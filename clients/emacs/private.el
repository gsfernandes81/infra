;;; private.el --- loaded by Emacs Solo on its first idle  -*- lexical-binding: t; -*-
;; Linked into ~/.emacs.d by ansible/playbooks/client-home-emacs.yml. Solo ignores this
;; file in git, so a pull of Solo never touches it. README.md beside it says what each
;; part is for. Python LSP needs no line here: Emacs 31's eglot starts `rass python' (ty +
;; ruff) by default. Solo loads this file after any file named on the command line is
;; open, hence the `dolist (buffer-list)' lines that switch modes on in buffers already
;; open.

(setq treesit-auto-install-grammar 'ask)  ; Solo says 'always: never download a grammar unasked

;; Soft wrap, as in Helix: a long line wraps at a word, and its continuation lines keep
;; the line's indent. Solo truncates long lines (truncate-lines t); both modes are built
;; in.
(setq-default truncate-lines nil)
(global-visual-line-mode 1)
(global-visual-wrap-prefix-mode 1)

;; Helix's wrap marker: each continuation line starts with ↪ at the line's indent, in code
;; and text (not in the echo area or other special buffers). Emacs has no setting for it,
;; so the indent visual-wrap computes gets the marker appended. That function is internal
;; to visual-wrap.el (Emacs 31.1); if a later Emacs renames it, the advice simply stops
;; applying and wrapping still works, unmarked. Unindented lines get no prefix from
;; visual-wrap at all, so a buffer-local wrap-prefix carries the marker for those.
(defconst private-wrap-marker (propertize "↪ " 'face 'shadow))
(defun private-wrap-marker-here-p () (derived-mode-p 'prog-mode 'text-mode))
(defun private-wrap-marker-local ()
  (when (private-wrap-marker-here-p) (setq-local wrap-prefix private-wrap-marker)))
(add-hook 'after-change-major-mode-hook #'private-wrap-marker-local)
(dolist (b (buffer-list)) (with-current-buffer b (private-wrap-marker-local)))
(advice-add 'visual-wrap--adjust-prefix :filter-return
            (lambda (prefix)
              (if (private-wrap-marker-here-p)
                  (concat (if (numberp prefix) (make-string prefix ?\s) prefix) private-wrap-marker)
                prefix)))

;; Questions in the minibuffer wrap, and the minibuffer grows to show them (Solo's
;; resize-mini-windows). Solo truncates every minibuffer line, so at 46 columns C-x C-c's
;; "Save file …? (y, n, !, …)" scrolled sideways and showed only its tail. Not while
;; completing: there, truncation keeps each M-x candidate on one line. Depth 90, to run
;; after Solo's hook.
(add-hook 'minibuffer-setup-hook
          (lambda ()
            (unless minibuffer-completion-table
              (setq truncate-lines nil)
              (setq-local word-wrap t)))
          90)

;; Line numbers only as wide as the numbers on screen; Solo reserves 4 columns, which on
;; a 46-column screen is room for code.
(setopt display-line-numbers-width nil)

;; Hover docs (SPC k) at the bottom, a third of the screen tall, instead of half of it.
(add-to-list 'display-buffer-alist
             '("\\*eldoc" (display-buffer-reuse-window display-buffer-at-bottom)
               (window-height . 0.33)))

;; NANO's modeline (Nicolas Rougier, GNU ELPA) in place of Solo's, set up before evil,
;; which copies the current line into each buffer it starts in; at the bottom where
;; Solo's was. It shortens the buffer name on a narrow screen and never the line:column on
;; the right; Solo's line is cut from the right at 46 columns, position first.
(use-package nano-modeline
  :ensure t
  :demand t
  :config                                ; NANO's prog-mode line, with evil's NORMAL/INSERT tag first
  (nano-modeline-footer '((private-evil-tag) " " (nano-modeline-buffer-status) " "
                          (nano-modeline-buffer-name) " " (nano-modeline-git-info))
                        '((nano-modeline-cursor-position)) t))   ; t: the default for every buffer

;; MELPA for evil's current snapshot: NonGNU ELPA's evil, 1.15.0, predates Emacs 31 and
;; needed a fix to start on it.
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(setq package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1))) ; MELPA only when needed
(add-to-list 'package-pinned-packages '(evil . "melpa"))

;; Vim keys, keeping the Helix habits: gd and gr go through eglot (gr is Vim's
;; replace-char, so it is bound here), U redoes, C-u and C-d scroll half a page, C-o and
;; C-i walk the jump list, and Space opens a small menu. :q, :w, :wq, :x and the rest are
;; evil's own ex line. Panes you cannot type in (references, diagnostics, help: special
;; modes) open in evil's motion state, where q is theirs and closes them, not Vim's macro
;; recorder. evil loads flyspell, so the play installs aspell and its English
;; dictionary.
(use-package evil
  :ensure t
  :demand t
  :init
  (setq evil-undo-system 'undo-redo     ; Emacs's own undo-redo, which U and C-r use
        evil-want-C-u-scroll t
        ;; no <N> tag of evil's: it gives each buffer its own status line, which hides
        ;; NANO's; private-evil-tag shows the state there instead
        evil-mode-line-format nil)
  :config
  (evil-mode 1)
  (evil-set-initial-state 'special-mode 'motion)  ; and every mode derived from it
  (evil-define-key 'normal 'global "gr" #'xref-find-references "U" #'evil-redo)
  (evil-set-leader '(normal motion) (kbd "SPC"))
  (evil-define-key '(normal motion) 'global
    (kbd "<leader>f") #'project-find-file   (kbd "<leader>b") #'switch-to-buffer
    (kbd "<leader>s") #'imenu               (kbd "<leader>d") #'flymake-show-buffer-diagnostics
    (kbd "<leader>a") #'eglot-code-actions  (kbd "<leader>r") #'eglot-rename
    (kbd "<leader>k") #'eldoc-doc-buffer    (kbd "<leader>/") #'project-find-regexp
    (kbd "<leader>?") #'execute-extended-command))  ; the command palette, as in Helix

;; NORMAL, INSERT and the rest at the left of the status line, INSERT in the warning
;; colour.
(defun private-evil-tag ()
  (when (bound-and-true-p evil-state)
    (propertize (format " %s" (upcase (symbol-name evil-state)))
                'face (if (eq evil-state 'insert) 'warning 'mode-line-emphasis))))

;; Learn keys from M-x, as from Helix's Space ?: each command is listed with its key, and
;; matching anywhere in the name finds evil's own commands (typing `undo' lists
;; `evil-undo (u)'). By default M-x matches from the start only, which hid them.
(add-to-list 'completion-category-overrides '(command (styles substring basic)))

;; A completion popup: Emacs 31 draws child frames in a terminal, so no corfu-terminal.
;; As eager as Helix's: it opens after 2 typed characters or a `.', after corfu's 0.2 s
;; (Helix: 2 characters or a trigger character, after 250 ms). Corfu's defaults are 3
;; characters and no trigger characters.
(use-package corfu
  :ensure t
  :demand t
  :custom
  (corfu-auto t)
  (corfu-auto-prefix 2)
  (corfu-auto-trigger ".")
  :config
  (global-corfu-mode 1)
  ;; The popup replaces Solo's inline first-candidate preview, so the popup, that preview
  ;; and minuet's ghost text do not all show at once.
  (remove-hook 'prog-mode-hook #'completion-preview-mode)
  (remove-hook 'text-mode-hook #'completion-preview-mode)
  (dolist (b (buffer-list))
    (with-current-buffer b (when (bound-and-true-p completion-preview-mode) (completion-preview-mode -1)))))

;; Ghost-text suggestions from llama-server in router mode: every request carries the
;; model and the key. Where the server is comes from the environment the Emacs server
;; started in, so a change to these needs a restart of the server (README.md, "The
;; completion server"):
;;   LLAMA_BASE_URL   http://host:port, with or without /v1; the default,
;;                    http://127.0.0.1:8080, is where `ssh g14' forwards the laptop's
;;                    llama-server
;;   LLAMA_FIM_MODEL  the router's name for the completion model
;;   LLAMA_API_KEY    the key; minuet reads it again on every request
;; With no server, nothing shows: minuet logs the failure and gives up after 3 s.
(use-package minuet
  :ensure t
  :demand t
  :bind (:map minuet-active-mode-map
              ("TAB" . minuet-accept-suggestion)
              ("M-n" . minuet-next-suggestion)
              ("C-g" . minuet-dismiss-suggestion))
  :config
  (setq minuet-provider 'openai-fim-compatible
        minuet-n-completions 1
        minuet-context-window 512)
  (let ((base (string-remove-suffix
               "/v1" (string-remove-suffix "/" (or (getenv "LLAMA_BASE_URL") "http://127.0.0.1:8080")))))
    (plist-put minuet-openai-fim-compatible-options :end-point (concat base "/v1/completions")))
  (plist-put minuet-openai-fim-compatible-options :name "llama.cpp")
  ;; Read on every request. With no key set, minuet refuses to run and puts an error in
  ;; the echo area at every pause in typing, so a placeholder goes instead: a llama-server
  ;; without --api-key ignores it, and one with a key answers 401, which minuet logs.
  (plist-put minuet-openai-fim-compatible-options :api-key
             (lambda () (let ((key (getenv "LLAMA_API_KEY")))
                          (if (member key '(nil "")) "none" key))))
  (plist-put minuet-openai-fim-compatible-options :model (or (getenv "LLAMA_FIM_MODEL") "Qwen3Coder-30B-A3B"))
  (minuet-set-nested-plist minuet-openai-fim-compatible-options nil :template :suffix)
  (minuet-set-optional-options
   minuet-openai-fim-compatible-options :prompt
   (lambda (ctx) (format "<|fim_prefix|>%s\n%s<|fim_suffix|>%s<|fim_middle|>"
                         (plist-get ctx :language-and-tab)
                         (plist-get ctx :before-cursor)
                         (plist-get ctx :after-cursor)))
   :template)
  (minuet-set-optional-options minuet-openai-fim-compatible-options :max_tokens 56)
  ;; minuet's own default already holds suggestions back outside evil's insert state
  (add-hook 'prog-mode-hook #'minuet-auto-suggestion-mode)
  (dolist (b (buffer-list))
    (with-current-buffer b (when (derived-mode-p 'prog-mode) (minuet-auto-suggestion-mode)))))
