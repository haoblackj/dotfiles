import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parent.parent / 'guard-gh-target-repo.py'
spec = importlib.util.spec_from_file_location('guard_gh_target_repo', HOOK)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

OWN = {'haoblackj'}
# Real node IDs look like IC_kwDO...; the hook only picks up IDs of that shape.
NODE_OWNERS = {'IC_kwDOown0001': 'haoblackj', 'IC_kwDOother01': 'kot149'}


def resolve(node_id):
    return NODE_OWNERS.get(node_id)


def decide(command, cwd=None):
    return guard.decision(command, owners=OWN, cwd=cwd, resolve_node_owner=resolve)[0]


def git(cwd, *args):
    subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path):
    """origin = haoblackj, upstream = kot149, one local commit not on any remote."""
    path = tmp_path / 'work'
    path.mkdir()
    git(path, 'init', '-q', '-b', 'main')
    git(path, 'config', 'user.email', 't@example.com')
    git(path, 'config', 'user.name', 't')
    git(path, 'remote', 'add', 'origin', 'https://github.com/haoblackj/zmk-workspace')
    git(path, 'remote', 'add', 'upstream', 'https://github.com/kot149/zmk-workspace.git')
    git(path, 'commit', '-q', '--allow-empty', '-m', 'docs: local work')
    return path


# --- gh: target repository ---------------------------------------------------------------

def test_issue_create_without_repo_is_denied():
    # 2026-11-02: gh picked the upstream remote and the issue landed on another owner's repo.
    assert decide('gh issue create --title t --body-file b.md') == 'deny'


def test_issue_create_on_own_repo_passes():
    assert decide('gh issue create -R haoblackj/zmk-workspace --title t --body b') is None
    assert decide('gh issue create --repo=haoblackj/zmk-workspace --title t --body b') is None


def test_writes_to_other_owners_are_denied():
    assert decide('gh issue create -R kot149/zmk-workspace --title t --body b') == 'deny'
    assert decide('gh pr review https://github.com/other/r/pull/3 --approve') == 'deny'
    assert decide('gh repo fork kot149/zmk-workspace') == 'deny'


def test_repo_flag_after_the_subcommand_counts():
    assert decide('gh issue comment 4 --body x -R haoblackj/r') is None


def test_url_target_names_the_repo():
    assert decide('gh issue comment https://github.com/haoblackj/r/issues/3 --body x') is None


def test_reads_are_not_checked():
    assert decide('gh issue list') is None
    assert decide('gh pr view 3') is None
    assert decide('gh api repos/kot149/r/issues/4 --jq .state') is None


def test_api_write_uses_the_path_owner():
    assert decide('gh api -X PATCH repos/haoblackj/r/issues/4 -f state=closed') is None
    assert decide('gh api -X PATCH repos/kot149/r/issues/4 -f state=closed') == 'deny'
    assert decide('gh api repos/{owner}/{repo}/issues -f title=x') == 'deny'


def test_api_write_outside_repos_is_denied():
    assert decide('gh api -X POST gists -f description=x') == 'deny'


def test_pr_create_fill_is_denied():
    # The body would come from commit messages the hook does not see.
    assert decide('gh pr create -R haoblackj/r --fill') == 'deny'


# --- gh api graphql ----------------------------------------------------------------------

MINIMIZE = ("gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,"
            "classifier:OUTDATED}){minimizedComment{isMinimized}}}' -f id=")


def test_graphql_mutation_on_own_node_passes():
    assert decide(MINIMIZE + 'IC_kwDOown0001') is None


def test_graphql_mutation_on_other_owners_node_is_denied():
    assert decide(MINIMIZE + 'IC_kwDOother01') == 'deny'


def test_graphql_mutation_on_unresolvable_node_is_denied():
    assert decide(MINIMIZE + 'IC_kwDOunknown') == 'deny'


def test_graphql_mutation_with_inline_id_is_checked():
    assert decide('gh api graphql -f query=\'mutation{addComment(input:{subjectId:"IC_kwDOother01",'
                  'body:"x"}){clientMutationId}}\'') == 'deny'


def test_graphql_mutation_without_ids_is_denied():
    assert decide("gh api graphql -f query='mutation{createRepository(input:{name:\"x\","
                  "visibility:PRIVATE}){clientMutationId}}'") == 'deny'


def test_graphql_query_passes():
    assert decide("gh api graphql -f query='query{viewer{login}}'") is None


# --- body contents -----------------------------------------------------------------------

def test_reference_to_another_owners_issue_in_the_body_is_denied(tmp_path):
    # 2026-11-02: a state comment on an own issue named another owner's issue and left a
    # cross-reference on it.
    assert decide('gh issue comment 2 -R haoblackj/r --body "see kot149/zmk-workspace#4"') == 'deny'
    assert decide('gh issue comment 2 -R haoblackj/r --body '
                  '"https://github.com/kot149/zmk-workspace/issues/4"') == 'deny'
    body = tmp_path / 'state.md'
    body.write_text('別件: kot149/zmk-workspace#4 に誤って立てた\n', encoding='utf-8')
    assert decide(f'gh issue comment 2 -R haoblackj/r --body-file {body}') == 'deny'
    assert decide(f'gh api -X PATCH repos/haoblackj/r/issues/comments/1 -F body=@{body}') == 'deny'


def test_relative_body_file_uses_cwd_and_cd(tmp_path):
    sub = tmp_path / 'sub'
    sub.mkdir()
    (sub / 'b.md').write_text('see https://github.com/other/r/pull/9', encoding='utf-8')
    assert decide('gh pr comment 1 -R haoblackj/r --body-file sub/b.md', cwd=str(tmp_path)) == 'deny'
    assert decide(f'cd {sub} && gh pr comment 1 -R haoblackj/r --body-file b.md') == 'deny'


def test_body_piped_from_a_file_is_read(tmp_path):
    body = tmp_path / 'b.md'
    body.write_text('see other/r#9\n', encoding='utf-8')
    assert decide(f'cat {body} | gh issue comment 1 -R haoblackj/r --body-file -') == 'deny'
    assert decide(f'gh issue comment 1 -R haoblackj/r --body-file - < {body}') == 'deny'
    assert decide(f'gh issue comment 1 -R haoblackj/r --body "$(cat {body})"') == 'deny'
    body.write_text('clean\n', encoding='utf-8')
    assert decide(f'cat {body} | gh issue comment 1 -R haoblackj/r --body-file -') is None


def test_body_from_a_heredoc_is_read():
    command = ('gh issue comment 1 -R haoblackj/r --body-file - <<\'EOF\'\n'
               'see other/r#9\nEOF')
    assert decide(command) == 'deny'


def test_body_piped_from_an_unknown_program_is_denied():
    assert decide('python3 make_body.py | gh issue comment 1 -R haoblackj/r --body-file -') == 'deny'


def test_mentions_of_other_users_are_denied():
    assert decide('gh issue comment 1 -R haoblackj/r --body "cc @kot149"') == 'deny'
    assert decide('gh issue comment 1 -R haoblackj/r --body "cc @haoblackj"') is None
    assert decide('gh issue comment 1 -R haoblackj/r --body "use `@reviewer` here"') is None
    assert decide('gh issue comment 1 -R haoblackj/r --body "mail a@example.com"') is None


def test_own_and_bare_references_pass():
    assert decide('gh issue comment 2 -R haoblackj/r --body "see haoblackj/r#3 and #4"') is None
    assert decide('gh issue comment 2 -R haoblackj/r --body "upstream is kot149/zmk-workspace"') is None


# --- shell parsing -----------------------------------------------------------------------

def test_every_gh_in_a_compound_command_is_checked():
    assert decide('cd x && gh issue list && gh issue close 3') == 'deny'
    assert decide('GH_TOKEN=x env -u GH_TOKEN gh pr create --title t') == 'deny'


def test_gh_after_any_prefix_is_checked():
    for prefix in ('timeout 30', 'nice -n 5', 'stdbuf -oL', 'echo 1 | xargs', 'time -p', 'flock /x'):
        assert decide(f'{prefix} gh issue create --title t') == 'deny', prefix
        assert decide(f'{prefix} gh issue create -R kot149/r --title t') == 'deny', prefix
        assert decide(f'{prefix} gh issue create -R haoblackj/r --title t --body b') is None, prefix
    assert decide('if gh issue create --title t; then :; fi') == 'deny'
    assert decide('echo `gh issue create --title t`') == 'deny'


def test_gh_inside_quoted_commands_is_checked():
    assert decide('bash -c "gh issue create --title t"') == 'deny'
    assert decide("ssh host 'gh issue comment 1 -R kot149/r --body x'") == 'deny'
    assert decide('echo "$(gh issue create --title t)"') == 'deny'
    assert decide('echo "gh issue create --title t" | bash') == 'deny'
    assert decide('bash -c "gh issue create -R haoblackj/r --title t --body b"') is None
    assert decide('bash -c "gh issue list"') is None


def test_bodies_and_commit_messages_are_not_read_as_commands():
    assert decide('gh issue comment 1 -R haoblackj/r --body "run gh issue create without -R"') is None
    assert decide('git commit -m "docs: gh issue create needs -R"') is None


def test_reference_after_japanese_is_denied():
    assert decide('gh issue comment 1 -R haoblackj/r --body "別件はkot149/zmk-workspace#4で"') == 'deny'
    assert decide('gh issue comment 1 -R haoblackj/r --body "確認お願いします@kot149"') == 'deny'


def test_scripts_that_call_gh_are_checked(tmp_path):
    shell = tmp_path / 'post.sh'
    shell.write_text('#!/bin/sh\ngh issue create --title t\n')
    assert decide(f'bash {shell}') == 'deny'
    assert decide(str(shell)) == 'deny'
    shell.write_text('#!/bin/sh\ngh issue list -R kot149/r\n')
    assert decide(f'bash {shell}') is None
    assert decide("python3 -c \"import subprocess; subprocess.run(['gh', 'issue', 'create'])\"") == 'deny'


def test_pr_body_heredoc_with_apostrophe_passes():
    command = ("gh pr create -R haoblackj/r --title t --body \"$(cat <<'EOF'\n"
               "It's done\nEOF\n)\"")
    assert decide(command) is None


def test_reads_with_quotes_and_unrelated_words_pass():
    assert decide('echo "gh issue list"') is None
    assert decide('brew upgrade gh git') is None
    assert decide('grep -rn "gh issue" .') is None


# --- git push ----------------------------------------------------------------------------

def test_push_to_own_remote_passes(repo):
    assert decide('git push origin main', cwd=str(repo)) is None
    assert decide(f'git -C {repo} push origin main') is None


def test_push_to_other_owners_remote_is_denied(repo):
    assert decide('git push upstream main', cwd=str(repo)) == 'deny'
    assert decide('git push https://github.com/kot149/zmk-workspace main', cwd=str(repo)) == 'deny'


def test_push_without_remote_uses_the_branch_remote(repo):
    git(repo, 'config', 'branch.main.remote', 'upstream')
    assert decide('git push', cwd=str(repo)) == 'deny'
    git(repo, 'config', 'branch.main.remote', 'origin')
    assert decide('git push', cwd=str(repo)) is None


def test_push_of_commits_that_reference_other_issues_is_denied(repo):
    git(repo, 'commit', '-q', '--allow-empty', '-m', 'fix: see kot149/zmk-workspace#4')
    assert decide('git push origin main', cwd=str(repo)) == 'deny'


def test_push_with_unresolvable_remote_is_denied(repo):
    assert decide('git push nosuchremote main', cwd=str(repo)) == 'deny'


# --- other paths to the GitHub API -------------------------------------------------------

def test_curl_writes_to_github_are_checked():
    assert decide('curl -X POST https://api.github.com/repos/kot149/r/issues -d @b.json') == 'deny'
    assert decide('curl -X POST https://api.github.com/repos/haoblackj/r/issues -d @b.json') is None
    assert decide('curl -d x https://api.github.com/graphql') == 'deny'
    assert decide('curl https://api.github.com/repos/kot149/r/issues/4') is None


def test_programs_talking_to_the_github_api_are_denied(tmp_path):
    script = tmp_path / 'post.py'
    script.write_text('import requests\nrequests.post("https://api.github.com/x")\n')
    assert decide(f'python3 {script}') == 'deny'
    assert decide("python3 -c 'import urllib.request; urllib.request.urlopen(\"https://api.github.com/x\")'") == 'deny'


# --- MCP tools ---------------------------------------------------------------------------

def test_mcp_github_writes_need_own_owner():
    assert guard.mcp_decision('mcp__github__create_issue',
                              {'owner': 'haoblackj', 'repo': 'r', 'title': 't', 'body': 'b'},
                              OWN)[0] is None
    assert guard.mcp_decision('mcp__github__create_issue',
                              {'owner': 'kot149', 'repo': 'r', 'title': 't'}, OWN)[0] == 'deny'
    assert guard.mcp_decision('mcp__github__add_issue_comment',
                              {'owner': 'haoblackj', 'repo': 'r', 'body': 'see other/r#2'},
                              OWN)[0] == 'deny'
    assert guard.mcp_decision('mcp__github__create_issue', {'title': 't'}, OWN)[0] == 'deny'
    assert guard.mcp_decision('mcp__github__get_issue', {'owner': 'kot149', 'repo': 'r'},
                              OWN)[0] is None


# --- hook entry point --------------------------------------------------------------------

def run_hook(payload):
    out = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                         capture_output=True, text=True,
                         env={'GH_WRITE_OWNERS': 'haoblackj', 'PATH': '/usr/bin:/bin'})
    return json.loads(out.stdout)['hookSpecificOutput'] if out.stdout.strip() else None


def test_hook_emits_permission_decision():
    result = run_hook({'tool_name': 'Bash', 'tool_input': {'command': 'gh issue create --title t'}})
    assert result['permissionDecision'] == 'deny'
    assert '-R' in result['permissionDecisionReason']


def test_hook_handles_mcp_payloads():
    result = run_hook({'tool_name': 'mcp__github__create_issue',
                       'tool_input': {'owner': 'kot149', 'repo': 'r', 'title': 't'}})
    assert result['permissionDecision'] == 'deny'
