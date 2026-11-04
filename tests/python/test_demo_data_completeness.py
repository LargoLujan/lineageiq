"""The demo generator must produce every file that the execution, schedule,
role and failure views read, with deterministic, fictitious content."""
import importlib.util
import re
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "backend" / "scripts" / "generate_demo_data.py"
spec = importlib.util.spec_from_file_location("generate_demo_data", SCRIPT)
demo = importlib.util.module_from_spec(spec)
sys.modules["generate_demo_data"] = demo
spec.loader.exec_module(demo)


def test_execution_rows_are_deterministic_and_cover_executable_items():
    first = demo.build_execution_rows()
    assert first == demo.build_execution_rows()
    jobs = [r for r in first if r["record_type"] == "job_instance"]
    assert {r["status"] for r in jobs} == {"Completed", "Failed"}
    assert all(float(r["duration_seconds"]) > 0 for r in jobs)
    known = {demo.qname(*item) for item in demo.ITEMS}
    assert {r["qualified_name"] for r in first} <= known
    assert any(r["schedule_enabled"] == "False" for r in first if r["record_type"] == "schedule")


def test_role_assignments_use_only_fictitious_emails():
    roles = {row[4] for row in demo.ROLE_ASSIGNMENTS}
    assert {"Admin", "Member", "Contributor", "Viewer"} <= roles
    for _, _, email, _, _ in demo.ROLE_ASSIGNMENTS:
        assert not email or re.search(r"@(contoso|example)\.com$", email)
