local fn = vim.fn
local command = vim.api.nvim_command

local install_path = fn.stdpath('data')..'/site/autoload/plug.vim'

-- Vim-plugがインストールされていない場合、gitからvim-plugをインストールします
if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({'curl', '-fLo', install_path, '--create-dirs',
    'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'})
end

-- Vim-Plugのインストールが完了したら、以下のコードでプラグインをインストールします
vim.defer_fn(function()
    -- プラグインの設定を開始
    command [[call plug#begin('~/.local/share/nvim/plugged')]]
    -- 必要なプラグインを指定
    command [[Plug 'junegunn/vim-easy-align']]
    -- プラグイン設定の終了
    command [[call plug#end()]]

    -- プラグインをインストールし、設定ファイルを再読込
    command 'PlugInstall --sync | source $MYVIMRC'

    -- 個人の環境に合わせたオプション設定
    -- 新しいオプション設定を追加したい場合、luaフォルダ内に新しいフォルダを作成し、
    -- そのパスをここでrequireすることで設定を読み込むことができます
    require('plugins.vim-easy-align')
end, 0)

-- このsetup_plugin.luaはinit.luaからrequireされることで、
-- プラグインを使用する準備が整います。
-- vim-plugはインストールされたプラグインを自動的に認識し、
-- 既にインストールされているプラグインはスキップされます。
