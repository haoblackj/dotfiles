-- bufferlines関連
vim.keymap.set("n", "<C-h>", "<cmd>bprev<CR>")
vim.keymap.set("n", "<C-l>", "<cmd>bnext<CR>")

-- 設定で通常の上下移動を表示行に置き換える
vim.api.nvim_set_keymap('n', 'j', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'k', 'gk', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', 'j', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', 'k', 'gk', { noremap = true, silent = true })

-- 状態遷移系
vim.keymap.set("i", "jj", "<esc><cmd>w<CR>")
vim.keymap.set("i", "kk", "<esc><cmd>w<CR>")