-- open File Tree when open
local function open_nvim_tree()
    require("nvim-tree.api").tree.open()
end

vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
        open_nvim_tree()
        -- nvim-treeを開いた後にカスタムハイライトを再適用
        require('custom_highlights').setup()
        -- vim.notify("Custom highlights applied after nvim-tree")
    end,
})

return {
  "nvim-tree/nvim-tree.lua",
  version = "*",
  lazy = false,
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  keys = {
    {mode = "n", "<C-n>", "<cmd>NvimTreeToggle<CR>", desc = "NvimTreeをトグルする"},
    {mode = "n", "<C-m>", "<cmd>NvimTreeFocus<CR>", desc = "NvimTreeにフォーカス"},
  },
  config = function()
    require("nvim-tree").setup {
      git = {
        enable = true,
        ignore = true,
      },
      update_focused_file = {
        enable = true,
        update_cwd = true,
      },
    }
  end,
}
