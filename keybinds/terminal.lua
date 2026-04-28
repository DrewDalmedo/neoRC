local terminal = require("neo.plugins.glacier")

map("n", "<C-CR>", function()
    terminal.open_terminal_buf()
end)
