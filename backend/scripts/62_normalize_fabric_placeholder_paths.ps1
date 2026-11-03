# Phase 62 - Thin PowerShell wrapper around
# backend/scripts/62_normalize_fabric_placeholder_paths.py (see that file's
# docstring): normalizes raw notebook/CopyJob code placeholders (Lakehouse
# ID variables, OneLake abfss paths) inside the explorer JSON into the
# canonical Lakehouse.schema.object form so the UI never leaks technical
# placeholders, keeping the raw form in an alias CSV for audit.
param(
    [string]$PythonCommand = "python3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

& $PythonCommand "backend/scripts/62_normalize_fabric_placeholder_paths.py"
if ($LASTEXITCODE -ne 0) {
    throw "backend/scripts/62_normalize_fabric_placeholder_paths.py exited with code $LASTEXITCODE"
}
