import importlib.util
import json
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / 'guard-gh-target-repo.py'
spec = importlib.util.spec_from_file_location('guard_gh_target_repo', HOOK)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def decide(command):
    return guard.decision(command, owners={'haoblackj'})[0]


def test_issue_create_without_repo_is_denied():
    # 2026-11-02: gh picked the upstream remote and the issue landed on kot149/zmk-workspace.
    assert decide('gh issue create --title t --body-file b.md') == 'deny'


def test_issue_create_on_own_repo_passes():
    assert decide('gh issue create -R haoblackj/zmk-workspace --title t --body b') is None
    assert decide('gh issue create --repo=haoblackj/zmk-workspace --title t') is None


def test_issue_create_on_other_owner_is_denied():
    assert decide('gh issue create -R kot149/zmk-workspace --title t') == 'deny'


def test_repo_flag_after_the_subcommand_counts():
    assert decide('gh issue comment 4 --body x -R haoblackj/r') is None


def test_url_target_names_the_repo():
    assert decide('gh issue comment https://github.com/haoblackj/r/issues/3 --body x') is None
    assert decide('gh pr review https://github.com/other/r/pull/3 --approve') == 'deny'


def test_reads_are_not_checked():
    assert decide('gh issue list') is None
    assert decide('gh pr view 3') is None
    assert decide('gh api repos/kot149/r/issues/4 --jq .state') is None


def test_api_write_uses_the_path_owner():
    assert decide('gh api -X PATCH repos/haoblackj/r/issues/4 -f state=closed') is None
    assert decide('gh api -X PATCH repos/kot149/r/issues/4 -f state=closed') == 'deny'
    assert decide('gh api repos/kot149/r/issues -f title=x') == 'deny'


def test_api_write_with_placeholder_is_denied():
    assert decide('gh api repos/{owner}/{repo}/issues -f title=x') == 'deny'


def test_graphql_mutations_name_their_target_by_id():
    assert decide("gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' -f id=IC_x") is None


def test_every_gh_in_a_compound_command_is_checked():
    assert decide('cd x && gh issue list && gh issue close 3') == 'deny'
    assert decide('GH_TOKEN=x env -u GH_TOKEN gh pr create --title t') == 'deny'


def test_mentions_inside_quotes_are_not_commands():
    assert decide('echo "gh issue create"') is None


def test_reference_to_another_owners_issue_in_the_body_is_denied(tmp_path):
    # 2026-11-02: a state comment on haoblackj/zmk-workspace#2 named kot149/zmk-workspace#4,
    # which left a cross-reference on the other person's issue.
    assert decide('gh issue comment 2 -R haoblackj/r --body "see kot149/zmk-workspace#4"') == 'deny'
    assert decide('gh issue comment 2 -R haoblackj/r --body '
                  '"https://github.com/kot149/zmk-workspace/issues/4"') == 'deny'
    body = tmp_path / 'state.md'
    body.write_text('別件: kot149/zmk-workspace#4 に誤って立てた\n', encoding='utf-8')
    assert guard.decision(f'gh issue comment 2 -R haoblackj/r --body-file {body}',
                          owners={'haoblackj'})[0] == 'deny'
    assert guard.decision(f'gh api -X PATCH repos/haoblackj/r/issues/comments/1 -F body=@{body}',
                          owners={'haoblackj'})[0] == 'deny'


def test_reference_relative_body_file_uses_cwd(tmp_path):
    (tmp_path / 'b.md').write_text('see https://github.com/other/r/pull/9', encoding='utf-8')
    assert guard.decision('gh pr comment 1 -R haoblackj/r --body-file b.md',
                          owners={'haoblackj'}, cwd=str(tmp_path))[0] == 'deny'


def test_own_and_bare_references_pass():
    assert decide('gh issue comment 2 -R haoblackj/r --body "see haoblackj/r#3 and #4"') is None
    assert decide('gh issue comment 2 -R haoblackj/r --body "upstream is kot149/zmk-workspace"') is None


def test_hook_emits_permission_decision():
    payload = json.dumps({'tool_input': {'command': 'gh issue create --title t'}})
    out = subprocess.run([sys.executable, str(HOOK)], input=payload, capture_output=True,
                         text=True, env={'GH_WRITE_OWNERS': 'haoblackj', 'PATH': '/usr/bin:/bin'})
    result = json.loads(out.stdout)['hookSpecificOutput']
    assert result['permissionDecision'] == 'deny'
    assert '-R' in result['permissionDecisionReason']
