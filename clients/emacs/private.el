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

;; Hover docs (SPC k) at the bottom, a third of the screen tall, instead of half of it.
(add-to-list 'display-buffer-alist
             '("\\*eldoc" (display-buffer-reuse-window display-buffer-at-bottom)
               (window-height . 0.33)))

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t) ; hel lives on MELPA
(setq package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1))) ; MELPA only when needed

;; Helix-style modal editing: ESC works in a terminal, gd/gr go through eglot's xref.
(use-package hel
  :ensure t
  :demand t
  :config
  (hel-mode 1)
  (hel-keymap-global-set :state 'normal          ; a small Helix space menu
    "SPC f" #'project-find-file   "SPC b" #'switch-to-buffer
    "SPC s" #'imenu               "SPC d" #'flymake-show-buffer-diagnostics
    "SPC a" #'eglot-code-actions  "SPC r" #'eglot-rename
    "SPC k" #'eldoc-doc-buffer    "SPC /" #'project-find-regexp
    "SPC ?" #'execute-extended-command)    ; the command palette, as in Helix
  (hel-keymap-global-set :state 'normal ":" #'private-colon))

;; Helix's :q, :q!, :w, :wq and :x on hel's `:', which is otherwise M-x. Typed exactly,
;; they run on Enter; anything else is M-x as before. Our own because evil's ex line,
;; the obvious donor, needs evil loaded beside hel, and its :q! under a server keeps the
;; unsaved buffer or, outside one, kills the server. Here :q! reverts first, so the edit
;; is gone, and the quits close this terminal's view (C-x C-c), never the server.
(defun private-q ()
  (if (and (buffer-file-name) (buffer-modified-p))
      (user-error "Unsaved changes: :w saves them, :q! discards them")
    (save-buffers-kill-terminal)))
(defun private-q! ()
  (when (buffer-modified-p)
    (cond ((and (buffer-file-name) (file-exists-p (buffer-file-name)))
           (revert-buffer t t))
          ((buffer-file-name)             ; a new file: nothing on disk to go back to
           (erase-buffer) (set-buffer-modified-p nil))
          (t (set-buffer-modified-p nil))))
  (save-buffers-kill-terminal))
(defun private-wq ()
  (save-buffer)
  (save-buffers-kill-terminal))
(defconst private-colon-commands
  '(("q" . private-q) ("q!" . private-q!) ("w" . save-buffer)
    ("wq" . private-wq) ("x" . private-wq)))
;; Plain functions, not commands, so M-x does not list them. hel would otherwise ask,
;; with several cursors, whether to run `:' once per cursor.
(hel-set-single-cursor-command 'private-colon)

(defun private-colon--setup ()
  "Make Enter run a `private-colon-commands' entry typed exactly, else what it did."
  (let ((map (current-local-map)))
    (use-local-map
     (make-composed-keymap
      (define-keymap "RET"
        (lambda () (interactive)
          (if (assoc (minibuffer-contents) private-colon-commands)
              (exit-minibuffer)
            (call-interactively (keymap-lookup map "RET")))))
      map))))
(defun private-colon (arg)
  "Run one of `private-colon-commands' if typed exactly, else M-x."
  (interactive "P")
  ;; The hook stays for the whole read, as M-X re-enters the minibuffer; depth 90, so
  ;; it wraps icomplete's Enter. last-typed lets M-x suggest a shorter way, as it does.
  ;; The prompt is `: ', so this is told apart from M-x; M-X still cycles on to M-x's
  ;; own command sets.
  (let* ((execute-extended-command--last-typed nil)
         (extended-command-versions
          (cons (list ": " (lambda () read-extended-command-predicate))
                extended-command-versions))
         (name (progn (add-hook 'minibuffer-setup-hook #'private-colon--setup 90)
                      (unwind-protect (read-extended-command ": ")
                        (remove-hook 'minibuffer-setup-hook #'private-colon--setup)))))
    (if-let* ((command (cdr (assoc name private-colon-commands))))
        (progn
          ;; keep q, w and q! out of M-x's history, where they would be "[No match]"
          (setq extended-command-history (delete name extended-command-history))
          (funcall command))
      (execute-extended-command arg name execute-extended-command--last-typed))))

;; Learn keys from M-x, as from Helix's Space ?: each command is listed with its key, and
;; matching anywhere in the name finds hel's own commands (typing `undo' lists
;; `hel-undo (u)'). By default M-x matches from the start only, which hid them.
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
  ;; suggest only while typing, not in hel's normal state
  (add-to-list 'minuet-auto-suggestion-block-predicates
               (lambda () (and (bound-and-true-p hel-local-mode)
                               (not (bound-and-true-p hel-insert-state)))))
  (add-hook 'prog-mode-hook #'minuet-auto-suggestion-mode)
  (dolist (b (buffer-list))
    (with-current-buffer b (when (derived-mode-p 'prog-mode) (minuet-auto-suggestion-mode)))))

;; NANO's modeline (Nicolas Rougier, GNU ELPA) in place of Solo's, at the bottom where
;; Solo's was. It shortens the buffer name on a narrow screen and never the line:column on
;; the right; Solo's line is cut from the right at 46 columns, position first.
(use-package nano-modeline
  :ensure t
  :demand t
  :config                                ; NANO's prog-mode line, with hel's NORMAL/INSERT tag first
  (nano-modeline-footer '((hel-state-mode-line-tag) " " (nano-modeline-buffer-status) " "
                          (nano-modeline-buffer-name) " " (nano-modeline-git-info))
                        '((nano-modeline-cursor-position)) t))   ; t: the default for every buffer
