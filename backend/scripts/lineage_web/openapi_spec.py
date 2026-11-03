"""Generates a real OpenAPI 3.0 spec from routes.py's route registry
(Tanda 5, E.4) -- served live at GET /api/openapi.json rather than as a
pre-built static file, since the spec describes this server's own code
shape (not scanned tenant data) and would otherwise risk drifting out of
sync with routes.py between rebuilds.
"""
from .routes import ROUTES

_AUTH_TO_SECURITY = {
    "public": [],
    "session": [{"sessionCookie": []}],
    "admin": [{"sessionCookie": []}],
    "session_or_api_key": [{"sessionCookie": []}, {"apiKeyHeader": []}],
    "admin_or_api_key": [{"sessionCookie": []}, {"apiKeyHeader": []}],
}


def _operation_for(route):
    operation = {
        "summary": route["description"],
        "responses": {
            "200": {"description": "Success", "content": {"application/json": {}}},
        },
    }
    if route["auth"] == "admin":
        operation["responses"]["401"] = {"description": "Not signed in"}
        operation["responses"]["403"] = {"description": "Signed in, but not on the admin allowlist"}
    elif route["auth"] == "admin_or_api_key":
        operation["responses"]["401"] = {"description": "Not signed in, and no valid X-Api-Key"}
        operation["responses"]["403"] = {"description": "Signed in, but not on the admin allowlist (a valid API key bypasses this check)"}
    elif route["auth"] in ("session", "session_or_api_key"):
        operation["responses"]["401"] = {"description": "Not signed in, and (if applicable) no valid X-Api-Key"}

    params = route.get("params")
    if params:
        operation["parameters"] = [
            {
                "name": param["name"],
                "in": param["in"],
                "required": param["required"],
                "description": param.get("description", ""),
                "schema": {"type": param.get("type", "string")},
            }
            for param in params
        ]

    request_body = route.get("request_body")
    if request_body:
        operation["requestBody"] = {
            "description": request_body,
            "required": True,
            "content": {"application/json": {"schema": {"type": "object"}}},
        }

    security = _AUTH_TO_SECURITY[route["auth"]]
    if security:
        operation["security"] = security

    return operation


def _build_openapi_spec():
    paths = {}
    for route in ROUTES:
        path_item = paths.setdefault(route["path"], {})
        path_item[route["method"].lower()] = _operation_for(route)

    return {
        "openapi": "3.0.3",
        "info": {
            "title": "Fabric Lineage Mapper API",
            "version": "1.0.0",
            "description": (
                "Scan trigger, Entra ID device-code sign-in, admin configuration, "
                "and a read-only workspaces/items/objects/lineage query API over "
                "this project's own scanned Fabric tenant catalog. Generated live "
                "from backend/scripts/lineage_web/routes.py."
            ),
        },
        "components": {
            "securitySchemes": {
                "sessionCookie": {
                    "type": "apiKey",
                    "in": "cookie",
                    "name": "fabric_lineage_session",
                    "description": "Set by GET /api/auth/device-status once an Entra ID device-code sign-in completes.",
                },
                "apiKeyHeader": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "X-Api-Key",
                    "description": "A static key created via POST /api/admin/api-keys, for machine-to-machine callers (e.g. a Fabric pipeline's Web activity) that can't do an interactive sign-in.",
                },
            },
        },
        "paths": paths,
    }
