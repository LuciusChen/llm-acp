;;; llm-acp.el --- llm.el provider backed by ACP (Claude Code / Codex CLI) -*- lexical-binding: t; -*-

;; Wraps ACP agents as an llm.el provider.
;; Each app symbol gets its own persistent ACP session.
;; One ACP client process is shared per agent type.
;; A single global notification handler dispatches chunks
;; to per-request accumulators via a session-id keyed hash table.
;;
;; Setup:
;;   (require 'llm-acp)
;;   (setq ellama-provider   (llm-acp-make :agent :claude :app 'ellama))
;;   (setq magit-gptcommit-llm-provider (llm-acp-make :agent :claude :app 'magit))
;;
;; Session commands:
;;   M-x llm-acp-new-session     — clear stored session for an app (next call starts fresh)
;;   M-x llm-acp-delete-session  — cancel + clear session for an app

;;; Code:

(require 'map)
(require 'project)
(require 'acp)
(eval-when-compile (require 'cl-lib))

;;; ── tunables ────────────────────────────────────────────────────────────────

(defgroup llm-acp nil "llm.el provider via ACP." :group 'llm)

(defcustom llm-acp-claude-command '("claude-acp")
  "Command + args for the Claude Code ACP server."
  :type '(repeat string) :group 'llm-acp)

(defcustom llm-acp-codex-command '("codex-acp")
  "Command + args for the Codex ACP server."
  :type '(repeat string) :group 'llm-acp)

(defcustom llm-acp-sessions-file
  (expand-file-name "llm-acp-sessions.eld" user-emacs-directory)
  "File used to persist app → session-id mappings."
  :type 'file :group 'llm-acp)

;;; ── session persistence ─────────────────────────────────────────────────────

(defun llm-acp--sessions-read ()
  (when (file-exists-p llm-acp-sessions-file)
    (with-temp-buffer
      (insert-file-contents llm-acp-sessions-file)
      (ignore-errors (read (current-buffer))))))

(defun llm-acp--sessions-write (sessions)
  (with-temp-file llm-acp-sessions-file
    (pp sessions (current-buffer))))

(defun llm-acp--session-get (app)
  (alist-get app (llm-acp--sessions-read)))

(defun llm-acp--session-set (app session-id)
  (let ((s (or (llm-acp--sessions-read) '())))
    (setf (alist-get app s) session-id)
    (llm-acp--sessions-write s)))

(defun llm-acp--session-remove (app)
  (let ((s (or (llm-acp--sessions-read) '())))
    (llm-acp--sessions-write (assoc-delete-all app s))))

;;; ── in-flight request table  (session-id → plist) ──────────────────────────
;;
;; Each entry: (:partial FN :complete FN :error FN :accumulated STRING)

(defvar llm-acp--pending (make-hash-table :test #'equal))

(defun llm-acp--pending-register (session-id partial complete error-fn)
  (puthash session-id
           (list :partial partial :complete complete
                 :error error-fn :accumulated "")
           llm-acp--pending))

(defun llm-acp--pending-append (session-id chunk)
  "Append CHUNK to the accumulated text for SESSION-ID and call :partial."
  (when-let ((entry (gethash session-id llm-acp--pending)))
    (let ((acc (concat (plist-get entry :accumulated) chunk)))
      (puthash session-id (plist-put entry :accumulated acc) llm-acp--pending)
      (when-let (fn (plist-get entry :partial))
        (funcall fn acc)))))

(defun llm-acp--pending-complete (session-id)
  "Fire :complete for SESSION-ID and remove the entry."
  (when-let ((entry (gethash session-id llm-acp--pending)))
    (remhash session-id llm-acp--pending)
    (when-let (fn (plist-get entry :complete))
      (funcall fn (plist-get entry :accumulated)))))

(defun llm-acp--pending-error (session-id kind msg)
  "Fire :error for SESSION-ID and remove the entry."
  (when-let ((entry (gethash session-id llm-acp--pending)))
    (remhash session-id llm-acp--pending)
    (when-let (fn (plist-get entry :error))
      (funcall fn kind msg))))

;;; ── global notification handler (one per agent client) ─────────────────────

(defun llm-acp--notification-handler (notification)
  "Dispatch a session/update NOTIFICATION to the correct pending request."
  (when (equal (map-elt notification 'method) "session/update")
    (let* ((params     (map-elt notification 'params))
           (session-id (map-elt params 'sessionId))
           (update     (map-elt params 'update))
           (kind       (map-elt update 'sessionUpdate))
           (chunk      (map-nested-elt update '(content text))))
      (when session-id
        (cond
         ((and chunk (equal kind "agent_message_chunk"))
          (llm-acp--pending-append session-id chunk))
         ((equal kind "agent_error")
          (llm-acp--pending-error session-id 'error
                                  (or (map-nested-elt update '(content text))
                                      "agent error"))))))))

;;; ── per-agent client with init state machine ────────────────────────────────
;;
;; State: :uninitialized → :initializing → :ready
;; While :initializing, sends are queued as thunks and drained on :ready.

(cl-defstruct llm-acp--agent-entry
  client
  (state :uninitialized)
  (queue nil))                          ; list of (lambda ()) pending :ready

(defvar llm-acp--agents (make-hash-table)
  "Hash table: agent-sym (:claude/:codex) → llm-acp--agent-entry.")

(defun llm-acp--agent-command (agent)
  (pcase agent
    (:claude llm-acp-claude-command)
    (:codex  llm-acp-codex-command)
    (_       (error "llm-acp: unknown agent %S" agent))))

(defun llm-acp--ensure-ready (agent thunk)
  "Call THUNK when the ACP client for AGENT is ready, initialising if needed."
  (let ((entry (gethash agent llm-acp--agents)))
    (cond
     ;; Already ready
     ((and entry (eq (llm-acp--agent-entry-state entry) :ready))
      (funcall thunk))

     ;; Still initializing — queue the thunk
     ((and entry (eq (llm-acp--agent-entry-state entry) :initializing))
      (push thunk (llm-acp--agent-entry-queue entry)))

     ;; Need to start up
     (t
      (let* ((cmd    (llm-acp--agent-command agent))
             (client (acp-make-client :command (car cmd)
                                      :command-params (cdr cmd)
                                      :context-buffer (current-buffer)))
             (new-entry (make-llm-acp--agent-entry
                         :client client
                         :state  :initializing
                         :queue  (list thunk))))
        (puthash agent new-entry llm-acp--agents)
        ;; Register the single global notification handler
        (acp-subscribe-to-notifications
         :client client
         :on-notification #'llm-acp--notification-handler)
        ;; ACP handshake
        (acp-send-request
         :client client
         :request (acp-make-initialize-request
                   :protocol-version 1
                   :client-info '((name    . "llm-acp")
                                  (title   . "Emacs llm-acp")
                                  (version . "0.1.0")))
         :on-success (lambda (_)
                       (setf (llm-acp--agent-entry-state new-entry) :ready)
                       ;; Drain queue in FIFO order
                       (let ((q (nreverse (llm-acp--agent-entry-queue new-entry))))
                         (setf (llm-acp--agent-entry-queue new-entry) nil)
                         (mapc #'funcall q)))
         :on-failure (lambda (err)
                       (setf (llm-acp--agent-entry-state new-entry) :uninitialized)
                       (let ((msg (format "llm-acp: ACP init failed: %S" err)))
                         (dolist (t (llm-acp--agent-entry-queue new-entry))
                           (ignore-errors (funcall t)))
                         (setf (llm-acp--agent-entry-queue new-entry) nil)
                         (message "%s" msg)))))))))

;;; ── struct ──────────────────────────────────────────────────────────────────

(cl-defstruct (llm-acp (:constructor llm-acp-make) (:copier nil))
  "llm.el provider backed by an ACP agent.

AGENT  :claude or :codex.
APP    Symbol identifying the caller (e.g. \\='magit, \\='ellama).
       Each app keeps its own persistent session.
CWD    Working directory for session/new.  Nil = current project root."
  (agent :claude)
  (app   'default)
  (cwd   nil))

;;; ── llm.el interface ────────────────────────────────────────────────────────

(cl-defmethod llm-name ((p llm-acp))
  (format "%s/ACP[%s]"
          (pcase (llm-acp-agent p) (:claude "Claude") (:codex "Codex"))
          (llm-acp-app p)))

(cl-defmethod llm-capabilities ((_ llm-acp)) '(streaming))
(cl-defmethod llm-chat-token-limit ((_ llm-acp)) 200000)

(cl-defmethod llm-chat-async ((p llm-acp) prompt response-cb error-cb &optional _)
  (llm-acp--send p prompt nil response-cb error-cb))

(cl-defmethod llm-chat-streaming ((p llm-acp) prompt partial-cb response-cb error-cb &optional _)
  (llm-acp--send p prompt partial-cb response-cb error-cb))

;;; ── core send ───────────────────────────────────────────────────────────────

(defun llm-acp--send (provider prompt partial-cb complete-cb error-cb)
  (let* ((agent (llm-acp-agent provider))
         (app   (llm-acp-app provider))
         (cwd   (or (llm-acp-cwd provider)
                    (when-let (pr (project-current)) (project-root pr))
                    default-directory))
         (text  (llm-acp--prompt->text prompt)))
    (llm-acp--ensure-ready
     agent
     (lambda ()
       (let* ((entry      (gethash agent llm-acp--agents))
              (client     (llm-acp--agent-entry-client entry))
              (session-id (llm-acp--session-get app)))
         (if session-id
             (llm-acp--resume-then-prompt
              client app session-id cwd text partial-cb complete-cb error-cb)
           (llm-acp--new-session-then-prompt
            client app cwd text partial-cb complete-cb error-cb)))))))

(defun llm-acp--new-session-then-prompt
    (client app cwd text partial-cb complete-cb error-cb)
  (acp-send-request
   :client  client
   :request (acp-make-session-new-request :cwd cwd)
   :on-success
   (lambda (response)
     (let ((sid (map-elt response 'sessionId)))
       (llm-acp--session-set app sid)
       (llm-acp--do-prompt client sid text partial-cb complete-cb error-cb)))
   :on-failure
   (lambda (err)
     (funcall error-cb 'error (format "session/new failed: %S" err)))))

(defun llm-acp--resume-then-prompt
    (client app session-id cwd text partial-cb complete-cb error-cb)
  (acp-send-request
   :client  client
   :request (acp-make-session-resume-request :session-id session-id :cwd cwd)
   :on-success
   (lambda (_)
     (llm-acp--do-prompt client session-id text partial-cb complete-cb error-cb))
   :on-failure
   (lambda (_)
     ;; Session expired — start fresh
     (llm-acp--session-remove app)
     (llm-acp--new-session-then-prompt
      client app cwd text partial-cb complete-cb error-cb))))

(defun llm-acp--do-prompt (client session-id text partial-cb complete-cb error-cb)
  (llm-acp--pending-register session-id partial-cb complete-cb error-cb)
  (acp-send-request
   :client  client
   :request (acp-make-session-prompt-request :session-id session-id :prompt text)
   :on-success (lambda (_) (llm-acp--pending-complete session-id))
   :on-failure (lambda (err)
                 (llm-acp--pending-error session-id 'error
                                         (format "session/prompt failed: %S" err)))))

;;; ── prompt → text ───────────────────────────────────────────────────────────

(defun llm-acp--prompt->text (prompt)
  "Extract the latest user message from an llm-chat-prompt.

The ACP session owns history, so only the newest user turn is sent."
  (if-let* ((interactions (llm-chat-prompt-interactions prompt))
            (last-user    (cl-find-if
                           (lambda (i) (eq (llm-chat-prompt-interaction-role i) 'user))
                           interactions :from-end t)))
      (let ((content (llm-chat-prompt-interaction-content last-user)))
        (cond
         ((stringp content) content)
         ((listp content)
          (mapconcat (lambda (p) (if (stringp p) p "")) content ""))
         (t "")))
    (or (llm-chat-prompt-context prompt) "")))

;;; ── interactive session management ──────────────────────────────────────────

(defun llm-acp--read-app ()
  (let* ((sessions (llm-acp--sessions-read))
         (names    (mapcar (lambda (s) (symbol-name (car s))) sessions)))
    (if names
        (intern (completing-read "App: " names nil t))
      (user-error "No llm-acp sessions found"))))

;;;###autoload
(defun llm-acp-new-session (app)
  "Clear stored session for APP; the next send will start a fresh one."
  (interactive (list (llm-acp--read-app)))
  (llm-acp--session-remove app)
  (message "llm-acp: session for '%s' cleared." app))

;;;###autoload
(defun llm-acp-delete-session (app agent)
  "Cancel the ACP session for APP (running under AGENT) and forget it."
  (interactive (list (llm-acp--read-app) :claude))
  (when-let* ((session-id (llm-acp--session-get app))
              (entry      (gethash agent llm-acp--agents))
              (client     (llm-acp--agent-entry-client entry)))
    (acp-send-request
     :client  client
     :request (acp-make-session-delete-request :session-id session-id)
     :on-success (lambda (_) (message "llm-acp: session deleted."))
     :on-failure (lambda (_) nil)))
  (llm-acp--session-remove app))

(provide 'llm-acp)
;;; llm-acp.el ends here
