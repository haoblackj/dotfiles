import { expect, test } from 'claude-code/testing'

import type { Entry, RepoRef } from '../types'
import { fromBash, fromPrompt, keyOf, mergeFound, repoOfRemote } from '../hooks/extract'

const here: RepoRef = { owner: 'haoblackj', repo: 'dotfiles' }
const numbers = (list: { number: number }[]) => list.map(f => f.number)

test('repoOfRemote は GitHub の三つの形を読む', () => {
  for (const remote of [
    'git@github.com:haoblackj/dotfiles.git',
    'https://github.com/haoblackj/dotfiles',
    'https://github.com/haoblackj/dotfiles.git',
    'ssh://git@github.com/haoblackj/dotfiles.git',
  ]) {
    expect(repoOfRemote(remote)).toEqual(here)
  }
})

test('repoOfRemote は GitHub 以外と null を null にする', () => {
  expect(repoOfRemote('https://gitlab.com/a/b')).toBe(null)
  expect(repoOfRemote(null)).toBe(null)
})

test('プロンプトの Issue の URL を拾う', () => {
  expect(fromPrompt('https://github.com/haoblackj/dotfiles/issues/73 を見て', null)).toEqual([
    { owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'url' },
  ])
})

test('プロンプトの裸の番号はいまのリポジトリのもので、後に出たものが先', () => {
  const found = fromPrompt('#73 と #75 の続き', here)
  expect(numbers(found)).toEqual([75, 73])
  expect(found.every(f => f.source === 'bare' && f.owner === 'haoblackj')).toBe(true)
})

test('GitHub のリポジトリでなければ裸の番号は拾わない', () => {
  expect(fromPrompt('#73', null)).toEqual([])
})

test('番号に見えない形は拾わない', () => {
  for (const text of ['色は #fff', '&#123;', 'issue#12', 'https://github.com/o/r/pull/5', '#12a']) {
    expect(fromPrompt(text, here)).toEqual([])
  }
})

test('URL の後ろのコメントの錨は拾わない', () => {
  expect(fromPrompt('https://github.com/o/r/issues/5#issuecomment-99', here)).toEqual([
    { owner: 'o', repo: 'r', number: 5, source: 'url' },
  ])
})

test('gh issue create の出力の URL を拾う', () => {
  expect(
    fromBash('gh issue create --title x --body y', 'https://github.com/haoblackj/dotfiles/issues/80\n', here),
  ).toEqual([{ owner: 'haoblackj', repo: 'dotfiles', number: 80, source: 'command' }])
})

test('gh issue のコマンドが名指しした番号を拾う', () => {
  expect(fromBash('gh issue comment 73 --body-file f', '', here)).toEqual([
    { owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'command' },
  ])
  expect(fromBash('gh issue view 73', '', here)).toEqual([
    { owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'command' },
  ])
})

test('gh issue の -R と --repo はそのリポジトリにする', () => {
  for (const command of ['gh issue edit 4 -R other/thing', 'gh issue close --repo other/thing 4']) {
    expect(fromBash(command, '', here)).toEqual([{ owner: 'other', repo: 'thing', number: 4, source: 'command' }])
  }
})

test('gh issue は最初の位置引数だけを読み、フラグの値の番号や URL を拾わない', () => {
  const only73 = [{ owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'command' }]
  expect(fromBash('gh issue comment 73 --body "dup of https://github.com/o/r/issues/5"', '', here)).toEqual(only73)
  expect(fromBash('gh issue comment --body "fixed in 2 places" 73', '', here)).toEqual(only73)
  expect(fromBash("gh issue edit -t 'v 2' --add-label x 73", '', here)).toEqual(only73)
  expect(fromBash('gh issue view https://github.com/o/r/issues/4 --comments', '', here)).toEqual([
    { owner: 'o', repo: 'r', number: 4, source: 'command' },
  ])
})

test('gh api の issues のパスを拾う', () => {
  expect(
    fromBash("gh api repos/haoblackj/dotfiles/issues/73/comments --paginate | jq -rs '.'", '', null),
  ).toEqual([{ owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'command' }])
})

test('PR のコマンドと、gh issue create 以外の出力の URL は拾わない', () => {
  expect(fromBash('gh pr view 5', 'https://github.com/o/r/pull/5', here)).toEqual([])
  expect(fromBash('echo hi', 'https://github.com/o/r/issues/9', here)).toEqual([])
})

test('repo の無いところで gh issue の番号だけのものは拾わない', () => {
  expect(fromBash('gh issue view 73', '', null)).toEqual([])
})

const entry = (number: number, over: Partial<Entry> = {}): Entry => ({
  ...here,
  number,
  source: 'url',
  title: null,
  status: 'shown',
  ...over,
})

test('mergeFound は新しいものを左に足し、既にあるものを先頭へ移す', () => {
  const merged = mergeFound(
    [entry(73, { title: 'T' })],
    [
      { ...here, number: 75, source: 'bare' },
      { ...here, number: 73, source: 'url' },
    ],
  )
  expect(merged).toEqual([
    entry(75, { source: 'bare', status: 'pending' }),
    entry(73, { title: 'T' }),
  ])
})

test('mergeFound は裸で待っているものを URL で出し直されたら表示に上げる', () => {
  expect(mergeFound([entry(73, { source: 'bare', status: 'pending' })], [{ ...here, number: 73, source: 'url' }])).toEqual([
    entry(73),
  ])
})

test('mergeFound は表示中のものを裸の番号で待ちに戻さない', () => {
  expect(mergeFound([entry(73)], [{ ...here, number: 73, source: 'bare' }])).toEqual([entry(73)])
})

test('keyOf は大文字小文字をそろえる', () => {
  expect(keyOf({ owner: 'HaoBlackJ', repo: 'Dotfiles', number: 1 })).toBe('haoblackj/dotfiles#1')
})
