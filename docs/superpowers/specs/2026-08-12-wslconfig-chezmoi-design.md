# .wslconfig を chezmoi 管理へ移す

作成日: 2026-08-12

## 解決する問題

WSL2 のホスト側設定 `.wslconfig`(Windows のユーザーホーム直下)が、chezmoi ではなく `haoblackj/_windows11-dotfiles` にプレーンファイルとして置かれている。

このリポジトリはブートストラップ専用で、マシンごとの差分を表現する手段を持たない。
そのため 2026-08-12 に QwenImage LoRA 学習(musubi-tuner の `blocks_to_swap` による RAM オフロード)向けへ `memory=48GB` を書いたコミット `5d52122` は、そのまま職場 PC など物理メモリの少ない機械へ展開すると、WSL2 が物理を超える確保を試みて Windows 側のページファイルに落ち、体感が著しく重くなる。
このリスクを避けるため `5d52122` は push を保留したままになっている。

chezmoi 側にはマシン識別の仕組みが既にあり、Windows ネイティブでの `chezmoi apply` 運用も確立している。
`.wslconfig` をそちらへ移し、マシンごとに内容を変えられるようにする。

## 検証済みの前提

以下はすべて 2026-08-12 に実機で確認した。

Windows の `COMPUTERNAME` は `HIRO-DESKTOP02` で、WSL 側の `chezmoi.hostname` も同じ値を返す。
よって hostname による分岐は Windows ネイティブ実行でも WSL 実行でも同一の結果になる。

`chezmoi execute-template` で `hasPrefix` が使えることを確認した。
`HIRO-DESKTOP02` と `HIRO-DESKTOP03` は一致し、`HIRO-LAPTOP01` と `ESCO-PC-1234` は一致しない。

`.wslconfig` の `memory` を指定しなかった場合、WSL2 は総物理メモリの 50% を割り当てる([公式ドキュメント](https://learn.microsoft.com/windows/wsl/wsl-config#wslconfig))。
つまり `memory` 行を出力しないことが、そのまま安全側の既定値になる。

`_windows11-dotfiles` の README 手順 8 に `chezmoi init --apply haoblackj` があり、Windows 側で chezmoi をネイティブ実行する運用は既に存在する。
chezmoi ソースには komorebi、whkd、yasb、Windows Terminal の設定が入っており、実際に配布されている。

メインPCの実機 `.wslconfig` には現在 `memory` 行が無い。
`5d52122` の内容はまだ実機に反映されていない。

## 設計

### 1. `dot_wslconfig.tmpl` を chezmoi ソースルートに追加

```
[wsl2]
{{- if hasPrefix "HIRO-DESKTOP" .chezmoi.hostname }}
memory=48GB
{{- end }}
networkingMode=Mirrored

[experimental]
hostAddressLoopback=true
```

Windows 側で `chezmoi apply` すると `C:\Users\yagu001\.wslconfig` に着地する。
`HIRO-DESKTOP` で始まらないホスト名では `memory` 行が出力されず、WSL2 の既定(物理の 50%)が効く。

判定キーに `.chezmoi.toml.tmpl` の `location`(自宅なら `home`)ではなく hostname のプレフィックスを選んだ。
`location` は `USERDOMAIN` が `HIRO` かどうかで決まるため、自宅マシン群を区別なく指してしまう。
プレフィックス判定なら、自宅であってもデスクトップ機だけに限定できる。

`HIRO-DESKTOP02` 単体の完全一致ではなくプレフィックスにしたのは、連番で `HIRO-DESKTOP03` を迎えたときにテンプレートの修正が要らないようにするため。

この形は「`HIRO-DESKTOP` を名乗る機械は物理 48GB 以上」という運用ルールを暗黙の前提に置く。
物理 48GB 未満の機械に同じ名前を振ると、上で述べたページファイル落ちが起きる。
テンプレート内で総物理メモリから比率を算出すればこの前提は不要になるが、Windows ネイティブの chezmoi でテンプレートの `output` による外部コマンド呼び出しが通るかは WSL 側からは検証できないため、確実に動くものだけで組む方針を採った。

### 2. `.chezmoiignore` の除外方向を直す

現状、`{{ if eq .chezmoi.os "windows" }}` のブロック(「Windows マシンのため対象から外す」側)に `/.wslconfig` が入っている。
これは配りたい方向と逆で、`.bashrc` や `.zshrc` といった Linux 用ファイルと並んでいることから、記述位置の誤りと判断する。

ソースファイルが存在しないため現在は無害だが、`dot_wslconfig.tmpl` を置いた時点で Windows 側の配布が止まる。

このブロックから `/.wslconfig` を削除し、`{{ if ne .chezmoi.os "windows" }}` のブロックへ移す。
WSL や Linux のホーム直下に `.wslconfig` を置いても WSL2 は読まないため、そちらでは配布しない。

### 3. `_windows11-dotfiles` から `.wslconfig` を削除

同じファイルを二つのリポジトリで管理すると、どちらが正なのか判別できなくなる。
chezmoi に一本化し、`_windows11-dotfiles` からは削除する。

未 push のコミット `5d52122` は revert せず残し、削除コミットを重ねる。
`memory=48GB` に至った経緯が履歴から追えるほうが後で役に立つ。

README の手順 8(`chezmoi init --apply`)が `.wslconfig` の配布も担うようになるが、手順自体に変更は要らない。

### 4. 実機への反映

メインPCの Windows 側で `chezmoi update` を実行し、`wsl --shutdown` してから WSL を起動し直す。
`.wslconfig` は WSL2 の VM 起動時にのみ読まれるため、再起動しなければ反映されない。

この反映で `memory=48GB` が初めて実機に効く。

## 検証方法

`chezmoi execute-template` に `dot_wslconfig.tmpl` を通し、二通りの出力を目視で確認する。

`HIRO-DESKTOP02` を渡したとき `memory=48GB` を含む 6 行が出ること。
`HIRO-DESKTOP` で始まらないホスト名を渡したとき `memory` 行が消え、`[wsl2]` セクションが `networkingMode` だけになること。

生成結果が `.wslconfig` として妥当な INI であること(セクションヘッダ直後に空行が入らず、`[experimental]` の前に空行が残ること)も確認する。

## 対象外

`_windows11-dotfiles` の `.gitconfig` も同様に chezmoi と重複しているが、今回は扱わない。

`memory=48GB` という値そのものの妥当性は再検討しない。
musubi-tuner の要件から決めた既存の値をそのまま移送する。
