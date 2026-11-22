# Keybindings and commands

The leader key is `Space`. Keys that only work inside a tool's own buffer are listed on that tool's page.

## General

| Key | Mode | Action |
|---|---|---|
| `<C-;>` | Normal, Visual | Save |
| `<C-;>` | Insert | Leave Insert mode and save |
| `<C-;>` | Terminal | Leave Terminal mode |
| `<C-h>` | Normal | Switch to the alternate buffer |
| `<C-d>` | Normal | Scroll down and center |
| `<C-u>` | Normal | Scroll up and center |
| `n` | Normal | Next search result, centered |
| `N` | Normal | Previous search result, centered |
| `<leader>e` | Normal | New empty buffer |
| `<leader>nv` | Normal | Clear search highlighting |
| `<leader>cc` | Normal | Set the working directory to the current file's directory |
| `<leader>ch` | Normal | Set the working directory to home |
| `<leader>cn` | Normal | Set the working directory to this config |

## Tools

| Key | Action | Details |
|---|---|---|
| `<leader>g` | Git status | [Keel](plugins/keel.md) |
| `<leader>f` | File explorer | [Harbor](plugins/harbor.md) |
| `<leader>o` | Select a project | [Projects](plugins/projects.md) |
| `<leader>l` | Find files | [Scope](plugins/scope.md) |
| `<leader>h` | Live grep | [Scope](plugins/scope.md) |
| `<leader>a` | Anchor the current file | [Anchor](plugins/anchor.md) |
| `<leader>m` | Edit the anchor list | [Anchor](plugins/anchor.md) |
| `<C-p>` | Open anchor slot 1 | [Anchor](plugins/anchor.md) |
| `<C-t>` | Open anchor slot 2 | [Anchor](plugins/anchor.md) |
| `<C-s>` | Open anchor slot 3 | [Anchor](plugins/anchor.md) |
| `<C-n>` | Open anchor slot 4 | [Anchor](plugins/anchor.md) |
| `<C-CR>` | Open the terminal | [Terminal and preview](plugins/terminal-and-preview.md) |
| `<leader>p` | Run the filetype's preview | [Terminal and preview](plugins/terminal-and-preview.md) |

## lc

These exist only when the [lc](plugins/lc.md) plugin is active.

| Key | Action |
|---|---|
| `<leader>tl` | Pick a problem |
| `<leader>tt` | Test the solution |
| `<leader>ts` | Submit the solution |
| `<leader>tr` | Show the last result |
| `<leader>tx` | Cancel the run |

## Neovide

| Key | Mode | Action |
|---|---|---|
| `<F11>` | Normal | Toggle fullscreen |
| `<C-=>` | Normal, Visual | Zoom in |
| `<C-->` | Normal, Visual | Zoom out |
| `<C-0>` | Normal, Visual | Reset zoom |

## Commands

| Command | Action |
|---|---|
| `:Keel` | Open the Git status view |
| `:Harbor [dir]` | Open a directory as an editable listing |
| `:Projects` | Open the project picker |
| `:Projects new [name]` | Create a project |
| `:Projects track [path]` | Track a directory |
| `:Projects untrack [path]` | Stop tracking an entry |
| `:Projects delete [path]` | Delete a project from disk |
| `:Anchor` | Edit the anchor list |
| `:Anchor add` | Anchor the current file |
| `:Anchor remove` | Empty the current file's slot |
| `:Anchor menu` | Edit the anchor list |
| `:Anchor {N}` | Open the file in slot N |
| `:ScopeFiles` | Find files |
| `:ScopeGrep` | Live grep |
| `:Lc {command}` | Run an lc command, listed on the [lc page](plugins/lc.md) |
