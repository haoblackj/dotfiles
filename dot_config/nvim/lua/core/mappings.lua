local map = vim.api.nvim_set_keymap
local opts = { noremap = true, silent = true }

-- Clipboardからペースト可能
map('v', '<C-c>', '"+y', opts)

-- qでquit (コメントアウトされているのでここでは記述しない)
-- map('n', 'q', ':q<CR>', opts)

-- qqでqの代わりをする (コメントアウトされているのでここでは記述しない)
-- map('n', 'qq', 'q', opts)

-- ESCの2回押しでハイライト消去
map('n', '<ESC><ESC>', ':nohlsearch<CR>', opts)

-- 画面行の移動
map('n', 'k', 'gk', opts)
map('n', 'gk', 'k', opts)
map('n', 'j', 'gj', opts)
map('n', 'gj', 'j', opts)
