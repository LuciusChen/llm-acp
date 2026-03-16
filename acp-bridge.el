;;; acp-bridge.el --- Programmatic API for ACP agents (Claude Code / Codex) -*- lexical-binding: t; -*-

;; A thin bridge between Emacs and ACP agents (Claude Code, Codex CLI).
;; Provides `acp-bridge-request' for calling agents from Elisp, and
;; session management commands.  No llm.el or gptel dependency.
;;
;; Quick start:
;;   (require 'acp-bridge)
;;
;;   ;; single-turn (e.g. commit message)
;;   (acp-bridge-request diff-text
;;     :app 'magit :new-session t
;;     :system-prompt "Conventional Commits format only."
;;     :on-done (lambda (text) (insert text)))
;;
;;   ;; multi-turn (session keeps history on agent side)
;;   (acp-bridge-request "Summarize the section"
;;     :app 'org
;;     :on-chunk (lambda (text) ...)
;;     :on-done  (lambda (_) nil))

;;; Code:

(require 'map)
(require 'project)
(require 'acp)
(eval-when-compile (require 'cl-lib))

;;; ── tunables ────────────────────────────────────────────────────────────────

(defgroup acp-bridge nil
  "ACP bridge for Claude Code / Codex CLI."
  :group 'tools)

(defcustom acp-bridge-claude-command '("claude-agent-acp")
  "Command + args for the Claude Code ACP server."
  :type '(repeat string) :group 'acp-bridge)

(defcustom acp-bridge-codex-command '("codex-acp")
  "Command + args for the Codex ACP server."
  :type '(repeat string) :group 'acp-bridge)

(defcustom acp-bridge-sessions-file
  (expand-file-name "acp-bridge-sessions.eld" user-emacs-directory)
  "File used to persist (app . context) → (agent . session-id) mappings."
  :type 'file :group 'acp-bridge)

(defcustom acp-bridge-fs-read-capability nil
  "When non-nil, declare fs/read_text_file capability in the ACP initialize request.
The bridge will automatically serve file-read requests from the agent using
Emacs file I/O.  Must be set before the first request to take effect."
  :type 'boolean :group 'acp-bridge)

(defcustom acp-bridge-fs-write-capability nil
  "When non-nil, declare fs/write_text_file capability in the ACP initialize request.
Agent file-write requests are surfaced to the caller via :on-request.
Must be set before the first request to take effect."
  :type 'boolean :group 'acp-bridge)

;;; ── session key ─────────────────────────────────────────────────────────────

(defun acp-bridge--compute-context (&optional cwd-override)
  "Return the session context directory.
Prefers CWD-OVERRIDE, then project root, then `default-directory'.
Result is always an expanded, trailing-slash-free path."
  (directory-file-name
   (expand-file-name
    (or cwd-override
        (when-let* ((pr (project-current))) (project-root pr))
        default-directory))))

(defun acp-bridge--session-key (app context)
  "Return the session persistence key for APP at CONTEXT."
  (cons app context))

;;; ── session persistence ─────────────────────────────────────────────────────
;;
;; Session values are (agent . session-id) cons cells.
;; An in-memory cache avoids repeated file reads within a single Emacs session.
;; The cache is write-through: every mutation immediately persists to disk.

(defvar acp-bridge--sessions-cache :unloaded
  "In-memory cache of session mappings, or :unloaded if not yet read.")

(defun acp-bridge--sessions-ensure ()
  "Load the sessions file into the cache if not already done."
  (when (eq acp-bridge--sessions-cache :unloaded)
    (setq acp-bridge--sessions-cache
          (or (when (file-exists-p acp-bridge-sessions-file)
                (with-temp-buffer
                  (insert-file-contents acp-bridge-sessions-file)
                  (ignore-errors (read (current-buffer)))))
              '()))))

(defun acp-bridge--sessions-flush ()
  "Persist the in-memory cache to disk."
  (with-temp-file acp-bridge-sessions-file
    (pp acp-bridge--sessions-cache (current-buffer))))

(defun acp-bridge--session-get (app context)
  "Return (agent . session-id) for APP at CONTEXT, or nil."
  (acp-bridge--sessions-ensure)
  (alist-get (acp-bridge--session-key app context)
             acp-bridge--sessions-cache nil nil #'equal))

(defun acp-bridge--session-set (app context agent session-id)
  "Store AGENT and SESSION-ID for APP at CONTEXT, then flush to disk."
  (acp-bridge--sessions-ensure)
  (let ((key (acp-bridge--session-key app context)))
    (setf (alist-get key acp-bridge--sessions-cache nil nil #'equal)
          (cons agent session-id)))
  (acp-bridge--sessions-flush))

(defun acp-bridge--session-remove (app context)
  "Remove the session for APP at CONTEXT, then flush to disk."
  (acp-bridge--sessions-ensure)
  (setq acp-bridge--sessions-cache
        (cl-remove (acp-bridge--session-key app context)
                   acp-bridge--sessions-cache :key #'car :test #'equal))
  (acp-bridge--sessions-flush))

;;; ── in-flight request table ─────────────────────────────────────────────────
;;
;; Each entry:
;;   (:partial FN :event FN :tool FN :request FN :complete FN :error FN
;;    :accumulated STRING :tool-calls HASH)

(defvar acp-bridge--pending (make-hash-table :test #'equal)
  "Hash table: session-id → plist with callbacks and accumulated text.")

(defun acp-bridge--pending-register
    (session-id partial event tool request complete error-fn)
  "Register callbacks for SESSION-ID."
  (puthash session-id
           (list :partial partial :event event :tool tool :request request
                 :complete complete :error error-fn :accumulated ""
                 :tool-calls (make-hash-table :test #'equal))
           acp-bridge--pending))

(defun acp-bridge--pending-append (session-id chunk)
  "Append CHUNK to accumulated text for SESSION-ID and call :partial."
  (when-let* ((entry (gethash session-id acp-bridge--pending)))
    (let ((acc (concat (plist-get entry :accumulated) chunk)))
      (puthash session-id (plist-put entry :accumulated acc) acp-bridge--pending)
      (when-let* ((fn (plist-get entry :partial)))
        (funcall fn acc)))))

(defun acp-bridge--pending-event (session-id event)
  "Forward raw ACP EVENT payload for SESSION-ID to the request callback."
  (when-let* ((entry (gethash session-id acp-bridge--pending))
              (fn    (plist-get entry :event)))
    (funcall fn event)))

(defun acp-bridge--tool-call-update-p (kind)
  "Return non-nil when KIND is a tool-call session update."
  (member kind '("tool_call" "tool_call_update")))

(defun acp-bridge--pending-tool-call-merge-field (state update from-key to-key)
  "Merge UPDATE FROM-KEY into STATE at TO-KEY when the field is present."
  (if (map-contains-key update from-key)
      (plist-put state to-key (map-elt update from-key))
    state))

(defun acp-bridge--pending-tool-call-event (session-id update)
  "Forward merged tool-call UPDATE for SESSION-ID to the request callback."
  (when-let* ((entry        (gethash session-id acp-bridge--pending))
              (fn           (plist-get entry :tool))
              (tool-call-id (map-elt update 'toolCallId))
              (tool-calls   (plist-get entry :tool-calls)))
    (let ((state (or (gethash tool-call-id tool-calls)
                     (list :type :tool-call
                           :session-id session-id
                           :tool-call-id tool-call-id))))
      (setq state (plist-put state :update-kind (map-elt update 'sessionUpdate)))
      (setq state (plist-put state :delta update))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'title :title))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'kind :kind))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'status :status))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'locations :locations))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'rawInput :raw-input))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'rawOutput :raw-output))
      (setq state (acp-bridge--pending-tool-call-merge-field state update 'content :content))
      (puthash tool-call-id state tool-calls)
      (funcall fn (copy-tree state)))))

(defun acp-bridge--pending-request (session-id request)
  "Forward ACP REQUEST event for SESSION-ID to the request callback."
  (when-let* ((entry (gethash session-id acp-bridge--pending))
              (fn    (plist-get entry :request)))
    (funcall fn request)
    t))

(defun acp-bridge--pending-complete (session-id)
  "Fire :complete for SESSION-ID and remove the entry."
  (when-let* ((entry (gethash session-id acp-bridge--pending)))
    (remhash session-id acp-bridge--pending)
    (when-let* ((fn (plist-get entry :complete)))
      (funcall fn (plist-get entry :accumulated)))))

(defun acp-bridge--pending-error (session-id kind msg)
  "Fire :error for SESSION-ID and remove the entry."
  (when-let* ((entry (gethash session-id acp-bridge--pending)))
    (remhash session-id acp-bridge--pending)
    (when-let* ((fn (plist-get entry :error)))
      (funcall fn kind msg))))

;;; ── global notification handler ─────────────────────────────────────────────

(defun acp-bridge--notification-handler (notification)
  "Dispatch a session/update NOTIFICATION to the correct pending request."
  (condition-case err
      (when (equal (map-elt notification 'method) "session/update")
        (let* ((params     (map-elt notification 'params))
               (session-id (map-elt params 'sessionId))
               (update     (map-elt params 'update))
               (kind       (map-elt update 'sessionUpdate))
               (chunk      (map-nested-elt update '(content text))))
          (when session-id
            (acp-bridge--pending-event session-id params)
            (cond
             ((and chunk (equal kind "agent_message_chunk"))
              (acp-bridge--pending-append session-id chunk))
             ((acp-bridge--tool-call-update-p kind)
              (acp-bridge--pending-tool-call-event session-id update))
             ((equal kind "agent_error")
              (acp-bridge--pending-error session-id 'error
                                         (or (map-nested-elt update '(content text))
                                             "agent error")))))))
    (error (message "acp-bridge: notification handler error: %S" err))))

(defun acp-bridge--respond-permission (client request-id &optional option-id)
  "Send a permission response for REQUEST-ID through CLIENT.
When OPTION-ID is non-nil, select that option; otherwise respond as cancelled."
  (acp-send-response
   :client client
   :response (if option-id
                 (acp-make-session-request-permission-response
                  :request-id request-id
                  :option-id option-id)
               (acp-make-session-request-permission-response
                :request-id request-id
                :cancelled t))))

(defun acp-bridge--permission-request-event (client request)
  "Build a callback event plist for a permission REQUEST on CLIENT."
  (let* ((request-id (map-elt request 'id))
         (params     (map-elt request 'params))
         (session-id (map-elt params 'sessionId)))
    (list :type       :permission-request
          :session-id session-id
          :request-id request-id
          :request    request
          :params     params
          :tool-call  (map-elt params 'toolCall)
          :options    (map-elt params 'options)
          :respond    (lambda (option-id)
                        (acp-bridge--respond-permission client request-id option-id))
          :cancel     (lambda ()
                        (acp-bridge--respond-permission client request-id nil)))))

(defun acp-bridge--fs-write-event (client request)
  "Build a callback event plist for an fs/write_text_file REQUEST on CLIENT."
  (let* ((request-id (map-elt request 'id))
         (params     (map-elt request 'params))
         (path       (map-elt params 'path))
         (content    (map-elt params 'content)))
    (list :type       :fs-write
          :request-id request-id
          :path       path
          :content    content
          :respond    (lambda ()
                        (condition-case err
                            (progn
                              (with-temp-file path (insert content))
                              (acp-send-response
                               :client client
                               :response (acp-make-fs-write-text-file-response
                                          :request-id request-id)))
                          (error
                           (acp-send-response
                            :client client
                            :response (acp-make-fs-write-text-file-response
                                       :request-id request-id
                                       :error (acp-make-error
                                               :code -32001
                                               :message (error-message-string err)))))))
          :cancel     (lambda ()
                        (acp-send-response
                         :client client
                         :response (acp-make-fs-write-text-file-response
                                    :request-id request-id
                                    :error (acp-make-error
                                            :code -32001
                                            :message "Write rejected")))))))

(defun acp-bridge--request-handler (client request)
  "Dispatch incoming ACP REQUEST for CLIENT to the correct pending request."
  (condition-case err
      (pcase (map-elt request 'method)
        ("session/request_permission"
         (let* ((params     (map-elt request 'params))
                (request-id (map-elt request 'id))
                (session-id (map-elt params 'sessionId))
                (event      (acp-bridge--permission-request-event client request)))
           (unless (and session-id
                        (acp-bridge--pending-request session-id event))
             (acp-bridge--respond-permission client request-id nil)
             (message "acp-bridge: auto-cancelled permission request for session %s"
                      session-id))))
        ("fs/read_text_file"
         (let* ((request-id (map-elt request 'id))
                (params     (map-elt request 'params))
                (path       (map-elt params 'path)))
           (condition-case read-err
               (acp-send-response
                :client client
                :response (acp-make-fs-read-text-file-response
                           :request-id request-id
                           :content (with-temp-buffer
                                      (insert-file-contents path)
                                      (buffer-string))))
             (error
              (acp-send-response
               :client client
               :response (acp-make-fs-read-text-file-response
                          :request-id request-id
                          :error (acp-make-error
                                  :code -32001
                                  :message (format "Cannot read %s: %s"
                                                   path (error-message-string read-err)))))))))
        ("fs/write_text_file"
         (let* ((params     (map-elt request 'params))
                (request-id (map-elt request 'id))
                (session-id (map-elt params 'sessionId))
                (event      (acp-bridge--fs-write-event client request)))
           (unless (and session-id
                        (acp-bridge--pending-request session-id event))
             (acp-send-response
              :client client
              :response (acp-make-fs-write-text-file-response
                         :request-id request-id
                         :error (acp-make-error :code -32001
                                                :message "No handler for fs/write_text_file")))
             (message "acp-bridge: auto-rejected fs/write_text_file for session %s"
                      session-id))))
        (_ nil))
    (error
     (when-let* ((request-id (map-elt request 'id)))
       (ignore-errors (acp-bridge--respond-permission client request-id nil)))
     (message "acp-bridge: request handler error: %S" err))))

;;; ── per-agent client with init state machine ────────────────────────────────
;;
;; State: :uninitialized → :initializing → :ready
;; While :initializing, sends are queued as thunks and drained on :ready.

(cl-defstruct acp-bridge--agent-entry
  client
  (state :uninitialized)
  (queue nil))

(defvar acp-bridge--agents (make-hash-table)
  "Hash table: agent-sym (:claude/:codex) → acp-bridge--agent-entry.")

(defun acp-bridge--agent-command (agent)
  "Return the ACP server command list for AGENT."
  (pcase agent
    (:claude acp-bridge-claude-command)
    (:codex  acp-bridge-codex-command)
    (_       (error "acp-bridge: unknown agent %S" agent))))

(defun acp-bridge--ensure-ready (agent thunk)
  "Call THUNK when the ACP client for AGENT is ready, initialising if needed."
  (let ((entry (gethash agent acp-bridge--agents)))
    (cond
     ((and entry (eq (acp-bridge--agent-entry-state entry) :ready))
      (funcall thunk))
     ((and entry (eq (acp-bridge--agent-entry-state entry) :initializing))
      (push thunk (acp-bridge--agent-entry-queue entry)))
     (t
      (let* ((cmd       (acp-bridge--agent-command agent))
             (client    (acp-make-client :command (car cmd)
                                         :command-params (cdr cmd)
                                         :context-buffer (current-buffer)))
             (new-entry (make-acp-bridge--agent-entry
                         :client client :state :initializing
                         :queue  (list thunk))))
        (puthash agent new-entry acp-bridge--agents)
        (acp-subscribe-to-notifications
         :client client
         :on-notification #'acp-bridge--notification-handler)
        (acp-subscribe-to-requests
         :client client
         :on-request (lambda (request)
                       (acp-bridge--request-handler client request)))
        (condition-case err
            (acp-send-request
             :client  client
             :request (acp-make-initialize-request
                       :protocol-version 1
                       :client-info '((name    . "acp-bridge")
                                      (title   . "Emacs acp-bridge")
                                      (version . "0.1.0"))
                       :read-text-file-capability  acp-bridge-fs-read-capability
                       :write-text-file-capability acp-bridge-fs-write-capability)
             :on-success
             (lambda (_)
               (setf (acp-bridge--agent-entry-state new-entry) :ready)
               (let ((q (nreverse (acp-bridge--agent-entry-queue new-entry))))
                 (setf (acp-bridge--agent-entry-queue new-entry) nil)
                 (mapc #'funcall q)))
             :on-failure
             (lambda (err)
               (remhash agent acp-bridge--agents)
               (message "acp-bridge: ACP init failed: %S" err)))
          (error
           (remhash agent acp-bridge--agents)
           (signal (car err) (cdr err)))))))))

;;; ── core send ────────────────────────────────────────────────────────────────

(defun acp-bridge--send
    (agent app cwd system-prompt mcp-servers message
           on-chunk on-event on-tool-call on-request on-done on-error)
  "Send MESSAGE via AGENT for APP at CWD.
SYSTEM-PROMPT is appended to the agent system prompt on new sessions.
MCP-SERVERS is a list of MCP server configurations passed to the session.
ON-CHUNK is called with accumulated text on each streaming chunk.
ON-EVENT is called with the raw session/update params payload.
ON-TOOL-CALL is called with merged tool-call state updates.
ON-REQUEST is called with ACP requests that require a client response.
ON-DONE is called with the final text when complete.
ON-ERROR is called with (kind msg) on failure."
  (let* ((context    (acp-bridge--compute-context cwd))
         (stored     (acp-bridge--session-get app context))
         (session-id (cdr stored)))
    (acp-bridge--ensure-ready
     agent
     (lambda ()
       (let* ((entry  (gethash agent acp-bridge--agents))
              (client (acp-bridge--agent-entry-client entry)))
         (if session-id
             (acp-bridge--resume-then-prompt
              client agent app context system-prompt session-id
              mcp-servers message on-chunk on-event on-tool-call on-request on-done on-error)
           (acp-bridge--new-session-then-prompt
            client agent app context system-prompt mcp-servers message
            on-chunk on-event on-tool-call on-request on-done on-error)))))))

(defun acp-bridge--new-session-then-prompt
    (client agent app context system-prompt mcp-servers message
            on-chunk on-event on-tool-call on-request on-done on-error)
  "Create a new ACP session and send MESSAGE as the first prompt."
  (acp-send-request
   :client  client
   :request (acp-make-session-new-request
             :cwd         context
             :mcp-servers mcp-servers
             :meta        (when system-prompt
                            `((systemPrompt . ((append . ,system-prompt))))))
   :on-success
   (lambda (response)
     (let ((sid (map-elt response 'sessionId)))
       (acp-bridge--session-set app context agent sid)
       (acp-bridge--do-prompt client sid message
                              on-chunk on-event on-tool-call on-request
                              on-done on-error)))
   :on-failure
   (lambda (err)
     (funcall on-error 'error (format "session/new failed: %S" err)))))

(defun acp-bridge--resume-then-prompt
    (client agent app context system-prompt session-id
     mcp-servers message on-chunk on-event on-tool-call on-request on-done on-error)
  "Resume SESSION-ID and send MESSAGE; fall back to a new session on failure."
  (acp-send-request
   :client  client
   :request (acp-make-session-resume-request :session-id session-id :cwd context
                                              :mcp-servers mcp-servers)
   :on-success
   (lambda (_)
     (acp-bridge--do-prompt client session-id message
                            on-chunk on-event on-tool-call on-request
                            on-done on-error))
   :on-failure
   (lambda (_)
     (acp-bridge--session-remove app context)
     (acp-bridge--new-session-then-prompt
      client agent app context system-prompt mcp-servers message
      on-chunk on-event on-tool-call on-request on-done on-error))))

(defun acp-bridge--do-prompt
    (client session-id text on-chunk on-event on-tool-call on-request
            on-done on-error)
  "Send TEXT as a prompt to SESSION-ID on CLIENT."
  (acp-bridge--pending-register session-id on-chunk on-event on-tool-call
                                on-request on-done on-error)
  (acp-send-request
   :client  client
   :request (acp-make-session-prompt-request :session-id session-id
                                              :prompt (list `((type . "text") (text . ,text))))
   :on-success (lambda (_) (acp-bridge--pending-complete session-id))
   :on-failure (lambda (err)
                 (acp-bridge--pending-error session-id 'error
                                            (format "session/prompt failed: %S" err)))))

;;; ── programmatic API ─────────────────────────────────────────────────────────

;;;###autoload
(cl-defun acp-bridge-request (message
                               &key
                               (agent        :claude)
                               (app          'acp-bridge)
                               cwd
                               system-prompt
                               new-session
                               mcp-servers
                               on-chunk
                               on-event
                               on-tool-call
                               on-request
                               on-done
                               on-error)
  "Send MESSAGE to AGENT for APP.

AGENT         :claude (default) or :codex.
APP           Symbol identifying the caller (default: \\='acp-bridge).
              Together with context, determines which session is reused.
CWD           Override for the session context directory.
              Nil = auto-detect from project root or `default-directory'.
SYSTEM-PROMPT String appended to agent system prompt on session creation.
NEW-SESSION   When non-nil, clear any stored session before sending.
              Useful for single-turn use (e.g. commit messages).
MCP-SERVERS   List of MCP server configuration alists for the session.
              Passed to session/new and session/resume.  Example:
              \\='(((name . \"my-server\") (command . \"/usr/local/bin/my-mcp\")))
ON-CHUNK      Called with accumulated text string on each streaming chunk.
ON-EVENT      Called with the raw ACP `session/update\\=' params payload.
ON-TOOL-CALL  Called with merged tool-call state updates.
ON-REQUEST    Called with ACP requests that require a client response.
              Receives permission-request, fs-write, and similar events.
ON-DONE       Called with the final text string when response is complete.
ON-ERROR      Called with (kind msg) on failure."
  (when new-session
    (acp-bridge--session-remove app (acp-bridge--compute-context cwd)))
  (let ((buf (current-buffer)))
    (cl-flet ((in-buf (fn) (when fn (lambda (&rest args)
                                      (when (buffer-live-p buf)
                                        (with-current-buffer buf
                                          (apply fn args)))))))
      (acp-bridge--send agent app cwd system-prompt mcp-servers message
                        (in-buf on-chunk) (in-buf on-event)
                        (in-buf on-tool-call) (in-buf on-request)
                        (in-buf on-done) (in-buf on-error)))))

;;; ── ergonomic helpers ────────────────────────────────────────────────────────

;;;###autoload
(cl-defun acp-bridge-query (message &rest args)
  "Single-turn ACP request.  Like `acp-bridge-request' with :new-session t.

Useful for one-shot calls (e.g. generating a commit message) where each
invocation must start from a clean slate.  All keyword arguments accepted
by `acp-bridge-request' are forwarded; :new-session t is always set."
  (apply #'acp-bridge-request message :new-session t args))

(defun acp-bridge--json-system-prompt (extra)
  "Return a system prompt requiring JSON output, with optional EXTRA appended."
  (concat "Respond with valid JSON only. No markdown code fences, no prose."
          (when extra (concat "\n" extra))))

(defun acp-bridge--json-done-handler (on-done on-error)
  "Wrap ON-DONE to JSON-parse the response text before calling it.
Calls ON-ERROR with (\\='json-parse-error msg) if parsing fails."
  (when on-done
    (lambda (text)
      (condition-case err
          (funcall on-done
                   (json-parse-string (string-trim text)
                                      :object-type 'alist
                                      :array-type  'list))
        (error
         (when on-error
           (funcall on-error 'json-parse-error
                    (format "JSON parse failed: %s"
                            (error-message-string err)))))))))

;;;###autoload
(cl-defun acp-bridge-query-json (message
                                  &key
                                  (agent        :claude)
                                  (app          'acp-bridge)
                                  cwd
                                  system-prompt
                                  mcp-servers
                                  on-chunk
                                  on-event
                                  on-tool-call
                                  on-request
                                  on-done
                                  on-error)
  "Single-turn ACP request; :on-done receives a parsed JSON alist.

Like `acp-bridge-query' but prepends a JSON-only instruction to SYSTEM-PROMPT
and parses the final text as JSON before passing it to ON-DONE.
On parse failure, calls ON-ERROR with (\\='json-parse-error msg)."
  (acp-bridge-query message
    :agent        agent
    :app          app
    :cwd          cwd
    :system-prompt (acp-bridge--json-system-prompt system-prompt)
    :mcp-servers  mcp-servers
    :on-chunk     on-chunk
    :on-event     on-event
    :on-tool-call on-tool-call
    :on-request   on-request
    :on-done      (acp-bridge--json-done-handler on-done on-error)
    :on-error     on-error))

;;; ── interactive session management ──────────────────────────────────────────

(defun acp-bridge--read-session-key ()
  "Read a session key (APP . CONTEXT) from the persisted sessions."
  (acp-bridge--sessions-ensure)
  (let ((keys (mapcar #'car acp-bridge--sessions-cache)))
    (if keys
        (let* ((choices  (mapcar (lambda (k)
                                   (format "%s @ %s" (car k) (cdr k)))
                                 keys))
               (selected (completing-read "Session: " choices nil t))
               (idx      (cl-position selected choices :test #'equal)))
          (nth idx keys))
      (user-error "No acp-bridge sessions found"))))

;;;###autoload
(defun acp-bridge-new-session (key)
  "Clear stored session for KEY; the next send will start a fresh one.
KEY is a (APP . CONTEXT) cons cell, selected interactively."
  (interactive (list (acp-bridge--read-session-key)))
  (acp-bridge--session-remove (car key) (cdr key))
  (message "acp-bridge: session for '%s @ %s' cleared." (car key) (cdr key)))

;;;###autoload
(defun acp-bridge-delete-session (key)
  "Cancel the ACP session for KEY on the agent side and forget it.
KEY is a (APP . CONTEXT) cons cell, selected interactively.
The agent is determined automatically from the stored session data."
  (interactive (list (acp-bridge--read-session-key)))
  (when-let* ((stored     (acp-bridge--session-get (car key) (cdr key)))
              (agent      (car stored))
              (session-id (cdr stored))
              (entry      (gethash agent acp-bridge--agents))
              (client     (acp-bridge--agent-entry-client entry)))
    (acp-send-request
     :client  client
     :request (acp-make-session-delete-request :session-id session-id)
     :on-success (lambda (_) (message "acp-bridge: session deleted."))
     :on-failure (lambda (_) nil)))
  (acp-bridge--session-remove (car key) (cdr key)))

;;;###autoload
(defun acp-bridge-cancel-session (key)
  "Send session/cancel for KEY, interrupting the ongoing operation.
KEY is a (APP . CONTEXT) cons cell, selected interactively.
The session remains alive; future sends to this (app, context) will reuse it.
Use `acp-bridge-delete-session' to also terminate the session entirely."
  (interactive (list (acp-bridge--read-session-key)))
  (if-let* ((stored     (acp-bridge--session-get (car key) (cdr key)))
            (agent      (car stored))
            (session-id (cdr stored))
            (entry      (gethash agent acp-bridge--agents))
            (client     (acp-bridge--agent-entry-client entry)))
      (progn
        (acp-send-notification
         :client       client
         :notification (acp-make-session-cancel-notification :session-id session-id))
        (message "acp-bridge: cancel sent for '%s @ %s'." (car key) (cdr key)))
    (user-error "acp-bridge: no active session for '%s @ %s'" (car key) (cdr key))))

;;;###autoload
(defun acp-bridge-set-model (key model-id)
  "Switch the session for KEY to MODEL-ID.
KEY is a (APP . CONTEXT) cons cell, selected interactively.
MODEL-ID is a string such as \"claude-opus-4-6\" or \"claude-haiku-4-5\".
Known Claude model IDs are offered for completion; any string is accepted.
This is a claude-code-acp extension; it has no effect on Codex sessions."
  (interactive
   (list (acp-bridge--read-session-key)
         (completing-read "Model ID: "
                          '("claude-opus-4-6"
                            "claude-sonnet-4-6"
                            "claude-haiku-4-5-20251001")
                          nil nil nil nil nil)))
  (if-let* ((stored     (acp-bridge--session-get (car key) (cdr key)))
            (agent      (car stored))
            (session-id (cdr stored))
            (entry      (gethash agent acp-bridge--agents))
            (client     (acp-bridge--agent-entry-client entry)))
      (acp-send-request
       :client  client
       :request (acp-make-session-set-model-request
                 :session-id session-id :model-id model-id)
       :on-success (lambda (_) (message "acp-bridge: model set to %s." model-id))
       :on-failure (lambda (err)
                     (message "acp-bridge: set-model failed: %S" err)))
    (user-error "acp-bridge: no active session for '%s @ %s'" (car key) (cdr key))))

;;; ── built-in callers ─────────────────────────────────────────────────────────

(defcustom acp-bridge-commit-agent :claude
  "Agent used by `acp-bridge-commit'."
  :type '(choice (const :tag "Claude Code" :claude)
                 (const :tag "Codex" :codex))
  :group 'acp-bridge)

(defconst acp-bridge-conventional-commits-prompt
  "The user provides the result of running `git diff --cached`. You suggest a conventional commit message. Don't add anything else to the response.

Commit message format:
  <type>[optional scope]: <description>

  [optional body]

  [optional footer(s)]

Types: fix, feat, build, chore, ci, docs, style, refactor, perf, test.
Use BREAKING CHANGE footer or ! after type/scope for breaking changes.
feat correlates with MINOR, fix with PATCH, BREAKING CHANGE with MAJOR in SemVer."
  "System prompt for `acp-bridge-commit'.")

;;;###autoload
(defun acp-bridge-commit ()
  "Generate a conventional commit message from staged changes and insert it."
  (interactive)
  (require 'magit-git nil t)
  (let ((diff (string-join (magit-git-lines "diff" "--cached") "\n")))
    (when (string-empty-p diff)
      (user-error "No staged changes"))
    (acp-bridge-query diff
      :agent        acp-bridge-commit-agent
      :app          'acp-bridge-commit
      :system-prompt acp-bridge-conventional-commits-prompt
      :on-done      (lambda (text) (insert (string-trim text)))
      :on-error     (lambda (_kind msg)
                      (message "acp-bridge-commit: %s" msg)))))

(provide 'acp-bridge)
;;; acp-bridge.el ends here
