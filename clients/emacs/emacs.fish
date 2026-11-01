# Emacs through its server, for fish. ansible/playbooks/client-home-emacs.yml links this
# file into ~/.config/fish/conf.d/, so an edit here is live in the next shell.
#
# `emacs FILE` opens FILE in the running Emacs server, in this terminal, so Emacs starts
# once and every later open is instant. With no server running, an empty ALTERNATE_EDITOR
# makes emacsclient start one first (on Termux the emacsd service normally has one up
# already). It is set as a variable rather than `-a ''` so EDITOR holds no quotes: fish's
# Alt-e and sudoedit split EDITOR on spaces and would pass the two characters '' on.
# `command emacs` is the real program. README.md beside this says how to restart the
# server after changing the LLAMA_* variables.
function emacs --wraps emacsclient --description 'Edit in the Emacs server, in this terminal'
    command emacsclient -t $argv
end

set -gx ALTERNATE_EDITOR ''
set -gx EDITOR 'emacsclient -t'
set -gx VISUAL $EDITOR

# 24-bit colour. Termux and Windows Terminal do it, but ssh does not pass COLORTERM, and
# without it Emacs paints the Catppuccin theme from the 256-colour palette in the wrong
# blues.
set -q COLORTERM; or set -gx COLORTERM truecolor

# pipx (Arch) puts rass, the ty+ruff language server wrapper, in ~/.local/bin.
test -d ~/.local/bin; and fish_add_path -g ~/.local/bin
