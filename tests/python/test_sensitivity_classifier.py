"""Unit tests for backend/scripts/lineage_web/sensitivity_classifier.py
(Tanda B, 2026-07-09) -- pure regex logic, no file I/O, no CSV data needed.

Run with:
    pytest tests/python/test_sensitivity_classifier.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web.sensitivity_classifier import (  # noqa: E402
    classify_column_name,
    classify_columns,
    category_label,
    category_recommendation,
    category_risk,
    category_risk_label,
    category_frameworks,
    PRIVACY_FRAMEWORKS,
    SENSITIVITY_CATEGORIES,
)


def test_classify_column_name_matches_email():
    assert "email" in classify_column_name("CustomerEmail")
    assert "email" in classify_column_name("CONTACT_E-MAIL")


def test_classify_column_name_matches_spanish_national_id():
    assert "national_id" in classify_column_name("NIF_NIE_O_PASAPORTE")
    assert "national_id" in classify_column_name("DNI")


def test_classify_column_name_does_not_false_positive_on_movilidad():
    # "movil" (mobile phone) must not match "MOVILIDAD_LABORAL"
    # (staff relocation/mobility program) -- a common false positive in
    # Spanish-language column names.
    assert classify_column_name("MOVILIDAD_LABORAL") == []
    assert classify_column_name("GRP_PLAN_MOVILIDAD") == []


def test_classify_column_name_matches_bare_movil():
    assert "phone" in classify_column_name("MOVIL")
    assert "phone" in classify_column_name("MOVIL_TRABAJO")


def test_classify_column_name_matches_multiple_categories():
    result = classify_column_name("EMAIL_TELEFONO_CONTACTO")
    assert "email" in result
    assert "phone" in result


def test_classify_column_name_returns_empty_for_unrelated_column():
    assert classify_column_name("ID_PRODUCTO") == []


def test_classify_column_name_handles_empty_input():
    assert classify_column_name("") == []
    assert classify_column_name(None) == []


def test_classify_columns_unions_categories_across_a_list():
    result = classify_columns(["ID", "APELLIDOS", "CustomerEmail", "PRODUCTO"])
    assert result == {"person_name", "email"}


def test_category_label_returns_localized_text():
    assert category_label("email", "es") == "Email"
    assert category_label("national_id", "es") == "Identificación nacional"
    assert category_label("national_id", "en") == "National ID"


def test_category_label_falls_back_to_key_for_unknown_category():
    assert category_label("not_a_real_category", "es") == "not_a_real_category"


# --- Roadmap Fase 2 (2026-08-31): admin-defined custom categories ---

def _custom(key="internal_id", patterns=None, **overrides):
    entry = {
        "key": key,
        "label_es": "ID interno",
        "label_en": "Internal ID",
        "patterns": patterns if patterns is not None else [r"\binternal_id\b"],
        "risk": "high",
        "recommendation_es": "Restringir acceso.",
        "recommendation_en": "Restrict access.",
    }
    entry.update(overrides)
    return entry


def test_classify_column_name_matches_a_custom_category():
    result = classify_column_name("INTERNAL_ID", custom_categories=[_custom()])
    assert "internal_id" in result


def test_classify_column_name_without_custom_categories_ignores_them():
    assert classify_column_name("INTERNAL_ID") == []


def test_classify_columns_unions_built_in_and_custom_categories():
    result = classify_columns(["CustomerEmail", "INTERNAL_ID"], custom_categories=[_custom()])
    assert result == {"email", "internal_id"}


def test_custom_category_cannot_shadow_a_built_in_key():
    # A custom entry using an already-taken key (e.g. "email") must not
    # override the real built-in definition -- it's silently ignored, not
    # merged or allowed to win.
    shadow = _custom(key="email", patterns=[r"\bnever_matches_anything_xyz\b"])
    result = classify_column_name("CustomerEmail", custom_categories=[shadow])
    assert result == ["email"]
    assert category_label("email", "es", custom_categories=[shadow]) == "Email"


def test_custom_category_with_no_patterns_is_ignored():
    broken = _custom(patterns=[])
    assert classify_column_name("INTERNAL_ID", custom_categories=[broken]) == []


def test_custom_category_with_invalid_regex_is_ignored_not_raised():
    broken = _custom(patterns=["("])  # unbalanced group -- re.error
    assert classify_column_name("INTERNAL_ID", custom_categories=[broken]) == []


def test_custom_category_label_and_risk_resolve_when_provided():
    custom = [_custom()]
    assert category_label("internal_id", "es", custom) == "ID interno"
    assert category_label("internal_id", "en", custom) == "Internal ID"
    assert category_risk("internal_id", custom) == "high"
    assert category_risk_label("internal_id", "es", custom) == "Alto"
    assert category_recommendation("internal_id", "es", custom) == "Restringir acceso."


def test_custom_category_label_falls_back_to_key_when_not_supplied():
    # Same key, but the caller didn't pass custom_categories this time --
    # must not leak state from a previous call.
    assert category_label("internal_id", "es") == "internal_id"


def test_custom_category_missing_label_falls_back_to_key():
    entry = _custom(label_es="", label_en="")
    assert category_label("internal_id", "es", [entry]) == "internal_id"


# --- 13 built-in categories for data-subject requests (one request can
# combine access, objection and biometric data). Each assertion below uses
# a realistic column name that exercises one pattern pitfall (camelCase,
# underscore-joined, Spanish/English).

def test_image_media_matches_typical_columns():
    assert "image_media" in classify_column_name("Staff_Photo_URL")
    assert "image_media" in classify_column_name("PersonImage")
    assert "image_media" in classify_column_name("FOTO_OFICIAL_CONFIRMADA")


def test_image_media_does_not_match_videoconference_session_metadata():
    # SESION_VIDEOCONFERENCIA is meeting-session scheduling metadata
    # (start/end time, platform link), not a stored image of a person --
    # "video" was deliberately excluded from the pattern to avoid this,
    # same reasoning as "movil(?!idad)" above.
    assert classify_column_name("SESION_VIDEOCONFERENCIA") == []
    assert classify_column_name("Has_Videoconference_Session") == []


def test_employment_matches_typical_columns():
    assert "employment" in classify_column_name("Employer")
    assert "employment" in classify_column_name("PUESTO")
    assert "employment" in classify_column_name("EmployeeID")


def test_insurance_matches_typical_columns():
    assert "insurance" in classify_column_name("TIENE_SEGURO")
    assert "insurance" in classify_column_name("PAGO_SEGURO_HOGAR")


def test_academic_record_matches_common_column_names():
    assert "academic_record" in classify_column_name("EXPEDIENTE")
    assert "academic_record" in classify_column_name("GPA")
    assert "academic_record" in classify_column_name("Grade")


def test_marketing_consent_matches_typical_columns():
    assert "marketing_consent" in classify_column_name("AddedToNewsletter")
    assert "marketing_consent" in classify_column_name("EmailOptOutCRM")


def test_marketing_consent_does_not_match_crm_territory_fields():
    # MarketingCountry/MarketingRegion are CRM territory-assignment fields,
    # not a person's own communication preference -- bare "marketing" was
    # deliberately left out of the pattern to avoid this false positive.
    assert classify_column_name("MarketingCountry") == []
    assert classify_column_name("MarketingRegion") == []


def test_guardian_family_matches_typical_columns():
    assert "guardian_family" in classify_column_name("ContactoMadre")
    assert "guardian_family" in classify_column_name("DOC_PADRE_TIPO")


def test_disciplinary_record_matches_typical_columns():
    assert "disciplinary_record" in classify_column_name("SANCIONES_ETICAS")
    assert "disciplinary_record" in classify_column_name("SANCIONADO_COMITE_ETICO")
    assert "disciplinary_record" in classify_column_name("MemberExpulsionDate")


def test_technical_access_matches_typical_columns():
    assert "technical_access" in classify_column_name("IPAddress")
    assert "technical_access" in classify_column_name("UserAgent")


def test_biometric_voice_ai_third_party_special_category_still_classify():
    # These rarely appear as Fabric columns (they usually live outside
    # Fabric or aren't column-shaped concepts) -- still verify the patterns
    # work against the kind of column name that WOULD appear if one of
    # these systems is ever brought into Fabric.
    assert "biometric" in classify_column_name("BiometricTemplateHash")
    assert "voice_recording" in classify_column_name("VoiceRecordingUrl")
    assert "ai_processing_flag" in classify_column_name("AutomatedDecisionFlag")
    assert "third_party_sharing" in classify_column_name("SharedWithPartner")
    assert "special_category_belief" in classify_column_name("ReligiousAffiliation")


# --- 2026-08-31 (Fase 6): legal-framework tagging on every category ---

def test_every_built_in_category_declares_at_least_one_framework():
    for key, meta in SENSITIVITY_CATEGORIES.items():
        assert meta.get("frameworks"), key


def test_every_declared_framework_key_is_a_real_framework():
    for key, meta in SENSITIVITY_CATEGORIES.items():
        for framework in meta["frameworks"]:
            assert framework in PRIVACY_FRAMEWORKS, f"{key} declares unknown framework {framework}"


def test_category_frameworks_matches_known_mappings():
    assert category_frameworks("biometric") == ["gdpr_special", "ccpa"]
    assert category_frameworks("academic_record") == ["ferpa", "ccpa"]
    assert category_frameworks("disciplinary_record") == ["gdpr_criminal", "ferpa"]
    assert category_frameworks("special_category_belief") == ["gdpr_special"]


def test_category_frameworks_returns_empty_list_for_unknown_key():
    assert category_frameworks("not_a_real_category") == []


def test_privacy_frameworks_have_bilingual_labels_and_descriptions():
    for key, meta in PRIVACY_FRAMEWORKS.items():
        assert meta.get("es"), key
        assert meta.get("en"), key
        assert meta.get("description_es"), key
        assert meta.get("description_en"), key


def test_custom_category_frameworks_default_to_empty_list():
    entry = _custom()  # no "frameworks" key at all
    assert category_frameworks("internal_id", [entry]) == []


def test_custom_category_frameworks_pass_through_when_valid():
    entry = _custom(frameworks=["gdpr"])
    assert category_frameworks("internal_id", [entry]) == ["gdpr"]


def test_custom_category_frameworks_drop_unknown_keys():
    entry = _custom(frameworks=["gdpr", "not_a_real_framework"])
    assert category_frameworks("internal_id", [entry]) == ["gdpr"]


def test_new_categories_have_risk_and_recommendation_defined():
    new_categories = [
        "image_media", "voice_recording", "biometric", "employment", "insurance",
        "academic_record", "marketing_consent", "guardian_family", "disciplinary_record",
        "ai_processing_flag", "third_party_sharing", "special_category_belief", "technical_access",
    ]
    for key in new_categories:
        assert category_risk(key) in ("low", "medium", "high", "very_high"), key
        assert category_recommendation(key, "es"), key
        assert category_recommendation(key, "en"), key
        assert category_label(key, "es") != key, key
        assert category_label(key, "en") != key, key
