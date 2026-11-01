;;; private-early-init.el --- ours, after Solo's early-init  -*- lexical-binding: t; -*-
;; Linked into ~/.emacs.d by ansible/playbooks/client-home-emacs.yml. Solo ignores this
;; file in git, so a pull of Solo never touches it. README.md beside it says what each
;; part is for.

;; Termux names this grammar libtree-sitter-markdown_inline.so, where Emacs looks for
;; libtree-sitter-markdown-inline.so (Arch's name, which needs nothing). Without this, on
;; Termux every LSP hover (Solo renders docs with markdown-ts-mode) git-cloned the grammar
;; and tried to compile it: ~1 MB and a 4 s freeze each time, measured. Only where that
;; file is.
(when (file-exists-p (expand-file-name "lib/libtree-sitter-markdown_inline.so"
                                       (or (getenv "PREFIX") "/usr")))
  (setq treesit-load-name-override-list
        '((markdown-inline "libtree-sitter-markdown_inline" "tree_sitter_markdown_inline"))))

;; Catppuccin Mocha, one of Solo's own themes (built on the modus-themes bundled with
;; Emacs 31), so nothing to download. Set here, before Solo's defaults; its defcustom then
;; keeps it.
(setq emacs-solo-use-custom-theme 'catppuccin)

;; Solo's banner in *scratch*, where `emacs' with no file opens, is 84 columns of block
;; letters and wraps into a jumble at 46. The same facts on one line instead.
(setq emacs-solo-scratch-banner
      (lambda () (format ";; Emacs Solo: %s, %d packages\n\n"
                         (emacs-init-time "%.2f s") (length package-activated-list))))
