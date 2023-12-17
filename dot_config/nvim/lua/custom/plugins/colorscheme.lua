return {
    {
        'kihachi2000/yash.nvim',
        config = function()
            require("lualine").setup {
                options = {
                    theme = "yash"
                }
            }
        end
    }
}