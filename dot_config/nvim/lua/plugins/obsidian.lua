return {
  'obsidian-nvim/obsidian.nvim',
  version = '*',
  lazy = true,
  ft = 'markdown',
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {
    legacy_commands = false,
    workspaces = {
      { name = 'penguinEx-novel', path = '~/repo/github.com/haoblackj/penguinEx/novel' },
    },
    picker = { name = 'telescope.nvim' },
  },
}
