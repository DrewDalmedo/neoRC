local preview = require("neo.plugins.preview")

map("n", "<leader>p", function()
    preview.run_preview()
end)

preview.register("lua", "echo 'Works!'")
