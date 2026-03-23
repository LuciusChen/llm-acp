;;; acp-bridge-httpd.el --- Local OpenAI-compatible HTTP server  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  LuciusChen

;; Author: LuciusChen
;; Package-Requires: ((emacs "28.1") (acp-bridge "0.1.0") (web-server "0.1.2"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exposes acp-bridge as a local OpenAI-compatible HTTP server so that
;; any tool supporting a custom OpenAI endpoint (gptel, gt.el, llm.el,
;; curl, …) can use Claude Code or Codex without extra configuration.
;;
;; Usage:
;;
;;   (require 'acp-bridge-httpd)
;;   (acp-bridge-httpd-start)          ; starts on acp-bridge-httpd-port
;;
;; Then point your tool at http://localhost:8765:
;;
;;   ;; gptel
;;   (gptel-make-openai "acp-bridge"
;;     :host     "localhost:8765"
;;     :protocol "http"
;;     :models   '(claude codex)
;;     :key      "ignored")
;;
;;   ;; gt.el
;;   (setq gt-chatgpt-host "http://localhost:8765"
;;         gt-chatgpt-key  "ignored")
;;
;; Model name mapping: any model whose name starts with "codex" uses
;; the :codex agent; everything else uses :claude.

;;; Code:

(require 'acp-bridge)
(require 'web-server)
(require 'json)
(require 'map)

(defgroup acp-bridge-httpd nil
  "Local OpenAI-compatible HTTP server backed by acp-bridge."
  :group 'acp-bridge)

(defcustom acp-bridge-httpd-port 8765
  "Port on which the acp-bridge HTTP server listens."
  :type 'natnum
  :group 'acp-bridge-httpd)

(defvar acp-bridge-httpd--server nil
  "Running `ws-server' instance, or nil when stopped.")

;;; Internal helpers

(defun acp-bridge-httpd--model->agent (model)
  "Map MODEL string to an acp-bridge agent keyword."
  (if (and (stringp model) (string-prefix-p "codex" model)) :codex :claude))

(defun acp-bridge-httpd--format-messages (messages)
  "Convert MESSAGES array into a (prompt . system-prompt) cons cell.
Single user turn: prompt is the content verbatim.
Multi-turn: prompt is formatted as a Human/Assistant dialogue so the
agent receives the full conversation history in one fresh session."
  (let (sys turns)
    (seq-doseq (msg messages)
      (let ((role    (map-elt msg 'role))
            (content (map-elt msg 'content)))
        (cond
         ((equal role "system")    (unless sys (setq sys content)))
         ((equal role "user")      (push (cons 'user      content) turns))
         ((equal role "assistant") (push (cons 'assistant content) turns)))))
    (setq turns (nreverse turns))
    (cons
     (if (and (= (length turns) 1) (eq (caar turns) 'user))
         (cdar turns)
       (mapconcat (lambda (turn)
                    (format "%s: %s"
                            (if (eq (car turn) 'user) "Human" "Assistant")
                            (cdr turn)))
                  turns "\n\n"))
     sys)))

(defun acp-bridge-httpd--sse-chunk (content)
  "Format CONTENT as an OpenAI-compatible SSE data line."
  (format "data: %s\n\n"
          (json-serialize
           `((id      . "acp-bridge")
             (object  . "chat.completion.chunk")
             (choices . [((index         . 0)
                          (delta         . ((content . ,content)))
                          (finish_reason . :null))])))))

(defun acp-bridge-httpd--close (proc)
  "Close client connection PROC and remove it from the server request list."
  (when-let* ((server (plist-get (process-plist proc) :server)))
    (setf (ws-requests server)
          (cl-remove-if (lambda (r) (eql proc (ws-process r)))
                        (ws-requests server))))
  (delete-process proc))

;;; Request handler

(defun acp-bridge-httpd--handle-completions (request)
  "Handle a POST /v1/chat/completions REQUEST."
  (with-slots (process body) request
    (condition-case err
        (let* ((data     (json-parse-string (ws-trim body)
                                            :object-type 'alist
                                            :null-object nil
                                            :false-object nil))
               (messages (map-elt data 'messages))
               (agent    (acp-bridge-httpd--model->agent (map-elt data 'model)))
               (parsed   (acp-bridge-httpd--format-messages messages))
               (prompt   (car parsed))
               (sys      (cdr parsed)))
          (unless (and prompt (not (string-empty-p prompt)))
            (ws-send-500 process "no user message in request"))
          (ws-response-header process 200
            '("Content-Type"      . "text/event-stream; charset=utf-8")
            '("Cache-Control"     . "no-cache")
            '("X-Accel-Buffering" . "no"))
          (let ((prev 0))
            (acp-bridge-query prompt
              :agent         agent
              :app           'acp-bridge-httpd
              :system-prompt sys
              :new-session   t
              :on-chunk
              (lambda (acc)
                (let ((delta (substring acc prev)))
                  (setq prev (length acc))
                  (unless (string-empty-p delta)
                    (process-send-string process
                      (acp-bridge-httpd--sse-chunk delta)))))
              :on-done
              (lambda (_)
                (process-send-string process "data: [DONE]\n\n")
                (acp-bridge-httpd--close process))
              :on-error
              (lambda (_kind msg)
                (process-send-string process
                  (format "data: {\"error\":%S}\n\n" msg))
                (acp-bridge-httpd--close process))))
          :keep-alive)
      (error
       (ws-send-500 process "acp-bridge-httpd: %S" err)))))

;;; Public API

;;;###autoload
(defun acp-bridge-httpd-start ()
  "Start the local OpenAI-compatible HTTP server.
Listens on `acp-bridge-httpd-port' (default 8765).
Handles POST /v1/chat/completions with SSE streaming."
  (interactive)
  (when acp-bridge-httpd--server
    (user-error "acp-bridge-httpd already running on port %d"
                acp-bridge-httpd-port))
  (setq acp-bridge-httpd--server
        (ws-start
         (lambda (request)
           (with-slots (headers) request
             (if (and (assoc :POST headers)
                      (string= "/v1/chat/completions"
                               (cdr (assoc :POST headers))))
                 (acp-bridge-httpd--handle-completions request)
               (ws-send-404 (ws-process request) "not found"))))
         acp-bridge-httpd-port))
  (message "acp-bridge-httpd: listening on http://localhost:%d"
           acp-bridge-httpd-port))

;;;###autoload
(defun acp-bridge-httpd-stop ()
  "Stop the local OpenAI-compatible HTTP server."
  (interactive)
  (unless acp-bridge-httpd--server
    (user-error "acp-bridge-httpd: no server running"))
  (ws-stop acp-bridge-httpd--server)
  (setq acp-bridge-httpd--server nil)
  (message "acp-bridge-httpd: stopped"))

(provide 'acp-bridge-httpd)
;;; acp-bridge-httpd.el ends here
