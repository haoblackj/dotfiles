return {
  "folke/persistence.nvim",
  event = "BufReadPre",
  opts = {},
  init = function()
    vim.api.nvim_create_autocmd("VimEnter", {
      callback = function()
        if vim.fn.argc() == 0 then
          require("persistence").load()
        end
      end,
    })
  end,
}
