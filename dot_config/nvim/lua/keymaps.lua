-- bufferlines関連
vim.keymap.set("n", "<C-h>", "<cmd>bprev<CR>")
vim.keymap.set("n", "<C-l>", "<cmd>bnext<CR>")

-- 設定で通常の上下移動を表示行に置き換える
vim.api.nvim_set_keymap('n', 'j', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'k', 'gk', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', 'j', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', 'k', 'gk', { noremap = true, silent = true })

-- 矢印キーでの上下移動も表示行に置き換える
vim.api.nvim_set_keymap('n', '<Down>', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Up>', 'gk', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', '<Down>', 'gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', '<Up>', 'gk', { noremap = true, silent = true })

-- インサートモードでの矢印キーの上下移動も表示行に置き換える
vim.api.nvim_set_keymap('i', '<Down>', '<C-o>gj', { noremap = true, silent = true })
vim.api.nvim_set_keymap('i', '<Up>', '<C-o>gk', { noremap = true, silent = true })

-- 状態遷移系
vim.keymap.set("i", "jj", "<esc><cmd>w<CR>")
vim.keymap.set("i", "kk", "<esc><cmd>w<CR>")

-- Alt + Shift + k で行を上に移動
vim.keymap.set("n", "<A-K>", ":m .-2<CR>==", { noremap = true, silent = true })
vim.keymap.set("n", "<A-<Up>>", ":m .-2<CR>==", { noremap = true, silent = true })

-- Alt + Shift + j で行を下に移動
vim.keymap.set("n", "<A-J>", ":m .+1<CR>==", { noremap = true, silent = true })
vim.keymap.set("n", "<A-<Down>>", ":m .+1<CR>==", { noremap = true, silent = true })

