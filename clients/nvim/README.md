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

A first run downloads about 60 MB after the packages: 50 MB of plugin history from
GitHub, 9 MB of parser sources, 2 MB for `blink.cmp`'s matcher. Later runs download only
what `lazy-lock.json` moved.

## Keys worth knowing

Space opens a menu of every leader key, and `Space s k` searches all keybinds by name.
`nvim +Tutor` teaches the motions, as `hx --tutor` does in Helix.

| Key | Does |
|---|---|
| `gd` / `gr` / `K` | definition, references, hover (from `ty`) |
| `u` / `U` | undo / redo; `U` is redo here, as in Helix |
| `Space c f` | format; saving formats too, with `ruff` |
| `Space u h` | inlay hints on or off (`ty` draws types inline) |
| Tab | in insert mode, accepts the grey suggestion from llama-server |
| Shift-Tab | accepts the suggestion's first line only |
| `Space a i` | on a selection, sends an instruction to llama-server |

## The completion server

`llama.vim` asks `http://127.0.0.1:8012/infill` by default. An ssh forward or `tailscale
serve` from the machine running llama-server puts it there. Three environment variables
and one file change that, and none of them is tracked:

| Set | When |
|---|---|
| `LLAMA_FIM_ENDPOINT` | the server is elsewhere: the full `/infill` URL |
| `LLAMA_FIM_MODEL` | llama-server runs in router mode: the completion model's name |
| `LLAMA_INST_MODEL` | instructions should use a different model from completion |
| `~/.config/llama/api-key` | llama-server runs with `--api-key`: the key, one line |

From WSL, `127.0.0.1` is the Linux side. A llama-server on Windows is reached through it
only with WSL's mirrored networking, `networkingMode=mirrored` in `.wslconfig`.
Otherwise set `LLAMA_FIM_ENDPOINT` to the Windows host's address.

With no server reachable, each failed request shows for two seconds in the bottom right
corner, and editing carries on.

## Updating the plugins

`lazy-lock.json` pins every plugin to a commit, so the phone and the laptop run the same
code. To move the pins:

1. Run `:Lazy update` in Neovim. It rewrites `lazy-lock.json` in this checkout.
2. Use the editor for a while. A plugin that broke is rolled back with `:Lazy restore`
   and `git checkout clients/nvim/lazy-lock.json`.
3. Commit the lock file.
4. On the other client, pull and run the play, or run `:Lazy restore` there.

Nothing checks for updates in the background, because the phone is on a metered
connection.

## The files

| File | Holds |
|---|---|
| `init.lua` | where LazyVim keeps its per-client state, then the plugin manager |
| `lua/config/lazy.lua` | the plugin list: LazyVim, its Python extra, and `lua/plugins/` |
| `lua/config/options.lua` | `ty` and `ruff` as the Python servers |
| `lua/config/keymaps.lua` | `U` as redo |
| `lua/plugins/lsp.lua` | Mason off, servers from the system |
| `lua/plugins/llama.lua` | `llama.vim`: its settings, its keys, its failure message |
| `lazy-lock.json` | the plugin commits |

LazyVim's per-client file, `lazyvim.json`, lives in Neovim's state directory rather than
here. Extras picked with `:LazyExtras` therefore stay on the client that picked them. An
extra every client should have goes in `lua/config/lazy.lua`.
