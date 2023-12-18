return {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    lazy = false,
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("nvim-tree").setup({
        sort = {
          sorter = "case_sensitive",
        },
        view = {
          width = '20%',
        },
        renderer = {
          group_empty = true,
          highlight_git = true,
          highlight_opened_files = 'name',
          icons = {
            glyphs = {
              git = {
                unstaged = '!', renamed = '»', untracked = '?', deleted = '✘',
                staged = '✓', unmerged = '', ignored = '◌',
              },
            },
          },
        },
        filters = {
          dotfiles = true,
        },
      })
    end,
  }