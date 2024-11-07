-- plugins/spzenhan.lua

return {
  setup = function()
    -- IMEオフ設定
    if vim.fn.executable("spzenhan") == 1 then
      vim.api.nvim_create_autocmd("InsertLeave", {
        pattern = "*",
        callback = function()
          vim.fn.system("spzenhan 0")
        end,
      })

      vim.api.nvim_create_autocmd("CmdlineLeave", {
        pattern = "*",
        callback = function()
          vim.fn.system("spzenhan 0")
        end,
      })
    end
  end,
}
