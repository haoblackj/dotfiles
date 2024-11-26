local wezterm = require 'wezterm'

local config = wezterm.config_builder()
config.automatically_reload_config = true

front_end = "WebGPU"

-- カラースキームの設定
config.color_scheme = 'Horizon Dark (base16)'

-- ショートカットキー設定
config.keys = {
  -- Alt+Shift+Fでフルスクリーン切り替え
  {
    key = 'F',
    mods = 'ALT|SHIFT',
    action = wezterm.action.ToggleFullScreen,
  },
  -- Ctrl+Shift+Xでコピーモードの起動
  {
    key = 'x',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.ActivateCopyMode,
  },
  -- Ctrl+Shift+Vでクリップボードからペースト
  {
    key = 'v',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.PasteFrom("Clipboard"),
  },
}

-- フォントの設定
config.font = wezterm.font("Firge35Nerd Console", {weight="Medium", stretch="Normal", style="Normal"})

-- フォントサイズの設定
config.font_size = 16

-- IMEから入力できるようにする設定
config.use_ime = true

-- WSL起動設定
config.default_prog = {
  "wsl.exe",
  "--distribution",
  "Ubuntu",
  "--cd",
  "/home/yagu001",
  "--exec",
  "/bin/zsh",
  "-l"
}

-- 起動メニュー設定
config.launch_menu = {
  -- 既存のWSLの設定をここに追加（必要に応じて）
  {
    label = "Ubuntu (WSL)",
    args = {"wsl.exe", "--distribution", "Ubuntu", "--cd", "/home/yagu001", "--exec", "/bin/zsh", "-l"}
  },
  {
    label = "ArchLinux - zsh",
    args = {"wsl.exe", "--distribution", "ArchLinux", "--cd", "/home/yagu001", "--exec", "/bin/zsh", "-l"}
  },
  {
    label = "ArchLinux - bash",
    args = {"wsl.exe", "--distribution", "ArchLinux", "--cd", "/home/yagu001", "--exec", "/bin/bash", "-l"}
  },
  -- PowerShell 7.4の設定
  {
    label = "PowerShell 7.4",
    args = {"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}
  },
  -- cmdの設定
  {
    label = "Command Prompt",
    args = {"cmd.exe"}
  },
}

-- マウスの設定
config.mouse_bindings = {
  -- 右クリックでペーストする設定
  {
    event={Up={streak=1, button="Right"}},
    mods="NONE",
    action=wezterm.action{PasteFrom="Clipboard"}
  },
}

-- WSL のタブを閉じる際の挙動を設定
config.skip_close_confirmation_for_processes_named = {
  'bash',
  'sh',
  'zsh',
  'fish',
  'tmux',
  'nu',
  'cmd.exe',
  'pwsh.exe',
  'powershell.exe',
}

-- タブの設定

config.colors = {
  tab_bar = {
    -- The color of the inactive tab bar edge/divider
    -- inactive_tab_edge = '#575757',
    inactive_tab_edge = 'none',
  },
}

config.window_close_confirmation = 'NeverPrompt'

config.window_decorations="INTEGRATED_BUTTONS|RESIZE"

-- config.hide_tab_bar_if_only_one_tab = true

config.window_frame = {
  inactive_titlebar_bg = "none",
  active_titlebar_bg = "none",
  font_size = 9.0,
}

 config.window_background_gradient = {
  colors = { "#000000" },
}

-- config.show_new_tab_button_in_tab_bar = false
-- config.show_close_tab_button_in_tabs = false

local SOLID_LEFT_ARROW = wezterm.nerdfonts.ple_lower_right_triangle
local SOLID_RIGHT_ARROW = wezterm.nerdfonts.ple_upper_left_triangle

wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
  local background = "#5c6d74"
  local foreground = "#FFFFFF"
  local edge_background = "none"

  if tab.is_active then
    background = "#ae8b2d"
    foreground = "#FFFFFF"
  end
  local edge_foreground = background
  local title = "   " .. wezterm.truncate_right(tab.active_pane.title, max_width - 1) .. "   "

  return {
    { Background = { Color = edge_background } },
    { Foreground = { Color = edge_foreground } },
    { Text = SOLID_LEFT_ARROW },
    { Background = { Color = background } },
    { Foreground = { Color = foreground } },
    { Text = title },
    { Background = { Color = edge_background } },
    { Foreground = { Color = edge_foreground } },
    { Text = SOLID_RIGHT_ARROW },
  }
end)



-- 背景の設定
config.window_background_opacity = 0.8
-- config.win32_system_backdrop = 'Tabbed'

-- config.window_background_image = "C:\\WorkTmp\\mMeyexn.jpeg"
-- config.window_background_image_hsb = {
--   -- 背景画像の明るさ
--   -- 1.0で元画像から変更なし
--   brightness = 0.5,
--   -- 色相の設定
--   -- 1.0で元画像から変更なし
--   hue = 1.0,
--   -- 彩度の調整
--   -- 1.0で元画像から変更なし
--   saturation = 1.0,
-- }

-- キーバインドの設定
config.keys = require("keybinds").keys
config.key_tables = require("keybinds").key_tables

return config
