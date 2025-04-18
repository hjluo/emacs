;;; mailclient.el --- mail sending via system's mail client.  -*- lexical-binding: t; -*-

;; Copyright (C) 2005-2025 Free Software Foundation, Inc.

;; Author: David Reitter <david.reitter@gmail.com>
;; Keywords: mail

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package allows handing over a buffer to be sent off
;; via the system's designated e-mail client.
;; Note that the e-mail client will display the contents of the buffer
;; again for editing.
;; The e-mail client is taken to be whoever handles a mailto: URL
;; via `browse-url'.
;; Mailto: URLs are composed according to RFC2368.

;; MIME bodies are not supported - we rather expect the mail client
;; to encode the body and add, for example, a digital signature.
;; The mailto URL RFC calls for "short text messages that are
;; actually the content of automatic processing."
;; So mailclient.el is ideal for situations where an e-mail is
;; generated automatically, and the user can edit it in the
;; mail client (e.g. bug-reports).

;; To activate:
;; (setq send-mail-function 'mailclient-send-it) ; if you use `mail'

;;; Code:


(require 'sendmail)   ;; for mail-sendmail-undelimit-header
(require 'mail-utils) ;; for mail-fetch-field
(require 'browse-url)
(require 'mail-parse)

(defcustom mailclient-place-body-on-clipboard-flag
  (fboundp 'w32-set-clipboard-data)
  "If non-nil, put the e-mail body on the clipboard in mailclient.
This is useful on systems where only short mailto:// URLs are
supported.  Defaults to non-nil on Windows, nil otherwise."
  :type 'boolean
  :group 'mail)

(defun mailclient-encode-string-as-url (string)
  "Convert STRING to a URL, using utf-8 as encoding."
  (apply (function concat)
	 (mapcar
	  (lambda (char)
	    (cond
	     ((eq char ?\n) "%0D%0A")  ;; newline
	     ((string-match "[-a-zA-Z0-9._~]" (char-to-string char))
	      (char-to-string char))   ;; unreserved as per RFC 6068
	     (t                        ;; everything else
	      (format "%%%02x" char))))	;; escape
	  ;; Convert string to list of chars
	  (append (encode-coding-string string 'utf-8)))))

(defvar mailclient-delim-static "?")
(defun mailclient-url-delim ()
  (let ((current mailclient-delim-static))
    (setq mailclient-delim-static "&")
    current))

(defun mailclient-gather-addresses (str &optional drop-first-name)
  (let ((field (mail-fetch-field str nil t)))
    (if field
	(save-excursion
	  (let ((first t)
		(result ""))
	    (mapc
	     (lambda (recp)
	       (setq result
		     (concat
		      result
		      (if (and drop-first-name
			       first)
			  ""
			(concat (mailclient-url-delim) str "="))
		      (mailclient-encode-string-as-url
		       recp)))
	       (setq first nil))
	     (split-string
	      (mail-strip-quoted-names field) ", *"))
	    result)))))

(declare-function clipboard-kill-ring-save "menu-bar.el"
		  (beg end &optional region))

;;;###autoload
(defun mailclient-send-it ()
  "Pass current buffer on to the system's mail client.
Suitable value for `send-mail-function'.
The mail client is taken to be the handler of mailto URLs."
  (require 'mail-utils)
  (let ((case-fold-search nil)
	delimline
	(mailbuf (current-buffer)))
    (with-temp-buffer
      (insert-buffer-substring mailbuf)
      ;; Move to header delimiter
      (mail-sendmail-undelimit-header)
      (setq delimline (point-marker))
      (if mail-aliases
	  (expand-mail-aliases (point-min) delimline))
      (goto-char (point-min))
      ;; ignore any blank lines in the header
      (while (and (re-search-forward "\n\n\n*" delimline t)
		  (< (point) delimline))
	(replace-match "\n"))
      (let ((case-fold-search t)
	    (mime-charset-pattern
	     (concat
	      "^content-type:[ \t]*text/plain;"
	      "\\(?:[ \t\n]*\\(?:format\\|delsp\\)=\"?[-a-z0-9]+\"?;\\)*"
	      "[ \t\n]*charset=\"?\\([^ \t\n\";]+\\)\"?"))
	    coding-system
	    character-coding
	    ;; Use the external browser function to send the
	    ;; message.
            (browse-url-default-handlers nil))
	;; initialize limiter
	(setq mailclient-delim-static "?")
	;; construct and call up mailto URL
	(browse-url
	 (concat
	  (save-excursion
	    (narrow-to-region (point-min) delimline)
            ;; We can't send multipart/* messages (i. e. with
            ;; attachments or the like) via this method.
            (when-let* ((type (mail-fetch-field "content-type")))
              (when (and (string-match "multipart"
                                       (car (mail-header-parse-content-type
                                             type)))
                         (not (y-or-n-p "Message with attachments can't be sent via mailclient; continue anyway?")))
                (error "Choose a different `send-mail-function' to send attachments")))
	    (goto-char (point-min))
	    (setq coding-system
		  (if (re-search-forward mime-charset-pattern nil t)
		      (coding-system-from-name (match-string 1))
		    'undecided))
	    (setq character-coding
		  (mail-fetch-field "content-transfer-encoding"))
	    (when character-coding
	      (setq character-coding (downcase character-coding)))
	    (concat
	     "mailto:"
	     ;; Some of the headers according to RFC 822 (or later).
	     (mailclient-gather-addresses "To"
					  'drop-first-name)
	     (mailclient-gather-addresses "cc"  )
	     (mailclient-gather-addresses "bcc"  )
	     (mailclient-gather-addresses "Resent-To"  )
	     (mailclient-gather-addresses "Resent-cc"  )
	     (mailclient-gather-addresses "Resent-bcc"  )
	     (mailclient-gather-addresses "Reply-To"  )
	     ;; The From field is not honored for now: it's
	     ;; not necessarily configured. The mail client
	     ;; knows the user's address(es)
	     ;; (mailclient-gather-addresses "From"  )
	     ;; subject line
	     (let ((subj (mail-fetch-field "Subject" nil t)))
	       (widen) ;; so we can read the body later on
	       (if subj ;; if non-blank
		   ;; the mail client will deal with
		   ;; warning the user etc.
		   (concat (mailclient-url-delim) "subject="
			   (mailclient-encode-string-as-url subj))
		 ""))))
	  ;; body
	  (mailclient-url-delim) "body="
	  (progn
	    (delete-region (point-min) delimline)
	    (unless (null character-coding)
	      ;; mailto: and clipboard need UTF-8 and cannot deal with
	      ;; Content-Transfer-Encoding or Content-Type.
	      ;; FIXME: There is code duplication here with rmail.el.
	      (set-buffer-multibyte nil)
	      (cond
	       ((string= character-coding "base64")
		(base64-decode-region (point-min) (point-max)))
	       ((string= character-coding "quoted-printable")
		(mail-unquote-printable-region (point-min) (point-max)
					       nil nil t))
               (t (error "Unsupported Content-Transfer-Encoding: %s"
			 character-coding)))
	      (decode-coding-region (point-min) (point-max) coding-system))
	    (mailclient-encode-string-as-url
	     (if mailclient-place-body-on-clipboard-flag
		 (progn
		   (clipboard-kill-ring-save (point-min) (point-max))
		   (concat
		    "*** E-Mail body has been placed on clipboard, "
		    "please paste it here! ***"))
	       (buffer-string))))))))))

(provide 'mailclient)

;;; mailclient.el ends here
