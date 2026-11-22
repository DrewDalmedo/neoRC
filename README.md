# neo

A hand-rolled Neovim configuration with no plugin manager and no third-party plugins. Everything is written in Lua and lives in this repository.

It runs on Neovim 0.10 and later, and CI tests it on Windows, Linux, and macOS.

## What's included

| Tool | What it does | Open with |
|---|---|---|
| [Keel](docs/plugins/keel.md) | Git status, line-level staging, commits, branches, push and pull, log | `<leader>g` |
| [Harbor](docs/plugins/harbor.md) | A file explorer you edit like text | `<leader>f` |
| [Projects](docs/plugins/projects.md) | Switch, create, clone, and track projects | `<leader>o` |
| [Anchor](docs/plugins/anchor.md) | Four one-key file slots per project | `<C-p>` `<C-t>` `<C-s>` `<C-n>` |
| [Scope](docs/plugins/scope.md) | Fuzzy file finding and live grep | `<leader>l` `<leader>h` |
| [lc](docs/plugins/lc.md) | Offline coding practice through lcclone | `<leader>tl` |
| [Syntax](docs/plugins/syntax.md) | Declarative highlighting for languages Neovim doesn't ship | Automatic |
| [Terminal and preview](docs/plugins/terminal-and-preview.md) | One reusable terminal, and per-filetype preview commands | `<C-CR>` `<leader>p` |

The leader key is `Space`.

## Requirements

- [Neovim](https://neovim.io) 0.10 or later
- [Git](https://git-scm.com), for Keel and for cloning projects

Optional:

- [ripgrep](https://github.com/BurntSushi/ripgrep), for faster live grep
- A clipboard tool on Linux, such as `wl-clipboard` or `xclip`, for the system clipboard
- UbuntuMono Nerd Font, the default font in Neovide and Neovim-Qt
- lcclone, for the `lc` plugin

## Install

The repository must live at `lua/neo` inside your Neovim config directory. Back up any existing config first.

On Linux and macOS:

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

See [Installation](docs/installation.md) for updating, pinning a release, and checking your setup.

## First steps

1. Press `<leader>o` to pick a project. `Projects` in your home directory and this config are tracked by default.
2. Press `<leader>l` to find a file, or `<leader>f` to browse and edit the directory.
3. Press `<leader>a` to anchor a file, then jump back to it with `<C-p>`.
4. Press `<leader>g` to see what changed in Git. Press `g?` in any Keel or Harbor buffer to list its keys.

## Per-machine settings

Create `lua/neo/overrides.lua` for settings that differ between machines. Git ignores it.

```lua
return {
    graphical = { font_family = "JetBrainsMono Nerd Font", font_size = 16 },
    projects = { dirs = { "Work", { "Uni", tag = "School" } } },
}
```

See [Configuration](docs/configuration.md) for every option.

## Documentation

- [Installation](docs/installation.md)
- [Keybindings and commands](docs/keybindings.md)
- [Configuration](docs/configuration.md)
- Plugins: [Keel](docs/plugins/keel.md), [Harbor](docs/plugins/harbor.md), [Projects](docs/plugins/projects.md), [Anchor](docs/plugins/anchor.md), [Scope](docs/plugins/scope.md), [lc](docs/plugins/lc.md), [Syntax](docs/plugins/syntax.md), [Terminal and preview](docs/plugins/terminal-and-preview.md)
- [Development](docs/development.md), including architecture, tests, and versioning

## Platform notes

CI runs every plugin's tests on Windows, Linux, and macOS with Neovim 0.10.4 and the latest stable release. The `lc` plugin is turned off on native Windows, but works under WSL.

## License

[GNU Affero General Public License v3.0](LICENSE)
