-- custom_highlights.lua

local M = {}

function M.setup()
  -- カラーパレットの定義
  local colors = {
    conversation = "#FF7F50", -- コーラル
    aozora_note = "#32CD32",  -- ライムグリーン
    ruby = "#1E90FF",          -- ドジャーブルー
    bouten = "#FFD700",        -- ゴールド
    number_unit = "#BA55D3",   -- ミディアムオーキッド
  }

  -- ハイライトグループの設定
  vim.api.nvim_set_hl(0, "ConversationHighlight", { fg = colors.conversation, bold = true })
  vim.api.nvim_set_hl(0, "AozoraNoteHighlight", { fg = colors.aozora_note, italic = true })
  vim.api.nvim_set_hl(0, "RubyHighlight", { fg = colors.ruby, underline = true })
  vim.api.nvim_set_hl(0, "BoutenHighlight", { fg = colors.bouten, bold = true, underline = true })
  vim.api.nvim_set_hl(0, "NumberUnitHighlight", { fg = colors.number_unit, bold = true })

  -- パターンの定義
  local patterns = {
    conversation = "「[^」]*」",
    aozora_note = "［＃[^］]*］",
    ruby = "｜[^｜]*《[^》]*》",
    bouten = "［＃「[^」]*」に傍点］",
    number_unit = "%d+%s*[%aぁ-んァ-ン一-龥]+",
  }


  -- ハイライトを適用する関数
  local function apply_custom_highlights()
    -- 既存のマッチを削除
    if vim.g.conversation_match_id then
      pcall(vim.fn.matchdelete, vim.g.conversation_match_id)
    end
    if vim.g.aozora_note_match_id then
      pcall(vim.fn.matchdelete, vim.g.aozora_note_match_id)
    end
    if vim.g.ruby_match_id then
      pcall(vim.fn.matchdelete, vim.g.ruby_match_id)
    end
    if vim.g.bouten_match_id then
      pcall(vim.fn.matchdelete, vim.g.bouten_match_id)
    end
    if vim.g.number_unit_match_id then
      pcall(vim.fn.matchdelete, vim.g.number_unit_match_id)
    end

    -- 新しいマッチを追加
    vim.g.conversation_match_id = vim.fn.matchadd("ConversationHighlight", patterns.conversation, 100)
    vim.g.aozora_note_match_id = vim.fn.matchadd("AozoraNoteHighlight", patterns.aozora_note, 100)
    vim.g.ruby_match_id = vim.fn.matchadd("RubyHighlight", patterns.ruby, 100)
    vim.g.bouten_match_id = vim.fn.matchadd("BoutenHighlight", patterns.bouten, 100)
    vim.g.number_unit_match_id = vim.fn.matchadd("NumberUnitHighlight", patterns.number_unit, 100)

    -- vim.notify("Custom highlights applied", vim.log.levels.INFO)
  end

  vim.api.nvim_create_autocmd({"BufRead", "BufEnter"}, {
    pattern = "*.txt",
    callback = apply_custom_highlights,
  })


end

return M

