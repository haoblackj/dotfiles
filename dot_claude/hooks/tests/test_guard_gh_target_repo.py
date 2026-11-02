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


def test_issue_create_on_other_owner_asks():
    assert decide('gh issue create -R kot149/zmk-workspace --title t') == 'ask'


def test_repo_flag_after_the_subcommand_counts():
    assert decide('gh issue comment 4 --body x -R haoblackj/r') is None


def test_url_target_names_the_repo():
    assert decide('gh issue comment https://github.com/haoblackj/r/issues/3 --body x') is None
    assert decide('gh pr review https://github.com/other/r/pull/3 --approve') == 'ask'


def test_reads_are_not_checked():
    assert decide('gh issue list') is None
    assert decide('gh pr view 3') is None
    assert decide('gh api repos/kot149/r/issues/4 --jq .state') is None


def test_api_write_uses_the_path_owner():
    assert decide('gh api -X PATCH repos/haoblackj/r/issues/4 -f state=closed') is None
    assert decide('gh api -X PATCH repos/kot149/r/issues/4 -f state=closed') == 'ask'
    assert decide('gh api repos/kot149/r/issues -f title=x') == 'ask'


def test_api_write_with_placeholder_is_denied():
    assert decide('gh api repos/{owner}/{repo}/issues -f title=x') == 'deny'


def test_graphql_mutations_name_their_target_by_id():
    assert decide("gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' -f id=IC_x") is None


def test_every_gh_in_a_compound_command_is_checked():
    assert decide('cd x && gh issue list && gh issue close 3') == 'deny'
    assert decide('GH_TOKEN=x env -u GH_TOKEN gh pr create --title t') == 'deny'


def test_mentions_inside_quotes_are_not_commands():
    assert decide('echo "gh issue create"') is None


def test_hook_emits_permission_decision():
    payload = json.dumps({'tool_input': {'command': 'gh issue create --title t'}})
    out = subprocess.run([sys.executable, str(HOOK)], input=payload, capture_output=True,
                         text=True, env={'GH_WRITE_OWNERS': 'haoblackj', 'PATH': '/usr/bin:/bin'})
    result = json.loads(out.stdout)['hookSpecificOutput']
    assert result['permissionDecision'] == 'deny'
    assert '-R' in result['permissionDecisionReason']
