# compact-plus install / gate results (2026-07-07)

- marketplace: compact-plus-local (github u-ichi/compact-plus)
- plugin: compact-plus@compact-plus-local (Version:1.0.2, scope user, enabled)
- plugin.json userConfig: 宣言なし → env伝播NG時の ${user_config.*}代替は不可（gate A重要）
- hook実体: ~/.claude/plugins/cache/compact-plus-local/compact-plus/<ver>/hooks/
- 宣言的設定: enabledPlugins + extraKnownMarketplaces を chezmoi source(private_settings.json)へ取り込み済（多PC再現）

## Gate A (env伝播)
- 配管サニティ: PASS — cached hookはCOMPACT_PLUS_PRIMARY_BACKEND(env)でbackendを差し替える(実測)
- 真の伝播(Claude Codeが実hook起動時にsettings.json envを注入するか): **リスタート後に最終確認**(下記まとめ検証)

## Gate B (VSCode plugin hook発火)
- **リスタート後に確認**(要リーダー操作)。settings.json hookはVSCodeで発火実績あり、plugin hookも同エンジン想定。

## 検証集約方針
build(Task2-3) → 配線(Task5) → chezmoi apply → **VSCode 1回リスタート** → Gate A/B + E2E(Task6) をまとめて確定。
