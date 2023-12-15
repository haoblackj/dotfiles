-- Desc: Clipboard settings
if vim.fn.has("wsl") then
  vim.g.clipboard = {
    name = "win32yank-wsl",
    copy = {
      ["+"] = "win32yank -i --crlf",
      ["*"] = "win32yank -i --crlf"
    },
    paste = {
      ["+"] = "win32yank -o --crlf",
      ["*"] = "win32yank -o --crlf"
    },
    cache_enable = 0,
  }
end