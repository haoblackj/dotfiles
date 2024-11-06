-- clever-f.vim 専用の Lua ファイルとして設定

-- Lazy.nvim プラグインの設定
return {
  {
    'rhysd/clever-f.vim',
    lazy = false,
    config = function()
      -- clever-f.vimの設定
      vim.g.clever_f_across_no_line = 1
      vim.g.clever_f_ignore_case = 1
      vim.g.clever_f_smart_case = 1
      vim.g.clever_f_chars_match_any_signs = ';'
      vim.g.clever_f_use_migemo = 1
    end
  }
}

-- 上記の設定により、clever-f.vimがNeovimに追加され、必要な設定が自動で適用されます。

