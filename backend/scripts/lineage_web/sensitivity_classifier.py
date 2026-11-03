"""Purview-inspired column sensitivity classifier (Tanda B, 2026-07-09) --
a simplified, pattern-based equivalent of Purview's built-in classifiers
(email/national ID/credit card/etc.), run over column names this project
has *already* catalogued (frontend/semantic-lineage/data/object-impact.json)
rather than sampling real column data. Deliberately dependency-free (no
other lineage_web imports) so both build_graph_map_index.py (a standalone
script, not part of the lineage_web package) and the web server's own
admin routes can import it the same way.

These are name-pattern heuristics, not a guarantee -- a column called
`DIRECCION_IP` would false-positive on the address pattern, a column
storing an email under an opaque name like `CONTACT_INFO_1` would be
missed entirely. Treat matches as "worth a human looking at", the same
posture Purview's own automatic classifiers ask for.
"""
import re

# category_key -> {es, en, patterns (compiled at import time)}. Patterns
# are checked case-insensitively against the raw column_name; word
# boundaries (\b) matter where a bare substring would false-positive on an
# unrelated column name that is common in practice (e.g. "movil" without a
# boundary matches "MOVILIDAD_LABORAL", a staff relocation/mobility
# program field, not a mobile phone column).
SENSITIVITY_CATEGORIES = {
    "email": {
        "es": "Email", "en": "Email",
        "patterns": [r"e-?mail"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "No compartir fuera de la organización sin anonimizar. Enmascarar en informes/exports de uso amplio.",
            "en": "Don't share outside the organization unmasked. Mask it in broadly-shared reports/exports.",
        },
    },
    "phone": {
        "es": "Teléfono", "en": "Phone",
        # "movil(?!idad)" (not \bmovil\b -- \b treats "_" as a word char, so
        # it wouldn't match a real column like "MOVIL_TRABAJO") -- excludes
        # only "movilidad" (staff relocation/mobility programs), a common
        # false positive in Spanish-language schemas.
        "patterns": [r"telefono", r"\bphone\b", r"movil(?!idad)"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Enmascarar en informes de uso amplio. Combinado con nombre, facilita contactar directamente a la persona.",
            "en": "Mask it in broadly-shared reports. Combined with a name, it makes directly contacting the person easy.",
        },
    },
    "national_id": {
        "es": "Identificación nacional", "en": "National ID",
        "patterns": [r"\bdni\b", r"\bnif\b", r"\bnie\b", r"passport", r"pasaporte", r"\bssn\b"],
        "risk": "high",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Identificador legal directo. Restringir a roles con necesidad de conocer, aplicar Dynamic Data Masking (DDM) donde sea técnicamente posible.",
            "en": "A direct legal identifier. Restrict to need-to-know roles, apply Dynamic Data Masking (DDM) where technically possible.",
        },
    },
    "person_name": {
        "es": "Nombre / apellidos", "en": "Person name",
        "patterns": [r"apellido", r"surname", r"last_?name", r"first_?name", r"full_?name"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        # Regex por contenido no es fiable para nombres de persona (ver
        # CONTENT_PATTERN_CATEGORIES abajo) -- el riesgo real depende
        # sobre todo de con qué OTRAS columnas aparece combinado.
        "recommendation": {
            "es": "Por sí solo, riesgo moderado. Combinado con fecha de nacimiento, email o dirección, el riesgo de reidentificación sube -- revisar esas combinaciones en la misma tabla.",
            "en": "Moderate risk alone. Combined with birth date, email, or address, re-identification risk rises -- review those combinations within the same table.",
        },
    },
    "address": {
        "es": "Dirección postal", "en": "Postal address",
        "patterns": [r"direccion", r"\baddress\b", r"domicilio"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Restringir a roles con necesidad de conocer. Evitar en exports/informes de distribución amplia.",
            "en": "Restrict to need-to-know roles. Avoid in broadly-distributed exports/reports.",
        },
    },
    "birth_date": {
        "es": "Fecha de nacimiento", "en": "Birth date",
        "patterns": [r"nacimiento", r"\bbirth"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Combinado con nombre o código postal, aumenta mucho el riesgo de reidentificación. Considerar Row-Level Security (RLS) si se expone en informes.",
            "en": "Combined with a name or postal code, re-identification risk rises sharply. Consider Row-Level Security (RLS) if exposed in reports.",
        },
    },
    "financial": {
        "es": "Datos financieros", "en": "Financial data",
        "patterns": [r"\biban\b", r"bank_?account", r"credit_?card", r"tarjeta", r"\bsalary\b", r"salario", r"sueldo", r"card_?number"],
        "risk": "high",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Acceso restringido y auditado. Aplicar DDM/cifrado en reposo donde sea posible; si son datos de tarjeta, revisar cumplimiento PCI-DSS.",
            "en": "Restricted, audited access. Apply DDM/encryption at rest where possible; if card data, review PCI-DSS compliance.",
        },
    },
    "health": {
        "es": "Datos de salud", "en": "Health data",
        "patterns": [r"\bhealth\b", r"\bsalud\b", r"medical", r"diagnostico", r"discapacidad", r"disability"],
        "risk": "very_high",
        "frameworks": ["gdpr_special", "ccpa"],
        "recommendation": {
            "es": "Categoría especial (art. 9 RGPD). Acceso mínimo indispensable, auditar cada acceso, valorar anonimización si no es imprescindible mantenerlo identificado.",
            "en": "Special category (GDPR Art. 9). Minimum necessary access, audit every access, consider anonymizing it if keeping it identified isn't essential.",
        },
    },
    "gender": {
        "es": "Género", "en": "Gender",
        "patterns": [r"\bgender\b", r"\bsexo\b"],
        "risk": "low",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Riesgo bajo por sí solo, pero es un dato considerado sensible en ciertas normativas -- revisar si su uso está realmente justificado.",
            "en": "Low risk on its own, but treated as sensitive under some regulations -- review whether using it is actually justified.",
        },
    },
    # --- 13 categorías pensadas para solicitudes de derechos de los
    # interesados: una misma solicitud puede combinar acceso, oposición y
    # datos biométricos. Investigadas contra RGPD (arts. 4/9/10/21/22),
    # FERPA (expediente académico) y CCPA/CPRA (11 categorías estatutarias
    # de datos personales); cada patrón se contrasta con nombres de columna
    # habituales (catalogados en frontend/semantic-lineage/data/object-
    # impact.json) antes de incluirlo -- misma disciplina que
    # "movil(?!idad)" ya aplicaba arriba. Algunas (biometric/voice_
    # recording/ai_processing_flag/third_party_sharing/special_category_
    # belief) rara vez aparecen como columna en Fabric y se incluyen igual
    # -- son categorías legalmente obligatorias de tener detector listo
    # (RGPD art. 9/22), o suelen vivir en un sistema fuera de Fabric
    # (control de acceso físico, plataforma de grabación) y conviene que el
    # patrón exista para el día que sí aparezca una columna así.
    "image_media": {
        "es": "Imagen / fotografía", "en": "Image / photo",
        # "video"/"videoconferencia" excluido a propósito -- columnas
        # como SESION_VIDEOCONFERENCIA suelen ser metadato de una sesión
        # o reunión (horario, enlace), no una imagen almacenada de una
        # persona; incluir "video" habría sido puro ruido, mismo criterio
        # que excluir "movilidad" de "phone".
        # No \b on imagen/image -- columns are often camelCase
        # compounds (PersonImage) where \b never fires (no non-word char
        # between "Person" and "Image"), same underscore/camelCase pitfall
        # "movil(?!idad)" above already worked around for "phone".
        "patterns": [r"foto", r"photo", r"imagen", r"image", r"headshot", r"avatar"],
        "risk": "high",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Dato personal directo (RGPD, CCPA cat. 8). Confirmar base legal de retención y si hay opción de baja tras finalizar la relación con la organización.",
            "en": "Direct personal data (GDPR, CCPA cat. 8). Confirm the legal retention basis and whether there's an opt-out once the relationship with the organization ends.",
        },
    },
    "voice_recording": {
        "es": "Grabación de voz", "en": "Voice recording",
        "patterns": [r"voice", r"voz", r"audio", r"grabacion", r"recording"],
        "risk": "high",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Rara vez aparece como columna en Fabric -- suele vivir en la plataforma de videoconferencia/grabación. Si aparece una columna así, tratar como dato personal directo (RGPD, CCPA cat. 8).",
            "en": "Rarely stored as a column in Fabric -- it usually lives in the videoconferencing/recording platform. If a column like this appears, treat as direct personal data (GDPR, CCPA cat. 8).",
        },
    },
    "biometric": {
        "es": "Dato biométrico", "en": "Biometric data",
        "patterns": [r"biometr", r"huella", r"fingerprint", r"faceid", r"face_?id", r"iris_?scan"],
        "risk": "very_high",
        "frameworks": ["gdpr_special", "ccpa"],
        "recommendation": {
            "es": "Categoría especial (art. 9 RGPD). Rara vez aparece como columna en Fabric -- suele vivir en el sistema de control de acceso físico. Si aparece, requiere consentimiento explícito o base legal reforzada.",
            "en": "Special category (GDPR Art. 9). Rarely stored as a column in Fabric -- it usually lives in the physical access-control system. If it appears, it requires explicit consent or a reinforced legal basis.",
        },
    },
    "employment": {
        "es": "Situación laboral", "en": "Employment",
        # Bare, no \b -- column names come both camelCase
        # (IsCurrentlyEmployed, NumberOfEmployees) and underscore-joined
        # (CONTRATO_PUESTO_RESPONSABLE), neither of which a \b-bounded
        # "puesto"/"employ" would reach.
        "patterns": [r"employ", r"empleador", r"empleo", r"puesto"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Dato profesional (CCPA cat. 9). Restringir a roles con necesidad de conocer (RR. HH., selección).",
            "en": "Professional data (CCPA cat. 9). Restrict to need-to-know roles (HR, recruiting).",
        },
    },
    "insurance": {
        "es": "Seguro", "en": "Insurance",
        # "seguro" bare (not \bseguro\b) -- TIENE_SEGURO/PAGO_SEGURO_HOGAR
        # have "_" on both sides, which \b treats as a word char (no
        # boundary fires there), same pitfall as "puesto"/"image" above.
        "patterns": [r"seguro", r"insuranc"],
        "risk": "medium",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Vinculado a datos de salud/financieros -- restringir a roles con necesidad de conocer, auditar acceso.",
            "en": "Linked to health/financial data -- restrict to need-to-know roles, audit access.",
        },
    },
    "academic_record": {
        "es": "Expediente académico", "en": "Academic record",
        # grade/gpa keep \b deliberately (protects against "Upgrade"/
        # "Downgrade" false-positiving as an academic record) -- nota does
        # NOT, since typical column names (e.g. grade_id, grade_label)
        # have "_" on at least one side, same \b-treats-underscore-as-a-
        # word-char pitfall as elsewhere in this file.
        "patterns": [r"expediente", r"\bgrade\b", r"\bgpa\b", r"transcript", r"matricula", r"nota", r"calificacion"],
        "risk": "low",
        "frameworks": ["ferpa", "ccpa"],
        # FERPA exige conservar el expediente académico -- a diferencia del
        # resto de categorías, la recomendación aquí no es "restringir/
        # anonimizar" sino "confirmar que el acceso amplio está
        # justificado", ya que conservarlo es una obligación legal, no
        # una opción.
        "recommendation": {
            "es": "Retención obligatoria (FERPA/normativa educativa) -- no es candidato a supresión. Confirmar que el acceso está limitado a quien lo necesita para fines académicos.",
            "en": "Mandatory retention (FERPA/education regulation) -- not an erasure candidate. Confirm access is limited to those who need it for academic purposes.",
        },
    },
    "marketing_consent": {
        "es": "Consentimiento de marketing", "en": "Marketing consent",
        # "marketing" a secas queda fuera a propósito -- columnas
        # habituales como MarketingCountry/MarketingRegion son territorio
        # de CRM, no preferencia de contacto; newsletter/optout sí son
        # señal real y limpia (EmailOptOutCRM, AddedToNewsletter).
        "patterns": [r"newsletter", r"opt_?out", r"opt_?in", r"unsubscribe"],
        "risk": "low",
        "frameworks": ["gdpr", "ccpa"],
        "recommendation": {
            "es": "Es la propia preferencia de la persona -- respetar el valor tal cual esté marcado, no como sugerencia.",
            "en": "This IS the person's own preference -- honor the stored value as-is, not as a suggestion.",
        },
    },
    "guardian_family": {
        "es": "Datos de familiares / tutores", "en": "Guardian / family data",
        # padre/madre bare -- column names are often camelCase compounds
        # (ContactoMadre, DOC_PADRE_TIPO), same pitfall as above.
        "patterns": [r"padre", r"madre", r"guardian", r"tutor_legal", r"next_?of_?kin", r"emergency_?contact"],
        "risk": "medium",
        "frameworks": ["gdpr", "ferpa"],
        "recommendation": {
            "es": "Dato personal de un TERCERO (el familiar), no solo del interesado -- si hay una preferencia de contacto registrada (ej. \"no contactar a este familiar\"), debe respetarse en cada sistema que envíe comunicaciones, no solo en el de origen.",
            "en": "Personal data of a THIRD PARTY (the family member), not just the data subject -- if a contact preference is on file (e.g. \"do not contact this relative\"), it must be honored in every system that sends communications, not just the source one.",
        },
    },
    "disciplinary_record": {
        "es": "Expediente disciplinario", "en": "Disciplinary record",
        "patterns": [r"sancion", r"disciplinary", r"expulsion", r"comite_?etico", r"conducta"],
        "risk": "very_high",
        "frameworks": ["gdpr_criminal", "ferpa"],
        "recommendation": {
            "es": "Dato sensible por naturaleza (art. 10 RGPD, procedimientos sancionadores). Acceso mínimo indispensable, auditar cada acceso.",
            "en": "Sensitive by nature (GDPR Art. 10, disciplinary proceedings). Minimum necessary access, audit every access.",
        },
    },
    "ai_processing_flag": {
        "es": "Uso en procesamiento de IA", "en": "AI processing flag",
        "patterns": [r"ai_?flag", r"ml_?feature", r"model_?input", r"automated_?decision", r"consentimiento_?ia"],
        "risk": "high",
        "frameworks": ["gdpr"],
        "recommendation": {
            "es": "Rara vez aparece como columna -- el uso en IA suele decidirse a nivel de pipeline/notebook, no de columna (ver qué notebooks leen esta tabla). RGPD art. 22: si alguna decisión automatizada afecta a la persona, debe poder oponerse.",
            "en": "Rarely stored as a column -- AI usage is usually decided at the pipeline/notebook level, not the column level (check which notebooks read this table). GDPR Art. 22: if any automated decision affects the person, they must be able to object.",
        },
    },
    "third_party_sharing": {
        "es": "Compartición con terceros", "en": "Third-party sharing",
        "patterns": [r"shared_?with", r"third_?party", r"\btercero", r"data_?export"],
        "risk": "high",
        "frameworks": ["gdpr"],
        "recommendation": {
            "es": "Rara vez aparece como columna -- normalmente vive en un registro/log o en contratos, no en una columna de tabla. RGPD art. 13/14: la persona debe ser informada antes de compartir sus datos fuera de la organización.",
            "en": "Rarely stored as a column -- it usually lives in a log/record or in contracts, not a table column. GDPR Art. 13/14: the person must be informed before their data is shared outside the organization.",
        },
    },
    "special_category_belief": {
        "es": "Categoría especial (creencias/origen)", "en": "Special category (beliefs/origin)",
        "patterns": [r"religio", r"\betnia\b", r"ethnic", r"\braza\b", r"\brace\b", r"political_?affiliation", r"union_?member", r"sexual_?orientation"],
        "risk": "very_high",
        "frameworks": ["gdpr_special"],
        "recommendation": {
            "es": "Categoría especial (art. 9 RGPD) -- rara vez aparece como columna. Si aparece, requiere consentimiento explícito o base legal reforzada; nunca debería compartirse ni usarse para perfilado.",
            "en": "Special category (GDPR Art. 9) -- rarely stored as a column. If it appears, it requires explicit consent or a reinforced legal basis; it should never be shared or used for profiling.",
        },
    },
    "technical_access": {
        "es": "Acceso técnico (IP/dispositivo)", "en": "Technical access (IP/device)",
        "patterns": [r"ip_?address", r"device_?id", r"user_?agent", r"login_?timestamp", r"access_?log"],
        "risk": "low",
        "frameworks": ["gdpr", "ccpa"],
        # A diferencia de casi todo lo demás en esta lista, los datos de
        # acceso técnico suelen conservarse incluso cuando la persona se
        # opone al resto del tratamiento (soporte de TI, seguridad) -- la
        # recomendación lo refleja en vez de sugerir restricción/supresión.
        "recommendation": {
            "es": "Necesario para soporte técnico/seguridad -- retención habitual y aceptada incluso cuando la persona se opone al resto del procesamiento de sus datos.",
            "en": "Needed for technical support/security -- routine, accepted retention even when the person objects to the rest of their data processing.",
        },
    },
}

# Categories with a content pattern reliable enough to auto-confirm a
# match (see fabric_notebooks/NB_Discover_Column_Sensitivity.py's own
# CONTENT_PATTERNS, which mirrors this exact set -- self-contained
# notebook, can't import this module directly, same reasoning as every
# other notebook's small local copy of a shared helper). The rest
# (person_name/address/birth_date/gender/health) have no reliable
# structured format to regex-match -- a name-flagged column in one of
# those still gets sampled for the admin to eyeball (see RISK_LABELS/
# get_category_meta), it just never gets an automatic match_percentage.
CONTENT_PATTERN_CATEGORIES = {"email", "phone", "national_id", "financial"}

# Roadmap Fase 6 (2026-08-31, follow-up to the privacy locator): which
# legal framework(s) make each category above sensitive -- lets the
# Privacidad panel/MCP browse "what data do we have under GDPR" as its own
# menu, instead of only the flat 22-category list Fase 5 shipped. A
# category can (and often does) belong to more than one framework at once
# (e.g. "biometric" is both a GDPR Art. 9 special category AND CCPA's own
# statutory category 5) -- SENSITIVITY_CATEGORIES' own "frameworks" list
# on each entry is the source of truth for that; this dict is just the
# framework's own display metadata (label + one-line description of what
# it covers), not a re-derivation of which categories belong to it.
#
# "gdpr" = GDPR Art. 4 general personal data. "gdpr_special" = GDPR Art. 9
# special category (stricter legal basis required). "gdpr_criminal" =
# GDPR Art. 10 criminal-offence/disciplinary data (its own separate
# safeguard, distinct from Art. 9). "ferpa" = US Family Educational
# Rights and Privacy Act (education records). "ccpa" = California
# Consumer Privacy Act/CPRA's 11 statutory categories of personal
# information (relevant to any organization holding data about US
# residents; nothing here is California-specific).
PRIVACY_FRAMEWORKS = {
    "gdpr": {
        "es": "RGPD", "en": "GDPR",
        "description_es": "Reglamento General de Protección de Datos (UE) -- dato personal en general (art. 4).",
        "description_en": "EU General Data Protection Regulation -- personal data in general (Art. 4).",
    },
    "gdpr_special": {
        "es": "RGPD - Categoría especial", "en": "GDPR - Special category",
        "description_es": "RGPD art. 9 -- origen étnico/racial, salud, biométrico, creencias, orientación sexual. Requiere consentimiento explícito o base legal reforzada.",
        "description_en": "GDPR Art. 9 -- ethnic/racial origin, health, biometric, beliefs, sexual orientation. Requires explicit consent or a reinforced legal basis.",
    },
    "gdpr_criminal": {
        "es": "RGPD - Datos penales/disciplinarios", "en": "GDPR - Criminal/disciplinary data",
        "description_es": "RGPD art. 10 -- condenas e infracciones penales, procedimientos sancionadores/disciplinarios.",
        "description_en": "GDPR Art. 10 -- criminal convictions and offences, disciplinary proceedings.",
    },
    "ferpa": {
        "es": "FERPA (EEUU)", "en": "FERPA (US)",
        "description_es": "Family Educational Rights and Privacy Act -- expediente académico y registros educativos.",
        "description_en": "Family Educational Rights and Privacy Act -- academic record and education records.",
    },
    "ccpa": {
        "es": "CCPA/CPRA (California, EEUU)", "en": "CCPA/CPRA (California, US)",
        "description_es": "California Consumer Privacy Act -- 11 categorías estatutarias de información personal.",
        "description_en": "California Consumer Privacy Act -- 11 statutory categories of personal information.",
    },
}

RISK_LABELS = {
    "low": {"es": "Bajo", "en": "Low"},
    "medium": {"es": "Medio", "en": "Medium"},
    "high": {"es": "Alto", "en": "High"},
    "very_high": {"es": "Muy alto", "en": "Very high"},
}

_COMPILED = {
    key: re.compile("|".join(meta["patterns"]), re.IGNORECASE) for key, meta in SENSITIVITY_CATEGORIES.items()
}


# Roadmap Fase 2 (2026-08-31, Purview-parity push): lets an admin add their
# own name-pattern categories on top of the 9 built-in ones above, without
# touching code -- entries come from admin_settings.json's
# custom_sensitivity_categories (see constants.py's DEFAULT_ADMIN_SETTINGS),
# same admin-curated-list pattern as certified_items/tags/data_quality_
# rules elsewhere in this project. Deliberately NOT merged into
# SENSITIVITY_CATEGORIES/_COMPILED at import time -- unlike the built-in
# set, this can change between one admin save and the next within the same
# running process (the web server never restarts on a settings save), so
# it has to be recompiled per call instead of once at module load.
#
# Only wired into the LIVE web-server path today (purview_insights.py's
# by-name sensitivity overview, GET /api/admin/sensitivity-overview) --
# takes effect immediately, no rescan needed, since that's a pure-Python
# evaluation at request time. Deliberately NOT wired into build_graph_map_
# index.py (the 3D graph map's own sensitivity coloring -- already a
# secondary, local-build-only path per _get_sensitivity_overview's own
# docstring) or into either Fabric notebook's hand-ported copy of this
# classifier (NB_Build_Graph_Map.py, NB_Discover_Column_Sensitivity.py --
# those run inside Fabric, disconnected from admin_settings.json, and
# would need a real notebook redeploy + rescan to pick up new patterns
# even if wired) -- a deliberate scope decision this round, not an
# oversight, so it doesn't get silently promised in three places it
# doesn't actually reach yet.
def _custom_category_registry(custom_categories):
    """custom_categories: the raw admin_settings.json list (each entry:
    {key, label_es, label_en, patterns, risk, recommendation_es,
    recommendation_en}). Returns (meta_by_key, compiled_by_key) in the
    same shape as SENSITIVITY_CATEGORIES/_COMPILED. An entry is silently
    skipped (not raised) when its key collides with a built-in category
    (built-ins always win -- an admin can't shadow "email"'s real
    definition), has no patterns, or has a regex that fails to compile
    (one admin typo must not break classification for every other column
    in the same request)."""
    meta_by_key = {}
    compiled_by_key = {}
    for entry in custom_categories or []:
        key = (entry.get("key") or "").strip()
        patterns = [p for p in (entry.get("patterns") or []) if p]
        if not key or key in SENSITIVITY_CATEGORIES or not patterns:
            continue
        try:
            compiled = re.compile("|".join(patterns), re.IGNORECASE)
        except re.error:
            continue
        label_es = entry.get("label_es") or key
        meta_by_key[key] = {
            "es": label_es,
            "en": entry.get("label_en") or label_es,
            "patterns": patterns,
            "risk": entry.get("risk") if entry.get("risk") in RISK_LABELS else "medium",
            "recommendation": {"es": entry.get("recommendation_es", ""), "en": entry.get("recommendation_en", "")},
            # Optional -- an admin-defined category has no obligation to map
            # to a real legal framework (it might just be an org-specific
            # thing to watch for), unlike every built-in category above,
            # which always has at least one. Unknown framework keys (a typo,
            # or a framework this project doesn't know about) are silently
            # dropped rather than raised, same "one bad entry can't break
            # this for everyone" posture as the rest of this function.
            "frameworks": [f for f in (entry.get("frameworks") or []) if f in PRIVACY_FRAMEWORKS],
        }
        compiled_by_key[key] = compiled
    return meta_by_key, compiled_by_key


def classify_column_name(column_name, custom_categories=None):
    """Returns a list of category keys (possibly empty) a single column
    name matches. A column can legitimately match more than one category
    (e.g. "CONTACT_EMAIL_PHONE" -- rare, but the classifier doesn't assume
    exclusivity). custom_categories (optional): admin-defined categories to
    check in addition to the 9 built-in ones -- compiled fresh on every
    call, which is fine for one column; classify_columns below compiles
    once and reuses it across a whole batch instead, since that's the path
    that actually runs at tenant scale."""
    if not column_name:
        return []
    matches = [key for key, pattern in _COMPILED.items() if pattern.search(column_name)]
    if custom_categories:
        _, compiled_custom = _custom_category_registry(custom_categories)
        matches.extend(key for key, pattern in compiled_custom.items() if pattern.search(column_name))
    return matches


def classify_columns(column_names, custom_categories=None):
    """Returns the set of every distinct category matched across a list of
    column names (e.g. every column in one table/object)."""
    _, compiled_custom = _custom_category_registry(custom_categories) if custom_categories else ({}, {})
    categories = set()
    for name in column_names:
        if not name:
            continue
        categories.update(key for key, pattern in _COMPILED.items() if pattern.search(name))
        if compiled_custom:
            categories.update(key for key, pattern in compiled_custom.items() if pattern.search(name))
    return categories


def category_label(key, lang="es", custom_categories=None):
    meta = SENSITIVITY_CATEGORIES.get(key)
    if meta is None and custom_categories:
        meta_by_key, _ = _custom_category_registry(custom_categories)
        meta = meta_by_key.get(key)
    if not meta:
        return key
    return meta.get(lang, meta.get("es", key))


def category_risk(key, custom_categories=None):
    meta = SENSITIVITY_CATEGORIES.get(key)
    if meta is None and custom_categories:
        meta_by_key, _ = _custom_category_registry(custom_categories)
        meta = meta_by_key.get(key)
    return (meta or {}).get("risk", "")


def category_risk_label(key, lang="es", custom_categories=None):
    risk = category_risk(key, custom_categories)
    meta = RISK_LABELS.get(risk)
    return meta.get(lang, meta.get("es", risk)) if meta else ""


def category_recommendation(key, lang="es", custom_categories=None):
    meta = SENSITIVITY_CATEGORIES.get(key)
    if meta is None and custom_categories:
        meta_by_key, _ = _custom_category_registry(custom_categories)
        meta = meta_by_key.get(key)
    recommendation = (meta or {}).get("recommendation") or {}
    return recommendation.get(lang, recommendation.get("es", ""))


def category_frameworks(key, custom_categories=None):
    """Roadmap Fase 6 (2026-08-31): which PRIVACY_FRAMEWORKS key(s) this
    category belongs to -- [] for an unknown key or a custom category that
    never declared any (see _custom_category_registry's own comment)."""
    meta = SENSITIVITY_CATEGORIES.get(key)
    if meta is None and custom_categories:
        meta_by_key, _ = _custom_category_registry(custom_categories)
        meta = meta_by_key.get(key)
    return list((meta or {}).get("frameworks") or [])
