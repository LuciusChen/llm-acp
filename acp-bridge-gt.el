;;; acp-bridge-gt.el --- gt.el engine backed by acp-bridge  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  LuciusChen

;; Author: LuciusChen
;; Package-Requires: ((emacs "28.1") (acp-bridge "0.1.0") (gt "0.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides `gt-acp-engine', a gt.el translation engine that uses
;; acp-bridge to send requests to Claude Code or Codex via ACP.
;;
;; Usage:
;;
;;   (gt-translator
;;     :taker   (gt-picker-taker)
;;     :engines (gt-acp-engine :agent :claude :stream t)
;;     :render  (gt-overlay-render))

;;; Code:

(require 'acp-bridge)
(require 'gt-core)

(defgroup acp-bridge-gt nil
  "gt.el engine backed by acp-bridge."
  :group 'acp-bridge
  :group 'gt)

(defcustom acp-bridge-gt-system-prompt
  "You are a translation assistant. Output only the translation, without any explanation or additional text."
  "System prompt used by `gt-acp-engine'."
  :type 'string
  :group 'acp-bridge-gt)

;;; Engine

(defclass gt-acp-engine (gt-engine)
  ((tag    :initarg :tag    :initform "ACP")
   (agent  :initarg :agent  :initform :claude
           :documentation "ACP agent to use: :claude or :codex.")
   (stream :initarg :stream :initform nil
           :documentation "When non-nil, stream chunks to the renderer.
Streaming is only supported for single-text requests."))
  "gt.el translation engine backed by acp-bridge.

Sends translation requests to Claude Code or Codex via the Agent
Client Protocol using `acp-bridge-query'.  Each request starts a
fresh ACP session.")

(cl-defmethod gt-execute ((engine gt-acp-engine) task)
  "Execute translation for TASK using acp-bridge."
  (with-slots (text src tgt) task
    (with-slots (agent stream) engine
      (when (and stream (cdr text))
        (user-error "gt-acp-engine: streaming does not support multiple text parts"))
      (let* ((render     (oref task render))
             (user-prompt (lambda (item)
                            (format "Translate from %s to %s:\n\n%s" src tgt item))))
        (if stream
            (pdd-with-new-task
              (acp-bridge-query (funcall user-prompt (car text))
                :agent         agent
                :app           'gt-acp
                :system-prompt acp-bridge-gt-system-prompt
                :new-session   t
                :on-chunk (lambda (acc)
                            (oset task res acc)
                            (gt-output render task))
                :on-done  (lambda (_) (pdd-resolve it nil))
                :on-error (lambda (_kind msg) (pdd-reject it msg))))
          (pdd-all
           (mapcar (lambda (item)
                     (pdd-with-new-task
                       (acp-bridge-query (funcall user-prompt item)
                         :agent         agent
                         :app           'gt-acp
                         :system-prompt acp-bridge-gt-system-prompt
                         :new-session   t
                         :on-done  (lambda (result) (pdd-resolve it result))
                         :on-error (lambda (_kind msg) (pdd-reject it msg)))))
                   text)))))))

(provide 'acp-bridge-gt)
;;; acp-bridge-gt.el ends here
