# Terminal and preview

## Terminal

`<C-CR>` opens one reusable terminal in the current window and enters Terminal mode. If the terminal already exists, it switches back to it.

Press `<C-;>` to leave Terminal mode.

The terminal is provided by `neo.plugins.glacier`, which also has `open_terminal_tab()` for showing it in its own tab.

## Preview

`<leader>p` runs the Ex command registered for the current filetype. If there isn't one, it shows an error.

Register commands in `keybinds/preview.lua`:

```lua
local preview = require("neo.plugins.preview")

preview.register("lua", "echo 'Works!'")
preview.register("markdown", "!glow %")
```

Only the `lua` example above is registered by default.
