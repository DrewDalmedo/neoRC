vim.keymap.set("n", "<leader>a", "<cmd>Anchor add<cr>", { desc = "Anchor: Add File" })
vim.keymap.set("n", "<leader>m", "<cmd>Anchor menu<cr>", { desc = "Anchor: Edit the List" })
for i = 1, 4 do
    vim.keymap.set("n", "<leader>" .. i, "<cmd>Anchor " .. i .. "<cr>", { desc = "Anchor: Go to Slot " .. i })
end
