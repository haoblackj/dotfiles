  -- キーマッピングの設定
  local map = vim.keymap.set
  local opts = { noremap = true, silent = true }

  -- リーダーキーをスペースに設定
  vim.g.mapleader = ' '

  -- jキーを二度押しでESCキーと同様に扱う
  map('i', 'jj', '<Esc>', opts)
  map('i', 'っj', '<ESC>', opts)

  -- 自動でカッコ等を閉じる
  map('i', '{', '{}<Left>', opts)
  map('i', '[', '[]<Left>', opts)
  map('i', '(', '()<Left>', opts)
  map('i', '"', '""<Left>', opts)
  map('i', "'", "''<Left>", opts)
  map('i', '「', '「」<Left>', opts)
  map('i', '『', '『』<Left>', opts)
  map('i', '〈', '〈〉<Left>', opts)
  map('i', '《', '《》<Left>', opts)

  -- 'S'を押すと、画面内の文字列に英数字入力でfuzzymotionできるようにする
  map('n', 'S', ':FuzzyMotion<CR>', opts)

  -- 論理行と表示行の移動をスワップする（VSCodeではスキップ）
  if not vim.g.vscode then
  map('n', 'k', 'gk', opts)
  map('n', 'gk', 'k', opts)
  map('n', 'j', 'gj', opts)
  map('n', 'gj', 'j', opts)
  map('n', '0', 'g0', opts)
  map('n', 'g0', '0', opts)
  map('n', '^', 'g^', opts)
  map('n', 'g^', '^', opts)
  map('n', '$', 'g$', opts)
  map('n', 'g$', '$', opts)
  map('i', '<Down>', '<C-o>gj', opts)
  map('i', '<Up>', '<C-o>gk', opts)
  end

  -- lazygitを呼び出すキーマップ
  map('n', '<leader>gg', ':LazyGit<CR>', opts)