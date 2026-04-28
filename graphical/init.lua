local default_font_size = 22

local font_family = "UbuntuMono Nerd Font"
local font_size = default_font_size

if vim.fn.has("win32") == 1 then
    font_size = 14
end

vim.opt.guifont = font_family .. ":h" .. font_size

if vim.g.neovide ~= nil then
    require("neo.graphical.neovide")
end
