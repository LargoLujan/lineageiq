"""/api/history/diff only serves existing .json files strictly inside the
scan diffs folder (backend/scripts/lineage_web/handler.py,
_resolve_history_diff_path)."""
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web.handler import _resolve_history_diff_path  # noqa: E402


def _layout(tmp_path):
    repo = tmp_path / "repo"
    diffs = repo / "analysis" / "single_workspace_scan" / "diffs"
    diffs.mkdir(parents=True)
    (diffs / "20261106T090000_contoso-sales.json").write_text("{}", encoding="utf-8")
    (diffs / "notes.txt").write_text("not a diff", encoding="utf-8")
    (repo / "config").mkdir()
    (repo / "config" / "admin_settings.json").write_text("{}", encoding="utf-8")
    evil = repo / "analysis" / "single_workspace_scan" / "diffs_evil"
    evil.mkdir()
    (evil / "x.json").write_text("{}", encoding="utf-8")
    return repo, diffs


def test_a_diff_inside_the_folder_is_served(tmp_path):
    repo, diffs = _layout(tmp_path)
    path = "analysis/single_workspace_scan/diffs/20261106T090000_contoso-sales.json"
    assert _resolve_history_diff_path(path, repo, diffs) == os.path.realpath(diffs / "20261106T090000_contoso-sales.json")


def test_paths_outside_the_folder_are_refused(tmp_path):
    repo, diffs = _layout(tmp_path)
    for path in (
        "analysis/single_workspace_scan/diffs/../../../config/admin_settings.json",
        "config/admin_settings.json",
        str(repo / "config" / "admin_settings.json"),
        "analysis/single_workspace_scan/diffs_evil/x.json",
        "analysis/single_workspace_scan/diffs",
    ):
        assert _resolve_history_diff_path(path, repo, diffs) is None, path


def test_only_existing_json_files_are_served(tmp_path):
    repo, diffs = _layout(tmp_path)
    assert _resolve_history_diff_path("analysis/single_workspace_scan/diffs/notes.txt", repo, diffs) is None
    assert _resolve_history_diff_path("analysis/single_workspace_scan/diffs/missing.json", repo, diffs) is None
