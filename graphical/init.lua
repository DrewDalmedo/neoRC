local M = {}

M.defaults = {
    font_family = "UbuntuMono Nerd Font",
    font_size = 22,
}

function M.setup()
    local ok, cfg = pcall(require, "neo.overrides")
    local overrides = (ok and type(cfg) == "table") and cfg.graphical or {}

    local font_family = overrides.font_family or M.defaults.font_family
    local font_size = overrides.font_size or M.defaults.font_size

    vim.opt.guifont = font_family .. ":h" .. font_size

    if vim.g.neovide then
        require("neo.graphical.neovide")
    end
end

return M
