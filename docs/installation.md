# Installation

## Requirements

| Dependency | Needed for | Required |
|---|---|---|
| Neovim 0.10+ | Everything | Yes |
| Git | Keel, cloning projects | Yes |
| ripgrep | Faster live grep that honors `.gitignore` natively | No |
| `wl-clipboard` or `xclip` | The system clipboard on Linux | No |
| UbuntuMono Nerd Font | The default GUI font | No |
| lcclone | The `lc` plugin | No |

Without ripgrep, live grep falls back to `findstr` on Windows and `grep` elsewhere.

## Install

The config loads as the Lua module `neo`, so the repository must be at `lua/neo` inside Neovim's config directory:

| Platform | Location |
|---|---|
| Linux, macOS | `~/.config/nvim/lua/neo` |
| Windows | `%LOCALAPPDATA%\nvim\lua\neo` |

Run `:echo stdpath("config")` in Neovim if you're not sure where your config directory is.

Back up any existing config, then on Linux or macOS run:

```bash
git clone https://github.com/DrewDalmedo/neoRC.git ~/.config/nvim/lua/neo
```

```bash
echo 'require("neo")' >> ~/.config/nvim/init.lua
```

On Windows, in PowerShell:

```powershell
git clone https://github.com/DrewDalmedo/neoRC.git "$env:LOCALAPPDATA\nvim\lua\neo"
```

```powershell
Add-Content "$env:LOCALAPPDATA\nvim\init.lua" 'require("neo")'
```

Start Neovim and press `Space` then `g` inside a Git repository. The Keel status view should open.

## Update

```bash
git -C ~/.config/nvim/lua/neo pull
```

Check the [release notes](https://github.com/DrewDalmedo/neoRC/releases) first. A major version can change keybindings, commands, or `overrides.lua` options.

## Pin a release

```bash
git -C ~/.config/nvim/lua/neo checkout v1.1.0
```

To go back to the latest version:

```bash
git -C ~/.config/nvim/lua/neo switch main
```

## Per-machine settings

Put anything specific to one machine in `lua/neo/overrides.lua`. Git ignores this file, so updates never overwrite it. See [Configuration](configuration.md).

## Saved data

Anchor lists and tracked projects are stored in Neovim's data directory, separately from the repository:

| Data | File |
|---|---|
| Anchor lists | `stdpath("data")/neo/anchor.json` |
| Tracked projects | `stdpath("data")/neo/projects.json` |

## Troubleshooting

- **Nothing loads:** check that your `init.lua` contains `require("neo")` and the repository is at `lua/neo`.
- **`<leader>g` says git isn't installed:** make sure `git` is on the `PATH` Neovim sees.
- **Yank doesn't reach the system clipboard on Linux:** install `wl-clipboard` or `xclip`, then check the clipboard section of `:checkhealth`.
- **`lc` commands don't exist:** the plugin only loads when the `lc` command is available and you're not on native Windows. Run `:checkhealth neo.plugins.lc`.
