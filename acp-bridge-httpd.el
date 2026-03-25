;;; acp-bridge-httpd.el --- Local OpenAI-compatible HTTP server  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  LuciusChen

;; Author: LuciusChen
;; Package-Requires: ((emacs "28.1") (acp-bridge "0.1.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exposes acp-bridge as a local OpenAI-compatible HTTP server using
;; Emacs built-in make-network-process — no third-party dependencies.
;;
;; Usage:
;;
;;   (require 'acp-bridge-httpd)
;;   (acp-bridge-httpd-start)
;;
;; Then point any OpenAI-compatible tool at http://localhost:8765:
;;
;;   ;; gptel
;;   (gptel-make-openai "acp-bridge"
;;     :host "localhost:8765" :protocol "http"
;;     :models '(claude codex) :stream t :key "ignored")
;;
;;   ;; gt.el
;;   (setq gt-chatgpt-host "http://localhost:8765" gt-chatgpt-key "ignored")
;;
;; Model mapping: names starting with "codex" → :codex, else → :claude.
;; Session management: single user turn → new session; multi-turn → reuse session.

;;; Code:

(require 'acp-bridge)
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
  "The server process, or nil when stopped.")

;;; HTTP parsing

(defun acp-bridge-httpd--filter (proc data)
  "Accumulate DATA on PROC and dispatch when the full HTTP request is ready."
  (process-put proc :buf (concat (process-get proc :buf) data))
  (let ((buf (process-get proc :buf)))
    (unless (process-get proc :hdr-end)
      (when-let* ((pos (string-search "\r\n\r\n" buf)))
        (dolist (line (split-string (substring buf 0 pos) "\r\n"))
          (cond
           ((string-match "^\\([A-Z]+\\) \\([^ ]+\\) HTTP" line)
            (process-put proc :method (match-string 1 line))
            (process-put proc :path   (match-string 2 line)))
           ((string-match "^[Cc]ontent-[Ll]ength: *\\([0-9]+\\)" line)
            (process-put proc :clen (string-to-number (match-string 1 line))))))
        (process-put proc :hdr-end (+ pos 4))))
    (when-let* ((hdr-end (process-get proc :hdr-end))
                (clen    (or (process-get proc :clen) 0))
                (body    (substring buf hdr-end))
                (_ (>= (string-bytes body) clen)))
      (acp-bridge-httpd--dispatch proc
                                  (process-get proc :method)
                                  (process-get proc :path)
                                  body))))

(defun acp-bridge-httpd--dispatch (proc method path body)
  "Route METHOD PATH request with BODY."
  (if (and (equal method "POST") (equal path "/v1/chat/completions"))
      (acp-bridge-httpd--completions proc body)
    (process-send-string proc
      "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nNot found")
    (delete-process proc)))

;;; Helpers

(defun acp-bridge-httpd--model->agent (model)
  "Map MODEL string to an acp-bridge agent keyword."
  (if (and (stringp model) (string-prefix-p "codex" model)) :codex :claude))

(defun acp-bridge-httpd--parse-messages (messages)
  "Return plist (:prompt :system :new-session) from MESSAGES array."
  (let (sys last-user (user-count 0))
    (seq-doseq (msg messages)
      (pcase (map-elt msg 'role)
        ("system" (unless sys (setq sys (map-elt msg 'content))))
        ("user"   (cl-incf user-count)
                  (setq last-user (map-elt msg 'content)))))
    (list :prompt      last-user
          :system      sys
          :new-session (= user-count 1))))

(defun acp-bridge-httpd--sse (content)
  "Format CONTENT as an OpenAI-compatible SSE data line."
  (format "data: %s\n\n"
          (json-serialize
           `((id      . "acp-bridge")
             (object  . "chat.completion.chunk")
             (choices . [((index         . 0)
                          (delta         . ((content . ,content)))
                          (finish_reason . :null))])))))

;;; Completions endpoint

(defun acp-bridge-httpd--completions (proc body)
  "Handle POST /v1/chat/completions: stream SSE to PROC."
  (condition-case err
      (let* ((data     (json-parse-string body
                                          :object-type 'alist
                                          :null-object nil
                                          :false-object nil))
             (model    (map-elt data 'model))
             (messages (map-elt data 'messages))
             (agent    (acp-bridge-httpd--model->agent model))
             (parsed   (acp-bridge-httpd--parse-messages messages))
             (prompt   (plist-get parsed :prompt))
             (sys      (plist-get parsed :system))
             (new-ses  (plist-get parsed :new-session))
             (app      (intern (format "acp-bridge-httpd-%s" (or model "claude")))))
        (unless (and (stringp prompt) (not (string-empty-p prompt)))
          (error "no user message in request"))
        (process-send-string proc
          (concat "HTTP/1.1 200 OK\r\n"
                  "Content-Type: text/event-stream; charset=utf-8\r\n"
                  "Cache-Control: no-cache\r\n"
                  "X-Accel-Buffering: no\r\n"
                  "Connection: keep-alive\r\n"
                  "\r\n"))
        (let ((prev 0))
          (acp-bridge-request prompt
            :agent         agent
            :app           app
            :cwd           "~"
            :system-prompt sys
            :new-session   new-ses
            :on-chunk
            (lambda (acc)
              (let ((delta (substring acc prev)))
                (setq prev (length acc))
                (unless (string-empty-p delta)
                  (process-send-string proc (acp-bridge-httpd--sse delta)))))
            :on-done
            (lambda (_)
              (process-send-string proc "data: [DONE]\n\n")
              (delete-process proc))
            :on-error
            (lambda (_kind msg)
              (process-send-string proc (format "data: {\"error\":%S}\n\n" msg))
              (delete-process proc)))))
    (error
     (ignore-errors
       (process-send-string proc
         (format (concat "HTTP/1.1 500 Internal Server Error\r\n"
                         "Content-Type: text/plain\r\nConnection: close\r\n\r\n"
                         "Error: %S") err)))
     (delete-process proc))))

;;; Public API

;;;###autoload
(defun acp-bridge-httpd-start ()
  "Start the local OpenAI-compatible HTTP server on `acp-bridge-httpd-port'."
  (interactive)
  (when acp-bridge-httpd--server
    (user-error "acp-bridge-httpd already running on port %d" acp-bridge-httpd-port))
  (setq acp-bridge-httpd--server
        (make-network-process
         :name    "acp-bridge-httpd"
         :service acp-bridge-httpd-port
         :server  t
         :family  'ipv4
         :coding  'binary
         :noquery t
         :filter  #'acp-bridge-httpd--filter))
  (message "acp-bridge-httpd: listening on http://localhost:%d" acp-bridge-httpd-port))

;;;###autoload
(defun acp-bridge-httpd-stop ()
  "Stop the local OpenAI-compatible HTTP server."
  (interactive)
  (unless acp-bridge-httpd--server
    (user-error "acp-bridge-httpd: no server running"))
  (delete-process acp-bridge-httpd--server)
  (setq acp-bridge-httpd--server nil)
  (message "acp-bridge-httpd: stopped"))

(provide 'acp-bridge-httpd)
;;; acp-bridge-httpd.el ends here
