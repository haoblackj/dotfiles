-- kensaku.lua

-- Lazy.nvim プラグインの設定
return {
  {
    'vim-denops/denops.vim',
    lazy = false,
  },
  {
    'lambdalisue/kensaku-search.vim',
    lazy = false,
  },
  {
    'lambdalisue/kensaku.vim',
    lazy = false,
  },
  config = function()
    -- kensaku-search の設定
    vim.keymap.set('c', '<CR>', '<Plug>(kensaku-search-replace)<CR>')
  end
}

