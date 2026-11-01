;;; install.el --- install the packages private.el uses  -*- lexical-binding: t; -*-
;; emacs --batch --init-directory ~/.emacs.d -l install.el
;;
;; Loads Solo as a real start does (early-init.el, init.el), then our private.el, whose
;; `use-package :ensure' forms install evil, corfu, minuet and nano-modeline. Without this
;; the first interactive start does it, and the screen freezes for half a minute. Prints
;; `changed' or `unchanged' on the last line; exits non-zero naming any package still
;; missing.

(defconst install-wanted '(evil corfu minuet nano-modeline))

(defun install-installed ()
  (require 'package)
  (package-initialize)
  (sort (mapcar #'car package-alist) #'string<))

(let ((before (install-installed))
      (ok t))
  (condition-case err
      (progn
        (load (locate-user-emacs-file "early-init.el") nil t)
        (load (locate-user-emacs-file "init.el") nil t)
        (load (locate-user-emacs-file "private.el") nil t))
    (error (setq ok nil)
           (princ (format "FAILED loading the config: %s\n" (error-message-string err)))))
  (let ((missing (seq-remove #'package-installed-p install-wanted)))
    (when missing
      (setq ok nil)
      (princ (format "MISSING %s\n" (mapconcat #'symbol-name missing " ")))))
  (if (not ok)
      (kill-emacs 1)
    (princ (if (equal before (install-installed)) "unchanged\n" "changed\n"))
    (kill-emacs 0)))
