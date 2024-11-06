return {
    "nvimtools/none-ls.nvim",
    config = function()
        local none_ls = require("null-ls")

        none_ls.setup({
            sources = {
                none_ls.builtins.diagnostics.textlint.with({
                    filetypes = { "text" }
                }),
                none_ls.builtins.formatting.textlint.with({
                    filetypes = { "text" }
                }),
            },
        })

        vim.api.nvim_create_autocmd("BufWritePost", {
            pattern = { "*.md", "*.txt" },
            callback = function()
                vim.lsp.buf.format({ async = true })
            end,
        })
    end,
}
