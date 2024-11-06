return {
  'nvimtools/none-ls.nvim',
  dependencies = 'nvim-lua/plenary.nvim',
  config = function()
    local null_ls = require("null-ls")
    local helpers = require("null-ls.helpers")

    null_ls.setup({
        sources = {
            null_ls.builtins.diagnostics.textlint.with({
                command = "yarn",
                args = { "textlint", "--format", "unix", "--stdin" },
                filetypes = { "markdown", "text" }, -- 使用するファイルタイプ
                condition = function(utils)
                    return utils.root_has_file(".textlintrc")
                end,
            }),
        },
    })

    -- 保存時に自動的にlintを実行するautocmd設定
    vim.api.nvim_create_autocmd("BufWritePost", {
        pattern = { "*.md", "*.txt" },
        callback = function()
            vim.lsp.buf.format({ async = true })
        end,
    })
  end,
}

