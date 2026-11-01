# Emacs on the clients

This is the editor for the phone (Termux) and for Arch in WSL on the laptop. It is **Emacs
Solo** (LionyxML/emacs-solo), a distribution built almost entirely on Emacs's own
features, with a small private layer of ours in the two files Solo sets aside for that:

- `private-early-init.el`: the Catppuccin Mocha theme (one of Solo's own) and a Termux
  grammar fix.
- `private.el`: NANO's modeline, Helix-style keys (`hel`), an eager completion popup
  (`corfu`), ghost-text suggestions from llama-server (`minuet`), and soft wrap marked
  with `↪` as in Helix.

Solo's own files are never edited, so updating Solo is a change of its pin in `SOURCE`.

## Set it up

Run the play from `ansible/` on the client itself:

```sh
cd ~/infra/ansible
ansible-playbook playbooks/client-home-emacs.yml        # Termux
ansible-playbook playbooks/client-home-emacs.yml -K     # Arch, when a package is missing
```

The play installs Emacs 31 and the tools the config uses, checks Solo out at the pinned
commit in `~/.emacs.d`, links our two files into it, and installs our four packages. It
links `emacs.fish` into fish's `conf.d`, and on Termux it installs the `emacsd` service.
It refuses an existing `~/.emacs.d` that is not Solo, and any `~/.emacs`, printing how to
move them aside.

A first run downloads about 5 MB after the packages, most of it the package indexes. Later
runs download only what the pin moved.

## Running it

`emacs FILE` opens FILE in the running Emacs server, in the terminal you typed it in.
`emacs.fish` makes `emacs` mean `emacsclient -t`, so Emacs starts once and every later
open is instant. With no server running, the first `emacs` starts one, because the file
also sets `ALTERNATE_EDITOR` empty. `EDITOR` and `VISUAL` point at the same command.

- **On Termux** the `emacsd` runit service keeps a server up: `sv status emacsd`, `sv
  restart emacsd`, and its log in `$PREFIX/var/log/sv/emacsd/current`. termux-services
  starts its supervisor at login, so after the first install, close every Termux session
  and open a new one.
- **On Arch** there is no service; the first `emacs` starts the server.
- **The real program** is still there as `command emacs`.
- **Restarting the server** is how a change to the `LLAMA_*` variables reaches it: the
  server reads them when it starts. On Termux `sv restart emacsd`, and `sv down emacsd`
  stops it; on Arch `emacsclient -e '(kill-emacs)'`, and the next `emacs` starts a new
  one.

## Keys worth knowing

The keys are Helix's, through `hel`. Prefix keys show a menu of what can follow
(which-key), and `M-x` lists every command with its key. Type part of what you want, such
as `undo` or `refer`, and the key appears beside the match.

| Key | Does |
|---|---|
| `Space` | the Space menu: `f` files, `b` buffers, `s` symbols, `d` diagnostics, `a` code actions, `r` rename, `k` hover docs, `/` search |
| `Space ?` | the command palette: `M-x` with keys, as in Helix |
| `:` | `M-x` too, with `:` as its prompt, except that `:w`, `:q`, `:q!`, `:wq` and `:x`, typed exactly, do what they do in Helix. `:q` refuses while the file has unsaved changes; `:q!` throws them away. Both close this terminal's view, as `C-x C-c` does, and leave the server running; other files changed in this terminal still get the save question |
| `g` | the goto menu: `g d` definition, `g r` references |
| `u` / `U` | undo / redo |
| `i`, `a`, `o` | insert |
| Tab | in insert mode, accepts the grey suggestion from llama-server |
| `C-h k`, `C-h b` | what a key does; every key active now |

## The completion server

`minuet` asks llama-server's `/v1/completions` for fill-in-the-middle text, and shows it
as grey text after the cursor. It reads three environment variables, in the server's
environment, so they are set in fish's `conf.d`:

| Set | For |
|---|---|
| `LLAMA_BASE_URL` | where llama-server is: `http://host:port`, with or without `/v1`. Default `http://127.0.0.1:8080`, where `ssh g14` forwards the laptop's |
| `LLAMA_FIM_MODEL` | the router's name for the completion model, sent with every request |
| `LLAMA_API_KEY` | the key, read again on every request. Unset, `none` is sent, which a llama-server without `--api-key` accepts |

With no server reachable, or a wrong key, nothing shows: `minuet` logs the failure and
gives up after 3 s.
`docs/ssh-clients.md` § The laptop says how the phone reaches the laptop's llama-server.

## Updating

- **Solo:** read its changes since the commit in `SOURCE`, try the new commit, then change
  the sha in `SOURCE` and re-run the play on each client.
- **Packages:** `M-x package-upgrade-all`. Their versions are not pinned; each client
  takes what the archives hold when it installs or upgrades.

## The files

| File | Holds |
|---|---|
| `SOURCE` | Solo's upstream and the pinned commit |
| `private-early-init.el` | the theme, and Termux's markdown grammar name |
| `private.el` | everything else of ours, each part commented |
| `emacs.fish` | `emacs` as emacsclient, `EDITOR`, `COLORTERM` |
| `emacsd/run`, `emacsd/log/run` | the Termux runit service and its log |
