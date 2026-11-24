# Configuration

## `overrides.lua`

Settings that differ between machines go in `lua/neo/overrides.lua`. Git ignores this file, so each machine keeps its own.

```lua
return {
    graphical = {
        font_family = "JetBrainsMono Nerd Font",
        font_size = 16,
    },
    projects = {
        dirs = {
            "Work",
            { "Uni", tag = "School" },
            { "Code/dotfiles", single = true },
            { "~/.wezterm.lua", file = true, name = "WezTerm" },
        },
        overwrite_defaults = false,
    },
    lc = {
        cmd = "~/.local/bin/lc",
        open = "show",
    },
}
```

Every section is optional.

## `graphical`

These apply in GUIs such as Neovide and Neovim-Qt.

| Option | Default | Description |
|---|---|---|
| `font_family` | `"UbuntuMono Nerd Font"` | The GUI font |
| `font_size` | `22` | The GUI font size |

## `projects`

| Option | Default | Description |
|---|---|---|
| `dirs` | None | Entries added to the default tracked set |
| `overwrite_defaults` | `false` | When `true`, `dirs` replaces the defaults instead of adding to them |

The defaults are `~/Projects` and this config.

An entry is a path, or a table with options:

| Entry | Meaning |
|---|---|
| `"Uni"` | Each subdirectory of `~/Uni` is a project, tagged `Uni` |
| `{ "Uni", tag = "School" }` | The same, tagged `School` |
| `{ "Work/dotfiles", single = true }` | The directory itself is one project |
| `{ "~/.wezterm.lua", file = true }` | One entry that opens a file |
| `{ "Work/neo", single = true, name = "Neo" }` | Shows under a different name |

Paths without a prefix are relative to your home directory. Paths starting with `~/`, `/`, `\\server\`, or a drive letter are used as written. Entries that don't exist are skipped, so one list can serve every machine.

Directories you track or untrack from the picker are saved per machine and applied on top of this set. See [Projects](plugins/projects.md).

## `lc`

Settings are layered in this order, with later ones winning: the defaults, this section, `vim.g.lc`, then `require("neo.plugins.lc").setup(opts)`.

| Option | Default | Description |
|---|---|---|
| `cmd` | `"lc"` | The command, as a string or a list. A leading `~/` expands |
| `picker` | `"neo"` | `"neo"` for the built-in picker, or `"select"` for `vim.ui.select` |
| `open` | `"start"` | What choosing a problem does: `"start"` or `"show"` |
| `statement` | `"leftabove vsplit"` | How the statement opens beside the solution, or `false` |
| `result` | `"botright 15split"` | How the result window opens, or `false` |
| `autowrite` | `true` | Save the problem's changed buffers before a run |
| `diagnostics` | `true` | Show compile errors and sanitizer reports as diagnostics |
| `quickfix` | `true` | Add errors and failed cases to the quickfix list |
| `notify` | `true` | Notify the verdict when a run ends |
| `keys` | See below | Keys in the result buffer. `close` and `help` apply to every lc view. Set one to `false` to disable it |

The default `keys` are `add_case = "a"`, `jump = "<CR>"`, `rerun = "r"`, `cancel = "<C-c>"`, `close = "q"`, and `help = "g?"`.

Compilers, language standards, and the workspace are lcclone's own settings, in `~/.config/lcclone/config`.

## Editor options

These are set in `options.lua`:

| Option | Value |
|---|---|
| `number`, `relativenumber` | On |
| `cursorline` | On |
| `expandtab` | On |
| `tabstop`, `shiftwidth` | `4` |
| `wrap`, `linebreak` | On |
| `autoindent`, `smartindent` | On |
| `clipboard` | `unnamedplus` |

Because of `clipboard`, yanks and deletes go to the system clipboard.

## Plugin setup options

A few plugins take options through their `setup()` call in `init.lua`:

| Plugin | Option | Default | Description |
|---|---|---|---|
| Harbor | `show_hidden` | `true` | Show dotfiles in listings |
| Anchor | `file` | `stdpath("data")/neo/anchor.json` | Where anchor lists are stored |
| Projects | `dirs` | See above | Replaces both the defaults and `overrides.lua` |
