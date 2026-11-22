# Projects

A project picker. Open it with `<leader>o` or `:Projects`.

A project is normally a subdirectory of a tracked directory, shown with the parent's name as a tag:

```text
Embedded   blinky
Projects   neo
Neovim     Config
```

The fuzzy prompt matches the whole line, so `emb bl` finds `blinky`.

## Picker keys

| Key | Action |
|---|---|
| `<CR>` | Switch to the project, or open a file entry |
| `<C-n>` | Create a project, or clone one from a Git URL |
| `<C-t>` | Track a directory |
| `<C-x>` | Untrack an entry, optionally deleting it from disk |
| `<C-d>` | Delete the highlighted project from disk, after asking |

The [shared picker keys](scope.md#picker-keys) also work: `<Up>`, `<Down>`, `<Esc>`, `j`, `k`, `gg`, `go`, and `G`.

## Commands

| Command | Action |
|---|---|
| `:Projects` | Open the picker |
| `:Projects new [name]` | Create a project |
| `:Projects track [path]` | Track a directory |
| `:Projects untrack [path]` | Stop tracking an entry |
| `:Projects delete [path]` | Delete a project from disk |

## Switching projects

A switch gives you a clean editor in the new project:

1. Modified files are saved. A file that can't be saved stays open with an error.
2. Other buffers, tabs, and windows are closed. Scratch, terminal, and unnamed buffers are discarded.
3. The working directory moves to the project.
4. [Harbor](harbor.md) opens on the project root.

If a Keel commit message or a Harbor listing has unsaved edits, Projects names them and asks first. Anything but `y` leaves your project, windows, and buffers as they were.

## Creating and cloning

`<C-n>` asks which tracked directory to use, unless only one can hold projects, then asks for a name. Instead of a name, you can enter:

- a Git URL such as `https://...` or `git@host:...`, optionally followed by a directory name
- a whole `git clone ...` line

The clone runs in the background, so the editor stays usable. When it finishes, Projects switches into it. If you have unsaved edits by then, it stays where you are and tells you where the clone went.

Git runs without a terminal here, so a clone that needs a password or host confirmation fails and says why.

## Tracked directories

The set is decided at startup, and the first of these wins:

1. `require("neo.plugins.projects").setup({ dirs = ... })`
2. The `projects` section of [`overrides.lua`](../configuration.md#projects), added to the defaults
3. The defaults: `~/Projects` and this config

Directories you track or untrack from the picker are saved per machine in `stdpath("data")/neo/projects.json` and applied on top.

## Deleting

Deleting never touches your home directory, a filesystem root, anything containing one, or anything overlapping Neovim's config. A symlink is removed itself, never its target.
