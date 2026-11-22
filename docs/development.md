# Development

## Layout

```text
init.lua            Load order: plugins, options, autocmds, keybinds, GUI
options.lua         Editor options
autocmds.lua        Global autocommands
keybinds/           Global keymaps, one file per area
graphical/          Neovide and Neovim-Qt settings
plugins/
  picker/           Shared fuzzy picker and statusline
  malleable/        Shared core for rendered and editable buffers
  keel/             Git interface
  harbor/           Editable file explorer
  projects/         Project picker
  anchor/           Per-project file slots
  scope/            File finding and live grep
  lc/               lcclone integration
  syntax/           Declarative highlighting
  glacier/          Terminal
  preview/          Per-filetype preview commands
docs/               This documentation
.github/            CI workflow and test runner
```

Each plugin is `plugins/<name>/init.lua` with a `setup()`, called from the root `init.lua`. Its global keys go in `keybinds/<name>.lua`, registered in `keybinds/init.lua`. A plugin's header comment is the most detailed reference for how it works.

## Guidelines

- Support Neovim 0.10+ on Windows, Linux, and macOS. Windows and Linux are the primary targets.
- Prefer `vim.fs`, `vim.uv`, and list-form `jobstart` over shell strings and platform-specific tools.
- Use `jobstart` when a process's full output matters. On Neovim 0.10, `vim.system` can lose the end of it.
- Use extmarks rather than `:syn` rules from a `FileType` autocmd, because Neovim's syntax setup clears those.
- Never commit `overrides.lua`.

## Picker

`neo.plugins.picker` is the shared fuzzy picker. Items are tables with a `display` string plus any data of your own.

```lua
local picker = require("neo.plugins.picker")

picker.open({
    title = " Projects ",
    items = { { display = "neo", path = "~/.config/nvim/lua/neo" } },
    on_select = function(item)
        vim.cmd("cd " .. vim.fn.fnameescape(item.path))
    end,
    keys = {
        ["<C-x>"] = function(p) p:close() end,
    },
    footer = " <C-x> close ",
})
```

The full option and controller reference is at the top of `plugins/picker/init.lua`.

## Malleable buffers

`neo.plugins.malleable` is the core under Keel and Harbor. It owns the buffer's lifecycle, safe redraws, keys, and the shape of a write. What the lines mean and what a write does stay in each plugin.

```lua
local malleable = require("neo.plugins.malleable")

local view, created = malleable.open({
    name = "myplugin://" .. dir,
    filetype = "myplugin",
    editable = true,
    on_write = function(view, done)
        apply(view, function(ok) done(ok) end)
    end,
    on_reload = function(view) redecorate(view) end,
    on_wipe = function(view) cleanup(view) end,
    keys = {
        { "<CR>", open_entry, desc = "Open" },
        { "s", stage, desc = "Stage", mode = { "n", "x" } },
    },
})

vim.api.nvim_win_set_buf(0, view.buf)

view:when_stable(function()
    view:replace(lines, { cursor = function(win, old_row) return new_row end })
    decorate(view.ns)
end)
```

| API | Description |
|---|---|
| `malleable.open(opts)` | Returns the view for `name` and whether it was created. Never touches windows |
| `view:replace(lines, opts)` | Replaces the lines, keeps each window's view, and clears `view.ns`. Returns `false` on a modified editable buffer unless `force = true` |
| `view:when_stable(fn)` | Runs `fn` now, or holds it until the current window leaves any mode but plain Normal |
| `view:help()` | Opens the generated key list |
| `malleable.confirm(opts)` | A yes/no float taking `title`, `lines`, `on_yes`, and `on_no`. Only `y` says yes |
| `malleable.unsaved()` | Views with unsaved edits |

The rules that keep these safe:

- Wrap row-changing refreshes in `when_stable`, so they can't move a Visual selection or a pending `:'<,'>` range.
- `on_write` must call `done(true)` or `done(false)`. A second `:w` doesn't run while a write is pending.
- Open a confirm from `vim.schedule` inside `on_write`. Focus returns to the view when `:w` ends.
- `:w other-file` writes a plain copy and never calls `on_write`.
- Don't combine `replace` with manual folds. Render collapsed content by leaving it out.

## Tests

Each plugin with tests has a standalone `test.lua` that needs no setup. Run one:

```bash
nvim --headless --clean -l plugins/keel/test.lua
```

Run all of them, with one result per plugin:

```bash
nvim --headless --clean -l .github/run-plugin-tests.lua
```

Tests must work on all three platforms. Common traps are `\` in paths on Windows, 8.3 short temp paths such as `RUNNER~1`, file names Windows forbids, and home directories that come from `USERPROFILE`.

## CI

[`.github/workflows/plugin-tests.yml`](../.github/workflows/plugin-tests.yml) runs on every push, across Windows, Linux, and macOS with Neovim 0.10.4 and stable. Each plugin runs in its own process, so one that fails, crashes, or hangs can't hide the others.

## Versioning

This repository uses [Semantic Versioning](https://semver.org). Its public API is the keybindings, commands, `overrides.lua` options, and minimum Neovim version.

| Bump | When |
|---|---|
| Major | Changes or removes any of those, or raises the minimum Neovim version |
| Minor | Adds a plugin, command, keybinding, or option without changing existing ones |
| Patch | Fixes a bug, or changes only tests or docs |

Tag meaningful milestones rather than every merge, using annotated tags such as `v1.1.0`.
