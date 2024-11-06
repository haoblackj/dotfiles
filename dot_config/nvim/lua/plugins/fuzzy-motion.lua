-- fuzzy-motion.vim 専用の Lua ファイルとして設定

-- Lazy.nvim プラグインの設定
return {
  {
    'yuki-yano/fuzzy-motion.vim',
    lazy = false,
    config = function()
      -- キーマッピングの設定
      vim.keymap.set('n', 'S', '<cmd>FuzzyMotion<CR>')
      vim.g.fuzzy_motion_matchers = { 'kensaku', 'fzf' }
    end
  }
}

