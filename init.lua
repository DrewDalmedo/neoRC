vim.g.mapleader = " "

require("neo.plugins.scope").setup()
require("neo.plugins.projects").setup()
require("neo.plugins.syntax").setup()

require("neo.options")
require("neo.autocmds")
require("neo.keybinds")
require("neo.graphical").setup()

