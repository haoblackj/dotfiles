--Lazy.nvim
-- {'vim-denops/denops.vim', lazy = false}, --kensaku.vimの依存プラグイン。
-- {'lambdalisue/kensaku-search.vim', lazy = false}, --/キーでの検索でkensaku.vimを使うためのプラグイン。
-- {'lambdalisue/kensaku.vim', lazy = false},

--kensaku-search
vim.keymap.set('c', '<CR>', '<Plug>(kensaku-search-replace)<CR>')

--furzy-motion
vim.keymap.set('n', 'S', '<cmd>FuzzyMotion<CR>')
vim.cmd("let g:fuzzy_motion_matchers = ['kensaku', 'fzf']")

--japanese-mini.surround
require('mini.surround').setup({
    mappings = {
     highlight = 'sx',
   },
    custom_surroundings = {
    ['j'] = {
      input = function()
        local ok, val = pcall(vim.fn.getchar)
        if not ok then return end
        local char = vim.fn.nr2char(val)

        local dict = {
          ['('] = { '（().-()）' },
          ['{'] = { '｛().-()｝' },
          ['['] = { '「().-()」' },
          [']'] = { '『().-()』' },
          ['<'] = { '＜().-()＞' },
          ['"'] = { '”().-()”' },
        }

       if char == 'b' then
          local ret = {}
          for _, v in pairs(dict) do table.insert(ret, v) end
          return { ret }
        end

        if dict[char] then return dict[char] end

        error('%s is unsupported surroundings in Japanese')
      end,
      output = function()
        local ok, val = pcall(vim.fn.getchar)
        if not ok then return end
        local char = vim.fn.nr2char(val)

        local dict = {
          ['('] = { left = '（', right = '）' },
          ['{'] = { left = '｛', right = '｝' },
          ['['] = { left = '「', right = '」' },
          [']'] = { left = '『', right = '』' },
          ['<'] = { left = '＜', right = '＞' },
          ['"'] = { left = '”', right = '”' },
        }

        if not dict[char] then error('%s is unsupported surroundings in Japanese') end

        return dict[char]
      end
   }
  },
 })

 --japnese-mini.ai
 require('mini.ai').setup({
    custom_textobjects = {
    ['j'] = function()
       local ok, val = pcall(vim.fn.getchar)
       if not ok then return end
       local char = vim.fn.nr2char(val)

       local dict = {
         ['('] = { '（().-()）' },
         ['{'] = { '｛().-()｝' },
         ['['] = { '「().-()」' },
         [']'] = { '『().-()』' },
         ['<'] = { '＜().-()＞' },
         ['"'] = { '”().-()”' },
       }

       if char == 'b' then
           local ret = {}
           for _, v in pairs(dict) do table.insert(ret, v) end
           return { ret }
         end

       if dict[char] then return dict[char] end

       error('%s is unsupported textobjects in Japanese')
   end
  }
 })