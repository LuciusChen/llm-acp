;;; tests/acp-bridge-test.el --- ERT tests for acp-bridge.el -*- lexical-binding: t; -*-

;; Run from repo root:
;;   emacs -batch \
;;     -L . \
;;     -L /tmp/acp-test-deps \
;;     -l ert \
;;     -l tests/acp-bridge-test \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'acp-bridge)
(require 'acp-fakes)

;;; ── helpers ─────────────────────────────────────────────────────────────────

(defmacro acp-bridge-test--with-clean-state (&rest body)
  "Run BODY with isolated sessions state and a temporary sessions file."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "acp-bridge-test-" nil ".eld"))
          (acp-bridge-sessions-file tmp))
     (unwind-protect
         (progn
           (setq acp-bridge--sessions-cache :unloaded)
           (clrhash acp-bridge--agents)
           (clrhash acp-bridge--pending)
           ,@body)
       (setq acp-bridge--sessions-cache :unloaded)
       (clrhash acp-bridge--agents)
       (clrhash acp-bridge--pending)
       (ignore-errors (delete-file tmp)))))

(defun acp-bridge-test--inject-agent (agent fake-client)
  "Insert a :ready AGENT entry backed by FAKE-CLIENT into `acp-bridge--agents'.
Also registers the global notification handler on FAKE-CLIENT so that
acp-fakes' inline dispatch reaches acp-bridge handlers."
  (acp-subscribe-to-notifications
   :client fake-client
   :on-notification #'acp-bridge--notification-handler)
  (acp-subscribe-to-requests
   :client fake-client
   :on-request (lambda (request)
                 (acp-bridge--request-handler fake-client request)))
  (puthash agent
           (make-acp-bridge--agent-entry
            :client fake-client :state :ready :queue nil)
           acp-bridge--agents))

;;; ── unit: session key ────────────────────────────────────────────────────────

(ert-deftest acp-bridge-test-session-key ()
  "Session key is a (app . context) cons cell."
  (should (equal (acp-bridge--session-key 'myapp "/tmp/proj")
                 '(myapp . "/tmp/proj"))))

;;; ── unit: compute-context ────────────────────────────────────────────────────

(ert-deftest acp-bridge-test-compute-context-override ()
  "CWD override is used and trailing slash is stripped."
  (should (equal (acp-bridge--compute-context "/tmp/override/")
                 "/tmp/override")))

(ert-deftest acp-bridge-test-compute-context-no-trailing-slash ()
  "Result never has a trailing slash."
  (should (not (string-suffix-p "/" (acp-bridge--compute-context "/tmp/foo/")))))

;;; ── unit: session persistence ────────────────────────────────────────────────

(ert-deftest acp-bridge-test-session-set-get-remove ()
  "Session can be set, retrieved, and removed."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'app1 "/tmp/ctx" :claude "sid-123")
    (should (equal (acp-bridge--session-get 'app1 "/tmp/ctx")
                   '(:claude . "sid-123")))
    (acp-bridge--session-remove 'app1 "/tmp/ctx")
    (should (null (acp-bridge--session-get 'app1 "/tmp/ctx")))))

(ert-deftest acp-bridge-test-session-persists-across-reload ()
  "Sessions flushed to disk survive a cache reset."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'app1 "/tmp/ctx" :claude "sid-999")
    (setq acp-bridge--sessions-cache :unloaded)
    (should (equal (acp-bridge--session-get 'app1 "/tmp/ctx")
                   '(:claude . "sid-999")))))

(ert-deftest acp-bridge-test-session-get-nil-for-missing ()
  "Returns nil for a key that was never set."
  (acp-bridge-test--with-clean-state
    (should (null (acp-bridge--session-get 'no-such-app "/tmp/ctx")))))

(ert-deftest acp-bridge-test-session-two-contexts-independent ()
  "Different contexts for the same app have independent sessions."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'app "/tmp/proj-a" :claude "sid-a")
    (acp-bridge--session-set 'app "/tmp/proj-b" :claude "sid-b")
    (should (equal (acp-bridge--session-get 'app "/tmp/proj-a") '(:claude . "sid-a")))
    (should (equal (acp-bridge--session-get 'app "/tmp/proj-b") '(:claude . "sid-b")))))

;;; ── integration: new session + streaming ────────────────────────────────────

(defvar acp-bridge-test--new-session-messages
  ;; Agent pre-injected as :ready → first request gets id=1
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-A"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-A")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "Hello"))))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-A")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . " world"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-new-session-streaming ()
  "New session: partial callbacks accumulate chunks; complete fires with full text."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--new-session-messages))
    (let ((partials '())
          (completed nil))
      (acp-bridge--send :claude 'test-app "/tmp/test-project" nil nil
                        "hi"
                        (lambda (text) (push text partials))
                        nil
                        nil
                        nil
                        (lambda (text) (setq completed text))
                        (lambda (_k _m) (error "unexpected error")))
      (should (equal (car partials) "Hello world"))
      (should (member "Hello" partials))
      (should (equal completed "Hello world"))
      (should (equal (acp-bridge--session-get 'test-app "/tmp/test-project")
                     '(:claude . "sid-A"))))))

;;; ── integration: resume success ─────────────────────────────────────────────

(defvar acp-bridge-test--resume-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/resume"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . nil))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-B")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "resumed"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-resume-success ()
  "Existing session is resumed; only last message sent; session-id unchanged."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'test-app "/tmp/test-project" :claude "sid-B")
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--resume-messages))
    (let ((completed nil))
      (acp-bridge--send :claude 'test-app "/tmp/test-project" nil nil
                        "continued"
                        nil
                        nil
                        nil
                        nil
                        (lambda (text) (setq completed text))
                        (lambda (_k _m) (error "unexpected error")))
      (should (equal completed "resumed"))
      (should (equal (acp-bridge--session-get 'test-app "/tmp/test-project")
                     '(:claude . "sid-B"))))))

;;; ── integration: resume failure → new session fallback ──────────────────────

(defvar acp-bridge-test--resume-fail-messages
  `(;; resume fails
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/resume"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (error . ((code . -32001) (message . "session not found"))))))
    ;; new session created
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . ((sessionId . "sid-C-fresh"))))))
    ;; prompt
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 3) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-C-fresh")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "fresh start"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 3) (result . nil))))))

(ert-deftest acp-bridge-test-resume-failure-fallback ()
  "Resume failure triggers new session; new session-id is stored."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'test-app "/tmp/test-project" :claude "sid-expired")
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--resume-fail-messages))
    (let ((completed nil))
      (acp-bridge--send :claude 'test-app "/tmp/test-project" nil nil
                        "retry"
                        nil
                        nil
                        nil
                        nil
                        (lambda (text) (setq completed text))
                        (lambda (_k _m) (error "unexpected error")))
      (should (equal completed "fresh start"))
      (should (equal (acp-bridge--session-get 'test-app "/tmp/test-project")
                     '(:claude . "sid-C-fresh"))))))

;;; ── integration: acp-bridge-request ─────────────────────────────────────────

(ert-deftest acp-bridge-test-request-streaming ()
  "acp-bridge-request: partial callbacks accumulate chunks; done fires with full text."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--new-session-messages))
    (let ((partials '())
          (completed nil))
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-chunk (lambda (text) (push text partials))
        :on-done  (lambda (text) (setq completed text))
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (equal (car partials) "Hello world"))
      (should (member "Hello" partials))
      (should (equal completed "Hello world"))
      (should (equal (acp-bridge--session-get 'test-app "/tmp/test-project")
                     '(:claude . "sid-A"))))))

(ert-deftest acp-bridge-test-request-on-event ()
  "acp-bridge-request forwards raw session/update params to :on-event."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--new-session-messages))
    (let (events)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-event (lambda (event) (push event events))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (= (length events) 2))
      (should (equal (map-elt (car events) 'sessionId) "sid-A"))
      (should (equal (map-nested-elt (car events) '(update sessionUpdate))
                     "agent_message_chunk"))
      (should (equal (map-nested-elt (car events) '(update content text))
                     " world"))
      (should (equal (map-nested-elt (cadr events) '(update content text))
                     "Hello")))))

(defvar acp-bridge-test--tool-call-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-T"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-T")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Search repo")
                                       (kind . "search")
                                       (status . "in_progress")
                                       (rawInput . "rg foo"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-T")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "completed")
                                       (rawOutput . "2 matches")
                                       (content . ((text . "Found 2 matches"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-request-on-tool-call ()
  "acp-bridge-request forwards merged tool-call state via :on-tool-call."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--tool-call-messages))
    (let (events)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event) (push event events))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (= (length events) 2))
      (let ((latest (car events))
            (initial (cadr events)))
        (should (equal (plist-get latest :type) :tool-call))
        (should (equal (plist-get latest :session-id) "sid-T"))
        (should (equal (plist-get latest :tool-call-id) "tool-1"))
        (should (equal (plist-get latest :title) "Search repo"))
        (should (equal (plist-get latest :kind) "search"))
        (should (equal (plist-get latest :status) "completed"))
        (should (equal (plist-get latest :raw-input) "rg foo"))
        (should (equal (plist-get latest :raw-output) "2 matches"))
        (should (equal (map-nested-elt (plist-get latest :content) '(text))
                       "Found 2 matches"))
        (should (equal (plist-get latest :update-kind) "tool_call_update"))
        (should (equal (plist-get initial :status) "in_progress"))
        (should (equal (plist-get initial :update-kind) "tool_call"))))))

(defvar acp-bridge-test--permission-request-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-P"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . request)
     (:object . ((id . 77)
                 (method . "session/request_permission")
                 (params . ((sessionId . "sid-P")
                            (toolCall . ((tool . "Bash")
                                         (status . "pending")))
                            (options . [((id . "allow-once")
                                         (name . "Allow Once"))
                                        ((id . "reject")
                                         (name . "Reject"))]))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-P")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "after permission"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-request-on-request ()
  "acp-bridge-request surfaces permission requests and supports responding."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--permission-request-messages))
    (let (seen-request sent-response)
      (cl-letf (((symbol-function 'acp-send-response)
                 (lambda (&rest args)
                   (setq sent-response args))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :on-request
          (lambda (request)
            (setq seen-request request)
            (funcall (plist-get request :respond) "allow-once"))
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      (should (equal (plist-get seen-request :type) :permission-request))
      (should (equal (plist-get seen-request :session-id) "sid-P"))
      (should (equal (map-elt (plist-get seen-request :tool-call) 'tool) "Bash"))
      (should (equal (map-elt (aref (plist-get seen-request :options) 0) 'id)
                     "allow-once"))
      (should sent-response)
      (should (equal (map-elt (plist-get sent-response :response) :request-id) 77))
      (should (equal (map-nested-elt (plist-get sent-response :response)
                                     '(:result outcome optionId))
                     "allow-once")))))

(ert-deftest acp-bridge-test-request-on-request-auto-cancels ()
  "Permission requests are auto-cancelled when no :on-request handler exists."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--permission-request-messages))
    (let (sent-response)
      (cl-letf (((symbol-function 'acp-send-response)
                 (lambda (&rest args)
                   (setq sent-response args))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      (should sent-response)
      (should (equal (map-elt (plist-get sent-response :response) :request-id) 77))
      (should (equal (map-nested-elt (plist-get sent-response :response)
                                     '(:result outcome outcome))
                     "cancelled")))))

;;; ── integration: tool-call lifecycle ────────────────────────────────────────

(defvar acp-bridge-test--concurrent-tool-calls-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-CC"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CC")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Search")
                                       (status . "in_progress"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CC")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-2")
                                       (title . "Read file")
                                       (status . "in_progress"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CC")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "completed")
                                       (rawOutput . "2 matches"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CC")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-2")
                                       (status . "completed")
                                       (rawOutput . "file contents"))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-concurrent-tool-calls ()
  "Two concurrent tool calls are tracked independently by toolCallId."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--concurrent-tool-calls-messages))
    (let ((by-id (make-hash-table :test #'equal)))
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event)
                        (puthash (plist-get event :tool-call-id) event by-id))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (let ((t1 (gethash "tool-1" by-id))
            (t2 (gethash "tool-2" by-id)))
        (should t1)
        (should t2)
        ;; Titles carried from initial tool_call through the update
        (should (equal (plist-get t1 :title) "Search"))
        (should (equal (plist-get t2 :title) "Read file"))
        ;; Each reaches its own completed state independently
        (should (equal (plist-get t1 :status) "completed"))
        (should (equal (plist-get t2 :status) "completed"))
        (should (equal (plist-get t1 :raw-output) "2 matches"))
        (should (equal (plist-get t2 :raw-output) "file contents"))))))

(defvar acp-bridge-test--partial-update-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-PU"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-PU")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Search")
                                       (kind . "search")
                                       (status . "in_progress")
                                       (rawInput . "rg foo"))))))))
    ;; Partial update: only status and rawOutput — no title/kind/rawInput
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-PU")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "completed")
                                       (rawOutput . "3 matches"))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-partial-tool-call-update ()
  "Partial updates preserve existing fields not included in the delta."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--partial-update-messages))
    (let (latest)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event) (setq latest event))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      ;; Fields from the initial tool_call must survive the partial update
      (should (equal (plist-get latest :title) "Search"))
      (should (equal (plist-get latest :kind) "search"))
      (should (equal (plist-get latest :raw-input) "rg foo"))
      ;; Fields from the partial update are applied
      (should (equal (plist-get latest :status) "completed"))
      (should (equal (plist-get latest :raw-output) "3 matches")))))

(defvar acp-bridge-test--failed-tool-call-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-FL"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-FL")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Run command")
                                       (status . "in_progress"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-FL")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "failed")
                                       (rawOutput . "exit code 1"))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-failed-tool-call ()
  "Tool call with failed terminal state is surfaced correctly."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--failed-tool-call-messages))
    (let (latest)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event) (setq latest event))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (equal (plist-get latest :title) "Run command"))
      (should (equal (plist-get latest :status) "failed"))
      (should (equal (plist-get latest :raw-output) "exit code 1")))))

(defvar acp-bridge-test--cancelled-tool-call-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-CAN"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CAN")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Run tests")
                                       (status . "in_progress"))))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-CAN")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "cancelled"))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-cancelled-tool-call ()
  "Tool call with cancelled terminal state is surfaced correctly."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--cancelled-tool-call-messages))
    (let (latest)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event) (setq latest event))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (equal (plist-get latest :title) "Run tests"))
      (should (equal (plist-get latest :status) "cancelled")))))

(defvar acp-bridge-test--late-content-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-LC"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ;; Initial call: no content or rawOutput yet
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-LC")
                            (update . ((sessionUpdate . "tool_call")
                                       (toolCallId . "tool-1")
                                       (title . "Read file")
                                       (status . "in_progress"))))))))
    ;; rawOutput arrives in a later update
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-LC")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (rawOutput . "file content here"))))))))
    ;; content arrives last, alongside status completion
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-LC")
                            (update . ((sessionUpdate . "tool_call_update")
                                       (toolCallId . "tool-1")
                                       (status . "completed")
                                       (content . ((text . "summary of file"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-late-arriving-content ()
  "rawOutput and content arriving in later updates are merged into accumulated state."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--late-content-messages))
    (let (latest)
      (acp-bridge-request "hi"
        :app 'test-app
        :cwd "/tmp/test-project"
        :on-tool-call (lambda (event) (setq latest event))
        :on-done  (lambda (_text) nil)
        :on-error (lambda (_k _m) (error "unexpected error")))
      (should (equal (plist-get latest :title) "Read file"))
      (should (equal (plist-get latest :status) "completed"))
      (should (equal (plist-get latest :raw-output) "file content here"))
      (should (equal (map-nested-elt (plist-get latest :content) '(text))
                     "summary of file")))))

;;; ── integration: cancel-session ─────────────────────────────────────────────

(ert-deftest acp-bridge-test-cancel-session ()
  "cancel-session sends a notification and leaves the session in the store."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'test-app "/tmp/test-project" :claude "sid-cancel")
    (acp-bridge-test--inject-agent :claude (acp-fakes-make-client '()))
    (let (sent-notification)
      (cl-letf (((symbol-function 'acp-send-notification)
                 (lambda (&rest args) (setq sent-notification args))))
        (acp-bridge-cancel-session '(test-app . "/tmp/test-project")))
      (should sent-notification)
      (should (acp-bridge--session-get 'test-app "/tmp/test-project")))))

(ert-deftest acp-bridge-test-cancel-session-no-session ()
  "cancel-session signals user-error when no session is stored."
  (acp-bridge-test--with-clean-state
    (should-error
     (acp-bridge-cancel-session '(test-app . "/tmp/test-project"))
     :type 'user-error)))

;;; ── integration: set-model ───────────────────────────────────────────────────

(defvar acp-bridge-test--set-model-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/set_model"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . nil))))))

(ert-deftest acp-bridge-test-set-model-success ()
  "set-model sends the request and logs success."
  (acp-bridge-test--with-clean-state
    (acp-bridge--session-set 'test-app "/tmp/test-project" :claude "sid-model")
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--set-model-messages))
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (acp-bridge-set-model '(test-app . "/tmp/test-project") "claude-haiku-4-5"))
      (should (cl-some (lambda (m) (string-match-p "claude-haiku-4-5" m))
                       messages)))))

(ert-deftest acp-bridge-test-set-model-no-session ()
  "set-model signals user-error when no session is stored."
  (acp-bridge-test--with-clean-state
    (should-error
     (acp-bridge-set-model '(test-app . "/tmp/test-project") "claude-haiku-4-5")
     :type 'user-error)))

;;; ── integration: mcp-servers ────────────────────────────────────────────────

(ert-deftest acp-bridge-test-mcp-servers-forwarded ()
  ":mcp-servers is forwarded to session/new."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--new-session-messages))
    (let (captured-request)
      (cl-letf (((symbol-function 'acp-send-request)
                 (let ((orig (symbol-function 'acp-send-request)))
                   (lambda (&rest args)
                     (let ((req (plist-get args :request)))
                       (when (equal (map-elt req :method) "session/new")
                         (setq captured-request req)))
                     (apply orig args)))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :mcp-servers '(((name . "my-server") (command . "/bin/my-mcp")))
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      (should captured-request)
      (should (equal (map-nested-elt captured-request '(:params mcpServers))
                     '(((name . "my-server") (command . "/bin/my-mcp"))))))))

;;; ── integration: fs/read_text_file ──────────────────────────────────────────

(defvar acp-bridge-test--fs-read-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-FSR"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ;; Agent asks to read a file
    ((:direction . incoming) (:kind . request)
     (:object . ((id . 55)
                 (method . "fs/read_text_file")
                 (params . ((path . "/tmp/acp-test-read.txt"))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-FSR")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "done"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-fs-read-auto-handled ()
  "fs/read_text_file is auto-handled: file content sent back to agent."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--fs-read-messages))
    (let ((tmp (make-temp-file "acp-test-read-" nil ".txt"))
          sent-response)
      (unwind-protect
          (progn
            (with-temp-file tmp (insert "hello from emacs"))
            ;; Redirect the read path to the temp file
            (cl-letf (((symbol-function 'acp-send-response)
                       (lambda (&rest args)
                         (setq sent-response args))))
              (acp-bridge-request "hi"
                :app 'test-app
                :cwd "/tmp/test-project"
                ;; Patch the path inside the incoming request
                :on-done  (lambda (_text) nil)
                :on-error (lambda (_k _m) (error "unexpected error"))))
            ;; The bridge should have responded with the file content
            (should sent-response)
            (let ((response (plist-get sent-response :response)))
              (should (equal (map-elt response :request-id) 55))))
        (ignore-errors (delete-file tmp))))))

(ert-deftest acp-bridge-test-fs-read-error-response ()
  "fs/read_text_file sends an error response when the file cannot be read."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--fs-read-messages))
    (let (sent-response)
      (cl-letf (((symbol-function 'acp-send-response)
                 (lambda (&rest args)
                   (setq sent-response args))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      ;; /tmp/acp-test-read.txt doesn't exist → error response
      (should sent-response)
      (let ((response (plist-get sent-response :response)))
        (should (equal (map-elt response :request-id) 55))
        (should (map-elt response :error))))))

;;; ── integration: fs/write_text_file ─────────────────────────────────────────

(defvar acp-bridge-test--fs-write-messages
  `(((:direction . outgoing) (:kind . request)
     (:object . ((id . 1) (method . "session/new"))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 1) (result . ((sessionId . "sid-FSW"))))))
    ((:direction . outgoing) (:kind . request)
     (:object . ((id . 2) (method . "session/prompt"))))
    ;; Agent asks to write a file
    ((:direction . incoming) (:kind . request)
     (:object . ((id . 66)
                 (method . "fs/write_text_file")
                 (params . ((sessionId . "sid-FSW")
                            (path . "/tmp/acp-test-write.txt")
                            (content . "written by agent"))))))
    ((:direction . incoming) (:kind . notification)
     (:object . ((method . "session/update")
                 (params . ((sessionId . "sid-FSW")
                            (update . ((sessionUpdate . "agent_message_chunk")
                                       (content . ((text . "done"))))))))))
    ((:direction . incoming) (:kind . response)
     (:object . ((id . 2) (result . nil))))))

(ert-deftest acp-bridge-test-fs-write-surfaced-to-caller ()
  "fs/write_text_file is surfaced to the caller via :on-request."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--fs-write-messages))
    (let (seen-event sent-response)
      (cl-letf (((symbol-function 'acp-send-response)
                 (lambda (&rest args) (setq sent-response args))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :on-request (lambda (event)
                        (setq seen-event event)
                        (funcall (plist-get event :cancel)))
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      (should (equal (plist-get seen-event :type) :fs-write))
      (should (equal (plist-get seen-event :path) "/tmp/acp-test-write.txt"))
      (should (equal (plist-get seen-event :content) "written by agent"))
      (should sent-response)
      ;; cancel → error response
      (should (map-elt (plist-get sent-response :response) :error)))))

(ert-deftest acp-bridge-test-fs-write-auto-rejected ()
  "fs/write_text_file is auto-rejected when no :on-request handler exists."
  (acp-bridge-test--with-clean-state
    (acp-bridge-test--inject-agent :claude
                                   (acp-fakes-make-client
                                    acp-bridge-test--fs-write-messages))
    (let (sent-response)
      (cl-letf (((symbol-function 'acp-send-response)
                 (lambda (&rest args) (setq sent-response args))))
        (acp-bridge-request "hi"
          :app 'test-app
          :cwd "/tmp/test-project"
          :on-done  (lambda (_text) nil)
          :on-error (lambda (_k _m) (error "unexpected error"))))
      (should sent-response)
      (should (map-elt (plist-get sent-response :response) :error)))))

;;; ── robustness: malformed notification ───────────────────────────────────────

(ert-deftest acp-bridge-test-notification-handler-malformed ()
  "Errors inside notification handler are caught and not propagated."
  (cl-letf (((symbol-function 'map-elt)
             (lambda (&rest _) (error "simulated parse error"))))
    (should-not (condition-case _
                    (progn (acp-bridge--notification-handler '()) nil)
                  (error t)))))

(provide 'acp-bridge-test)
;;; tests/acp-bridge-test.el ends here
