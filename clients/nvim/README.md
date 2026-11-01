# Neovim on the clients

This is the Neovim config for the phone (Termux) and for Arch in WSL on the laptop. It is
LazyVim with three changes: `ty` and `ruff` for Python, language servers from the system
package manager instead of Mason, and fill-in-the-middle completion from a llama-server
through `llama.vim`.

## Set it up

Run the play from `ansible/` on the client itself:

```sh
cd ~/infra/ansible
ansible-playbook playbooks/client-home-nvim.yml        # Termux
ansible-playbook playbooks/client-home-nvim.yml -K     # Arch, when a package is missing
```

The play installs the packages and links `~/.config/nvim` to this directory. It then
installs the plugins at the pinned commits, compiles the syntax parsers, and checks that
`ty` and `ruff` attach. It refuses an existing `~/.config/nvim` that it did not make and
prints the two `mv` commands that move it and its plugin data aside.

A first run downloads about 60 MB after the packages and their package lists: 50 MB of
plugin history from GitHub, 9 MB of parser sources, 2 MB for `blink.cmp`'s matcher. Later
runs download only what `lazy-lock.json` moved.

## Keys worth knowing

Space opens a menu of every leader key, and `Space s k` searches all keybinds by name.
`nvim +Tutor` teaches the motions, as `hx --tutor` does in Helix.

The look is LazyVim's own, with four changes for a phone held upright: the command
line sits on the bottom line, long lines wrap as in Helix (at a word, keeping their
indent, marked `↪`), inlay hints start off, and inline diagnostic text shows on the
cursor's line only. Anything more is LazyVim's to maintain, not this config's.

| Key | Does |
|---|---|
| `gd` / `gr` / `K` | definition, references, hover (from `ty`) |
| `u` / `U` | undo / redo; `U` is redo here, as in Helix |
| `Space c f` | format; saving formats too, with `ruff` |
| `Space u h` | inlay hints on or off (`ty` draws types inline) |
| Tab | in insert mode, accepts the grey suggestion from llama-server |
| Shift-Tab | accepts the suggestion's first line only |
| `Space a i` | on a selection, sends an instruction to llama-server |
| `Space a a` / `Space a x` | accepts / cancels the instruction's result |
| `Space a r` / `Space a c` | reruns / continues the instruction |

## The completion server

With nothing set, `llama.vim` asks `http://127.0.0.1:8080/infill`, llama-server's own
default port. On the phone, `ssh g14` puts the laptop's llama-server there, through a
tunnel that `client-home-ssh-config.yml` sets up with the laptop's host key pinned, and
`ssh -O exit g14` takes it down; `docs/ssh-clients.md` § The laptop says why a tunnel
and not the laptop's LAN address. These change where it asks, and none of them is
tracked:

| Set | When |
|---|---|
| `LLAMA_BASE_URL` | the server is elsewhere: `http://host:port`, with or without `/v1` |
| `LLAMA_FIM_ENDPOINT` | the full `/infill` URL; it wins over `LLAMA_BASE_URL` |
| `LLAMA_FIM_MODEL` | llama-server runs in router mode: the completion model's name |
| `LLAMA_INST_MODEL` | instructions should use a different model from completion |
| `LLAMA_API_KEY` | llama-server has `--api-key`: the key |
| `~/.config/llama/api-key` | the key from a file instead: one line, mode 600 |

**With llama-server's router, `LLAMA_FIM_MODEL` is required.** The router picks the
model from each request's `model` field and refuses a request without one, and
`llama.vim` drops that refusal silently: no suggestions and no message. Set it to a name
or alias from the router's `/v1/models`. The router loads a model on its first request,
so the first suggestion waits for that. With `--models-max 1`, a `LLAMA_INST_MODEL` that
differs from the completion model swaps the two in and out of memory. `:LlamaStatus`
shows whether each model is configured and loaded.

`llama.vim` passes the key to `curl` on its command line, so another local user can read
it from the process list while a request runs. Neovim warns at start when the key file is
readable by others.

In WSL with its default NAT networking, `127.0.0.1` is the Linux side, and the Windows
host is the default route's gateway. Exporting that as `LLAMA_BASE_URL`, as the owner's
fish config does, reaches a llama-server on Windows that listens beyond `127.0.0.1` and
that Windows Firewall lets in:

```fish
set -gx LLAMA_BASE_URL "http://"(ip route show default | awk '{print $3}')":8080"
```

When the server is not reachable, suggestions are off and editing carries on as plain
Neovim, with one notice saying so. Neovim asks the server's `/health` as it starts and
then at most every 20 seconds while you type, so suggestions come back on their own when
the server answers, with a second notice, and go off again if it disappears. A request
that fails between two checks shows for two seconds in the bottom right corner.
`:LlamaStatus` shows what the server reports.

## Updating the plugins

`lazy-lock.json` pins every plugin to a commit, so the phone and the laptop run the same
code. To move the pins:

1. Run `:Lazy update` in Neovim. It rewrites `lazy-lock.json` in this checkout.
2. Use the editor for a while. A plugin that broke is rolled back with `:Lazy restore`
   and `git checkout clients/nvim/lazy-lock.json`.
3. Commit the lock file.
4. On the other client, pull and run the play, or run `:Lazy restore` there.

When `:Lazy restore` cannot reach a pinned commit, on a weak signal for example, it
reports no error and rewrites `lazy-lock.json` to the commits it was left on. `git diff`
shows that, and `git checkout clients/nvim/lazy-lock.json` undoes it. The play checks each
plugin against the lock itself and leaves the file alone.

Nothing checks for updates in the background, because the phone is on a metered
connection.

## The files

| File | Holds |
|---|---|
| `init.lua` | where LazyVim keeps its per-client state, then the plugin manager |
| `lua/config/lazy.lua` | the plugin list: LazyVim, its Python extra, and `lua/plugins/` |
| `lua/config/options.lua` | `ty` and `ruff` as the Python servers; Helix's soft wrap |
| `lua/config/keymaps.lua` | `U` as redo |
| `lua/plugins/lsp.lua` | Mason off, servers from the system |
| `lua/plugins/llama.lua` | `llama.vim`: its settings, its keys, its failure message |
| `lua/plugins/treesitter.lua` | parsers compile four at a time, for the phone's memory |
| `lua/plugins/ui.lua` | the command line at the bottom; fewer inline hints, for portrait |
| `lazy-lock.json` | the plugin commits |

LazyVim's per-client file, `lazyvim.json`, lives in Neovim's state directory rather than
here. Extras picked with `:LazyExtras` therefore stay on the client that picked them. An
extra every client should have goes in `lua/config/lazy.lua`.
