-- Kensaku関連のプラグインとその依存関係
return {
    {
        'lambdalisue/kensaku-search.vim',
        dependencies = {
            {
                'lambdalisue/kensaku.vim',
                dependencies = {
                    {
                        'vim-denops/denops.vim',
                        -- vim-denops/denops.vim の追加の設定や関数をここに記述
                    }
                },
                -- lambdalisue/kensaku.vim の追加の設定や関数をここに記述
            }
        },
        -- lambdalisue/kensaku-search.vim の追加の設定や関数をここに記述
    }
}
