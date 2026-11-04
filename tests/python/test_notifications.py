"""Unit tests for the scan-completion notification system in
backend/scripts/lineage_web/scan_manager.py (email via smtplib, Teams via
a webhook POST) -- written after finding this code was
already fully built (real SMTP send, real Adaptive Card Teams webhook,
wired into every scan-completion path) but had NO test coverage at all.
Real end-to-end sending (a real SMTP server actually accepting the
message, a real Teams channel actually rendering the card) can't be
verified from this session -- no live credentials -- so these tests cover
what CAN be verified without one: the email/card content is correct and
complete, and the send functions call smtplib/urllib with the right
arguments and handle both success and failure without raising.
"""
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import scan_manager as sm  # noqa: E402


SAMPLE_DIFF = {"by_type": {"Report": {"added": 2, "removed": 1, "modified": 0}}}


def _base_settings(**notif_overrides):
    return {
        "notifications": {
            "smtp_host": "smtp.example.com", "smtp_port": 587, "smtp_use_tls": True,
            "smtp_user": "bot@example.com", "smtp_password_ref": "SMTP_PW", "from_address": "bot@example.com",
            "teams_webhook_url": "https://mycompany.webhook.office.com/webhookb2/00000000-0000-0000-0000-000000000000@tenant/IncomingWebhook/abc123",
            **notif_overrides,
        },
    }


def test_build_notification_email_es_succeeded_contains_key_facts():
    subject, html_body, text_body = sm._build_notification_email(
        "WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", SAMPLE_DIFF,
        "user@example.com", "", "", "es",
    )
    assert "Escaneo completado" in subject
    assert "WS1" in html_body and "WS1" in text_body
    assert "user@example.com" in html_body
    assert "Report" in html_body and "+2" in html_body


def test_build_notification_email_en_failed_includes_error_detail():
    subject, html_body, text_body = sm._build_notification_email(
        sm.FULL_SCAN_LABEL, "2026-08-24T10:00:00", "2026-08-24T10:05:00", "failed", SAMPLE_DIFF,
        None, "discover_items", "Timeout", "en",
    )
    assert "errors" in subject
    assert "Full tenant scan" in html_body
    assert "anonymous" in html_body  # no triggered_by_email given
    assert "discover_items" in html_body and "Timeout" in html_body
    assert "discover_items" in text_body and "Timeout" in text_body


def test_build_notification_email_escapes_html_in_dynamic_fields():
    _subject, html_body, _text = sm._build_notification_email(
        "<script>alert(1)</script>", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", {},
        "user@example.com", "", "", "es",
    )
    assert "<script>alert(1)</script>" not in html_body
    assert "&lt;script&gt;" in html_body


def test_build_notification_email_no_changes_shows_placeholder():
    _subject, html_body, text_body = sm._build_notification_email(
        "WS1", "2026-08-24T10:00:00", "2026-08-24T10:00:10", "succeeded", {}, "user@example.com", "", "", "es",
    )
    assert "No se detectaron cambios" in html_body
    assert "No se detectaron cambios" in text_body


def test_build_teams_message_is_valid_adaptive_card_envelope():
    message = sm._build_teams_message(
        "WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", SAMPLE_DIFF,
        "user@example.com", "", "", "es",
    )
    assert message["type"] == "message"
    card = message["attachments"][0]["content"]
    assert card["type"] == "AdaptiveCard"
    fact_titles = {f["title"] for f in card["body"][1]["facts"]}
    assert {"Alcance", "Iniciado por", "Duración"} <= fact_titles


def test_build_teams_message_failed_status_is_attention_colored():
    message = sm._build_teams_message(
        "WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "failed", {}, "user@example.com", "step", "boom", "es",
    )
    heading = message["attachments"][0]["content"]["body"][0]
    assert heading["color"] == "Attention"


def test_send_email_not_configured_returns_clear_message():
    ok, error = sm._send_email({"notifications": {}}, "to@example.com", "Subject", "<p>hi</p>", "hi")
    assert ok is False
    assert "SMTP is not configured" in error


@patch("smtplib.SMTP")
def test_send_email_success_calls_smtp_with_expected_args(mock_smtp_cls):
    mock_server = MagicMock()
    mock_smtp_cls.return_value.__enter__.return_value = mock_server
    import os
    os.environ["SMTP_PW"] = "secret123"
    try:
        ok, error = sm._send_email(_base_settings(), "to@example.com", "Subject", "<p>hi</p>", "hi")
    finally:
        del os.environ["SMTP_PW"]
    assert ok is True
    assert error == ""
    mock_smtp_cls.assert_called_once_with("smtp.example.com", 587, timeout=15)
    mock_server.starttls.assert_called_once()
    mock_server.login.assert_called_once_with("bot@example.com", "secret123")
    assert mock_server.sendmail.call_count == 1
    from_addr, to_list, _raw_message = mock_server.sendmail.call_args[0]
    assert from_addr == "bot@example.com"
    assert to_list == ["to@example.com"]


@patch("smtplib.SMTP")
def test_send_email_skips_tls_and_login_when_not_configured(mock_smtp_cls):
    mock_server = MagicMock()
    mock_smtp_cls.return_value.__enter__.return_value = mock_server
    settings = _base_settings(smtp_use_tls=False, smtp_user="", smtp_password_ref="")
    ok, _error = sm._send_email(settings, "to@example.com", "Subject", "<p>hi</p>", "hi")
    assert ok is True
    mock_server.starttls.assert_not_called()
    mock_server.login.assert_not_called()


@patch("smtplib.SMTP")
def test_send_email_smtp_exception_returns_ok_false_not_raise(mock_smtp_cls):
    import smtplib
    mock_smtp_cls.return_value.__enter__.side_effect = smtplib.SMTPConnectError(421, "down")
    ok, error = sm._send_email(_base_settings(), "to@example.com", "Subject", "<p>hi</p>", "hi")
    assert ok is False
    assert error


@patch("smtplib.SMTP")
def test_send_email_refuses_reserved_sp_secret_password_ref(mock_smtp_cls):
    settings = _base_settings(smtp_password_ref="FABRIC_API_SP_CLIENT_SECRET")
    settings["lakehouse"] = {"sp_client_secret_ref": "FABRIC_API_SP_CLIENT_SECRET"}
    ok, error = sm._send_email(settings, "to@example.com", "Subject", "<p>hi</p>", "hi")
    assert ok is False
    assert "reserved" in error.lower()
    mock_smtp_cls.assert_not_called()


def test_send_teams_notification_not_configured_returns_clear_message():
    ok, error = sm._send_teams_notification({"notifications": {}}, {"type": "message"})
    assert ok is False
    assert "webhook" in error.lower()


@patch("urllib.request.urlopen")
def test_send_teams_notification_success_posts_json_to_webhook(mock_urlopen):
    mock_response = MagicMock()
    mock_response.status = 200
    mock_urlopen.return_value.__enter__.return_value = mock_response
    message = sm._build_teams_message("WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", SAMPLE_DIFF, "user@example.com", "", "", "es")
    ok, error = sm._send_teams_notification(_base_settings(), message)
    assert ok is True
    assert error == ""
    sent_request = mock_urlopen.call_args[0][0]
    assert sent_request.full_url == _base_settings()["notifications"]["teams_webhook_url"]
    assert sent_request.get_header("Content-type") == "application/json"


@patch("urllib.request.urlopen")
def test_send_teams_notification_http_error_returns_ok_false(mock_urlopen):
    import urllib.error
    webhook_url = _base_settings()["notifications"]["teams_webhook_url"]
    mock_urlopen.side_effect = urllib.error.HTTPError(webhook_url, 400, "Bad Request", {}, None)
    message = {"type": "message"}
    ok, error = sm._send_teams_notification(_base_settings(), message)
    assert ok is False
    assert "400" in error


def test_send_teams_notification_rejects_non_microsoft_webhook_url():
    ok, error = sm._send_teams_notification(_base_settings(teams_webhook_url="https://attacker.example.com/collect"), {"type": "message"})
    assert ok is False
    assert "webhook" in error.lower()


def test_send_scan_notification_emails_noop_for_running_status():
    # Only terminal statuses should ever attempt to send -- a "running"
    # (or any other non-terminal) status must be a silent no-op, not an
    # exception from _build_notification_email being handed a status key
    # NOTIFICATION_TEXT["subject"] doesn't have.
    with patch("lineage_web.scan_manager._load_admin_settings") as mock_load:
        sm._send_scan_notification_emails("WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "running", {}, "user@example.com")
        mock_load.assert_not_called()


@patch("lineage_web.scan_manager._send_teams_notification")
@patch("lineage_web.scan_manager._send_email")
@patch("lineage_web.scan_manager._load_admin_settings")
def test_send_scan_notification_emails_only_emails_interested_subscribers(mock_load, mock_send_email, mock_send_teams):
    mock_load.return_value = {
        "notifications": {
            "subscribers": [
                {"email": "wants-success@example.com", "notify_succeeded": True, "notify_failed": False},
                {"email": "wants-failure-only@example.com", "notify_succeeded": False, "notify_failed": True},
                {"email": "no-flags@example.com"},
            ],
        },
    }
    mock_send_email.return_value = (True, "")
    sm._send_scan_notification_emails("WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", SAMPLE_DIFF, "user@example.com")
    emailed = {call.args[1] for call in mock_send_email.call_args_list}
    assert emailed == {"wants-success@example.com"}
    mock_send_teams.assert_not_called()  # no teams_webhook_url in this settings fixture


@patch("lineage_web.scan_manager._send_teams_notification")
@patch("lineage_web.scan_manager._send_email")
@patch("lineage_web.scan_manager._load_admin_settings")
def test_send_scan_notification_emails_posts_teams_when_flag_and_webhook_set(mock_load, mock_send_email, mock_send_teams):
    mock_load.return_value = {
        "notifications": {
            "subscribers": [],
            "teams_webhook_url": "https://example.com/webhook",
            "teams_notify_failed": True,
            "teams_notify_succeeded": False,
        },
    }
    mock_send_teams.return_value = (True, "")
    sm._send_scan_notification_emails("WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "failed", {}, "user@example.com", "step1", "boom")
    mock_send_teams.assert_called_once()
    mock_send_email.assert_not_called()


@patch("lineage_web.scan_manager._send_teams_notification")
@patch("lineage_web.scan_manager._send_email")
@patch("lineage_web.scan_manager._load_admin_settings")
def test_send_scan_notification_emails_skips_teams_when_status_flag_off(mock_load, mock_send_email, mock_send_teams):
    mock_load.return_value = {
        "notifications": {
            "subscribers": [],
            "teams_webhook_url": "https://example.com/webhook",
            "teams_notify_failed": True,
            "teams_notify_succeeded": False,
        },
    }
    sm._send_scan_notification_emails("WS1", "2026-08-24T10:00:00", "2026-08-24T10:05:00", "succeeded", {}, "user@example.com")
    mock_send_teams.assert_not_called()
