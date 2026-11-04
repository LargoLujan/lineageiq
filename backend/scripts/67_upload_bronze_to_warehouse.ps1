# Phase 67 - Bronze upload straight into a Fabric WAREHOUSE, via direct
# T-SQL bulk insert over the same TDS connection every other SQL-endpoint
# script in this project already uses (see 66_test_external_source_
# connection.ps1's SQL-Server-family branch) -- not OneLake Files + a
# Spark notebook like 64_upload_bronze_to_onelake.py's Lakehouse path.
#
# Why a Warehouse and not a Lakehouse: a Lakehouse's SQL analytics endpoint
# is query-only -- no INSERT/CREATE TABLE, confirmed. A Fabric
# Warehouse's SQL endpoint is genuinely read-write T-SQL, so writing tables
# there needs nothing beyond a normal SqlConnection + SqlBulkCopy, no
# notebook step to paste in and no OneLake staging area. Reads the exact
# same admin_settings.json "lakehouse" config (mirrored to config/
# lakehouse_target.json) that the admin panel's write-target tab now lets
# an admin point at either a Lakehouse or a Warehouse -- this script only
# actually works against the latter (a Lakehouse SQL endpoint will
# correctly fail every CREATE TABLE with a permissions error, not silently
# do nothing).
#
# Bronze here means exactly what it means everywhere else in this project
# (see docs/101_medallion_lakehouse_provisioning.md and item_history's own
# bronze framing): raw, untyped columns, every one VARCHAR(8000) (Fabric
# Warehouse's T-SQL surface rejects NVARCHAR outright, confirmed live).
#
# Cost/traffic efficiency (avoid rewriting a table that hasn't actually
# changed): each entity's source CSV is content-
# hashed and compared against the hash recorded the last time it was
# successfully uploaded -- if unchanged, that entity is skipped entirely,
# no bulk-load/MERGE traffic at all. If it DID change but the destination
# table already exists with the exact same columns, the new data is bulk-
# loaded into a throwaway staging table and reconciled into the real table
# with a single MERGE (matched on every column, since none of these 128
# varied CSVs has a catalogued per-entity business key) -- rows identical
# to what's already there are never touched, only the rows that were
# actually added or removed get written. A DROP+CREATE+full reload only
# still happens for a genuinely first-ever upload of an entity, or when its
# CSV's column set itself changed since the table was created (no safe way
# to MERGE across a schema change).
#
# The "what changed since last time" state itself lives INSIDE the
# Warehouse (dbo._bronze_upload_state, one row per entity), not in a local
# file (this must not depend on anything that
# would disappear once local CSVs are eventually retired -- the Warehouse
# is meant to become the permanent, self-sufficient store, not just a
# mirror something else keeps track of). Read once at the top of the run
# (a single small query, not per-entity) and upserted back after every
# entity that actually changes -- adds a handful of small metadata queries
# per run, not the 128-way full staging+MERGE cost skipping this state
# entirely would (measured live: 31s with state vs 17m20s without).
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json"),
    [string]$AzCommand = "az",
    [switch]$DryRun,
    [string]$ProgressPath = (Join-Path $PSScriptRoot "../../analysis/single_workspace_scan/progress.json"),
    [int]$ConnectTimeoutSeconds = 30,
    [int]$CommandTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The first 21 entries were originally kept in sync by hand with
# 64_upload_bronze_to_onelake.py's ENTITY_SOURCE_PATHS; this list has since
# grown past that one on purpose, to cover everything already scanned
# locally and more (not just the first 21). Every index/*.csv and
# analysis/*.csv finished catalog/summary output now included too --
# deliberately EXCLUDING two categories that don't belong in a permanent
# queryable table: (1) the d1_-d8_/e1_/e2_/probe_/notebook_lineage_batch_
# files, which are working artifacts of the iterative human-review
# methodology used to BUILD this lineage model (review queues, decision
# templates, one-off connectivity probes), not the model's own data; (2)
# nothing under analysis/'s dated one-off subdirectories. Also excludes any
# one-off HR/staff entity a fork of this project adds for its own tenant --
# those commonly contain real staff names/emails, and should only be added
# here after an explicit, confirmed decision to do so, never as a default.
$Entities = [ordered]@{
    workspaces                              = "index/workspaces.csv"
    items                                    = "index/items.csv"
    item_analysis                            = "index/item_analysis.csv"
    dependencies                             = "index/dependencies.csv"
    executions                               = "index/executions.csv"
    object_column_catalog                    = "analysis/object_column_catalog.csv"
    object_impact_index                      = "analysis/object_impact_index.csv"
    object_read_write_classification         = "analysis/object_read_write_classification.csv"
    notebook_super_lineage_objects           = "analysis/notebook_super_lineage_objects.csv"
    notebook_super_lineage_flows             = "analysis/notebook_super_lineage_flows.csv"
    semantic_model_datamart_dependencies     = "analysis/semantic_model_datamart_dependencies.csv"
    semantic_model_report_dependencies       = "analysis/semantic_model_report_dependencies.csv"
    workspace_governance_principals          = "analysis/workspace_governance_principals.csv"
    deployment_pipelines                     = "index/deployment_pipelines.csv"
    deployment_pipeline_stages               = "index/deployment_pipeline_stages.csv"
    deployment_pipeline_stage_items          = "index/deployment_pipeline_stage_items.csv"
    source_object_type_overrides             = "index/source_object_type_overrides.csv"
    manual_lineage_object_evidence           = "index/manual_lineage_object_evidence.csv"
    source_object_type_metadata_evidence     = "analysis/source_object_type_metadata_evidence.csv"
    sql_endpoint_object_catalog              = "analysis/sql_endpoint_object_catalog.csv"
    item_history                             = "analysis/item_history.csv"
    discovery_layers                                                 = "index/discovery_layers.csv"
    fabric_connections                                               = "index/fabric_connections.csv"
    tooling_inventory                                                = "index/tooling_inventory.csv"
    workspace_git_connections                                        = "index/workspace_git_connections.csv"
    workspace_role_assignments                                       = "index/workspace_role_assignments.csv"
    control_framework_lineage_candidates                             = "analysis/control_framework_lineage_candidates.csv"
    control_framework_lineage_gaps                                   = "analysis/control_framework_lineage_gaps.csv"
    credential_required_metadata_objects                             = "analysis/credential_required_metadata_objects.csv"
    credential_required_metadata_targets                             = "analysis/credential_required_metadata_targets.csv"
    critical_path_candidates                                         = "analysis/critical_path_candidates.csv"
    deep_object_lineage_gaps                                         = "analysis/deep_object_lineage_gaps.csv"
    deep_object_lineage_item_enrichment                              = "analysis/deep_object_lineage_item_enrichment.csv"
    deep_object_lineage_source_objects                               = "analysis/deep_object_lineage_source_objects.csv"
    deployment_pipeline_discovery_gaps                               = "analysis/deployment_pipeline_discovery_gaps.csv"
    deployment_pipeline_workspace_groups                             = "analysis/deployment_pipeline_workspace_groups.csv"
    evidence_hardening_queue                                         = "analysis/evidence_hardening_queue.csv"
    evidence_hardening_summary                                       = "analysis/evidence_hardening_summary.csv"
    execution_duration_by_item                                       = "analysis/execution_duration_by_item.csv"
    execution_query_gaps                                             = "analysis/execution_query_gaps.csv"
    execution_timing_summary                                         = "analysis/execution_timing_summary.csv"
    failure_hotspots                                                 = "analysis/failure_hotspots.csv"
    graph_summary                                                    = "analysis/graph_summary.csv"
    graph_validation                                                 = "analysis/graph_validation.csv"
    ideal_execution_edges                                            = "analysis/ideal_execution_edges.csv"
    ideal_execution_plan                                             = "analysis/ideal_execution_plan.csv"
    ideal_execution_summary                                          = "analysis/ideal_execution_summary.csv"
    ideal_execution_waves                                            = "analysis/ideal_execution_waves.csv"
    item_object_lineage_candidates                                   = "analysis/item_object_lineage_candidates.csv"
    item_object_lineage_gaps                                         = "analysis/item_object_lineage_gaps.csv"
    likely_conflict_cleanup_phase_plan                               = "analysis/likely_conflict_cleanup_phase_plan.csv"
    likely_conflict_cleanup_queue                                    = "analysis/likely_conflict_cleanup_queue.csv"
    likely_conflict_cleanup_summary                                  = "analysis/likely_conflict_cleanup_summary.csv"
    lineage_explorer_gaps                                            = "analysis/lineage_explorer_gaps.csv"
    manual_execution_candidates                                      = "analysis/manual_execution_candidates.csv"
    manual_lineage_review_queue                                      = "analysis/manual_lineage_review_queue.csv"
    manual_lineage_review_summary                                    = "analysis/manual_lineage_review_summary.csv"
    notebook_code_deep_review                                        = "analysis/notebook_code_deep_review.csv"
    notebook_code_deep_review_summary                                = "analysis/notebook_code_deep_review_summary.csv"
    notebook_definition_download_manifest                            = "analysis/notebook_definition_download_manifest.csv"
    notebook_definition_download_probe_manifest                      = "analysis/notebook_definition_download_probe_manifest.csv"
    notebook_lineage_flow_catalog                                    = "analysis/notebook_lineage_flow_catalog.csv"
    notebook_lineage_path_aliases                                    = "analysis/notebook_lineage_path_aliases.csv"
    notebook_lineage_review_batches                                  = "analysis/notebook_lineage_review_batches.csv"
    notebook_lineage_review_summary                                  = "analysis/notebook_lineage_review_summary.csv"
    notebook_lineage_touchpoints                                     = "analysis/notebook_lineage_touchpoints.csv"
    notebook_no_object_gap_closure                                   = "analysis/notebook_no_object_gap_closure.csv"
    notebook_no_object_gap_closure_summary                           = "analysis/notebook_no_object_gap_closure_summary.csv"
    notebook_super_lineage_gaps                                      = "analysis/notebook_super_lineage_gaps.csv"
    notebook_super_lineage_summary                                   = "analysis/notebook_super_lineage_summary.csv"
    object_column_catalog_status                                     = "analysis/object_column_catalog_status.csv"
    object_column_catalog_summary                                    = "analysis/object_column_catalog_summary.csv"
    object_impact_summary                                            = "analysis/object_impact_summary.csv"
    object_level_lineage_coverage                                    = "analysis/object_level_lineage_coverage.csv"
    object_level_lineage_summary                                     = "analysis/object_level_lineage_summary.csv"
    object_lineage_candidate_hardening_review                        = "analysis/object_lineage_candidate_hardening_review.csv"
    object_lineage_candidate_hardening_summary                       = "analysis/object_lineage_candidate_hardening_summary.csv"
    object_read_write_summary                                        = "analysis/object_read_write_summary.csv"
    orchestration_group_candidates                                   = "analysis/orchestration_group_candidates.csv"
    orchestration_recommendations                                    = "analysis/orchestration_recommendations.csv"
    orchestration_v2_edges                                           = "analysis/orchestration_v2_edges.csv"
    orchestration_v2_object_conflicts                                = "analysis/orchestration_v2_object_conflicts.csv"
    orchestration_v2_parallel_candidates                             = "analysis/orchestration_v2_parallel_candidates.csv"
    orchestration_v2_plan                                            = "analysis/orchestration_v2_plan.csv"
    orchestration_v2_summary                                         = "analysis/orchestration_v2_summary.csv"
    orchestration_v2_waves                                           = "analysis/orchestration_v2_waves.csv"
    parallelism_candidates                                           = "analysis/parallelism_candidates.csv"
    pipeline_activity_lineage                                        = "analysis/pipeline_activity_lineage.csv"
    pipeline_object_lineage_candidates                               = "analysis/pipeline_object_lineage_candidates.csv"
    pipeline_object_lineage_gaps                                     = "analysis/pipeline_object_lineage_gaps.csv"
    pro_notebook_items_for_rescan                                    = "analysis/pro_notebook_items_for_rescan.csv"
    pro_semantic_report_notebook_inventory                           = "analysis/pro_semantic_report_notebook_inventory.csv"
    read_only_metadata_access_request_targets                        = "analysis/read_only_metadata_access_request_targets.csv"
    schedule_review_candidates                                       = "analysis/schedule_review_candidates.csv"
    semantic_datamart_summary                                        = "analysis/semantic_datamart_summary.csv"
    semantic_model_definition_gaps                                   = "analysis/semantic_model_definition_gaps.csv"
    semantic_model_lineage_summary                                   = "analysis/semantic_model_lineage_summary.csv"
    semantic_model_source_classification                             = "analysis/semantic_model_source_classification.csv"
    semantic_model_view_candidates                                   = "analysis/semantic_model_view_candidates.csv"
    sharepoint_source_object_type_evidence                           = "analysis/sharepoint_source_object_type_evidence.csv"
    source_object_type_casefold_catalog_evidence                     = "analysis/source_object_type_casefold_catalog_evidence.csv"
    source_object_type_deep_catalog_gap_evidence                     = "analysis/source_object_type_deep_catalog_gap_evidence.csv"
    source_object_type_metadata_gaps                                 = "analysis/source_object_type_metadata_gaps.csv"
    source_object_type_metadata_summary                              = "analysis/source_object_type_metadata_summary.csv"
    source_object_type_resolution_queue                              = "analysis/source_object_type_resolution_queue.csv"
    source_object_type_resolution_summary                            = "analysis/source_object_type_resolution_summary.csv"
    sql_endpoint_object_catalog_status                               = "analysis/sql_endpoint_object_catalog_status.csv"
    sql_endpoint_object_catalog_summary                              = "analysis/sql_endpoint_object_catalog_summary.csv"
    sql_server_deep_catalog_columns                                  = "analysis/sql_server_deep_catalog_columns.csv"
    sql_server_deep_catalog_databases                                = "analysis/sql_server_deep_catalog_databases.csv"
    sql_server_deep_catalog_dependencies                             = "analysis/sql_server_deep_catalog_dependencies.csv"
    sql_server_deep_catalog_gaps                                     = "analysis/sql_server_deep_catalog_gaps.csv"
    sql_server_deep_catalog_more_sql_columns                         = "analysis/sql_server_deep_catalog_more_sql_columns.csv"
    sql_server_deep_catalog_more_sql_databases                       = "analysis/sql_server_deep_catalog_more_sql_databases.csv"
    sql_server_deep_catalog_more_sql_dependencies                    = "analysis/sql_server_deep_catalog_more_sql_dependencies.csv"
    sql_server_deep_catalog_more_sql_gaps                            = "analysis/sql_server_deep_catalog_more_sql_gaps.csv"
    sql_server_deep_catalog_more_sql_objects                         = "analysis/sql_server_deep_catalog_more_sql_objects.csv"
    sql_server_deep_catalog_more_sql_summary                         = "analysis/sql_server_deep_catalog_more_sql_summary.csv"
    sql_server_deep_catalog_objects                                  = "analysis/sql_server_deep_catalog_objects.csv"
    sql_server_deep_catalog_summary                                  = "analysis/sql_server_deep_catalog_summary.csv"
    top_graph_nodes                                                  = "analysis/top_graph_nodes.csv"
    workspace_deployment_pipeline_membership                         = "analysis/workspace_deployment_pipeline_membership.csv"
    workspace_devops_link_candidates                                 = "analysis/workspace_devops_link_candidates.csv"
    workspace_governance_devops_gaps                                 = "analysis/workspace_governance_devops_gaps.csv"
    workspace_governance_enrichment                                  = "analysis/workspace_governance_enrichment.csv"
    # Added for the SQL-migration pilot (39_build_d1_closure_
    # control.ps1's main input): the D1-D8 "queue" files are real
    # computational data other steps depend on, not the human-review
    # scratch (decision templates, manual evidence templates) the rest of
    # the d1_-d8_ family was deliberately excluded for -- see that
    # exclusion's own reasoning further up. Only added as each one is
    # actually needed by a step being migrated, not the whole D1-D8 family
    # at once.
    d1_missing_object_lineage_queue                                  = "analysis/d1_missing_object_lineage_queue.csv"
    d2_likely_dependency_edge_queue                                  = "analysis/d2_likely_dependency_edge_queue.csv"
    d2_likely_dependency_item_queue                                  = "analysis/d2_likely_dependency_item_queue.csv"
    d3_likely_object_lineage_object_queue                            = "analysis/d3_likely_object_lineage_object_queue.csv"
    d3_likely_object_lineage_item_queue                              = "analysis/d3_likely_object_lineage_item_queue.csv"
    d4_exact_object_type_source_queue                                = "analysis/d4_exact_object_type_source_queue.csv"
    d4_exact_object_type_impact_queue                                = "analysis/d4_exact_object_type_impact_queue.csv"
    d5_object_conflict_queue                                         = "analysis/d5_object_conflict_queue.csv"
    d5_object_guard_edge_queue                                       = "analysis/d5_object_guard_edge_queue.csv"
    d5_object_conflict_participants                                  = "analysis/d5_object_conflict_participants.csv"
    d6_failure_duration_queue                                        = "analysis/d6_failure_duration_queue.csv"
    d6_failure_hotspot_queue                                         = "analysis/d6_failure_hotspot_queue.csv"
    d6_duration_stabilization_queue                                  = "analysis/d6_duration_stabilization_queue.csv"
    d6_execution_evidence                                            = "analysis/d6_execution_evidence.csv"
    d7_orchestration_review_queue                                    = "analysis/d7_orchestration_review_queue.csv"
    d7_nonprod_candidate_queue                                       = "analysis/d7_nonprod_candidate_queue.csv"
    d7_wave_promotion_queue                                          = "analysis/d7_wave_promotion_queue.csv"
    # Added for 05_build_graph.ps1 (it reads its own prior
    # graph/nodes.csv output to retain ExternalConnection nodes no longer
    # referenced by a current dependency -- same self-referential pattern
    # as the semantic_model_view_candidates backfill chain).
    graph_nodes                                                      = "graph/nodes.csv"
}

# Same shape/path as scan_single_workspace.ps1's Write-ScanProgress, just a
# distinct scan_kind/workspace label ("__warehouse_upload__", same
# convention as the executions-only scan's "__production_executions__") --
# GET /api/status already matches progress.json's "workspace" field against
# the running scan's own label, so the *exact same* progress bar the admin
# panel already shows for a normal scan (percentage + elapsed time + current
# step) picks this operation up for free, no new frontend polling needed.
function Write-UploadProgress {
    param([string]$CurrentStepName, [string]$Phase = "running", [int]$CompletedSteps = 0, [int]$TotalSteps = 1)
    $progress = [pscustomobject]@{
        scan_kind          = "warehouse_upload"
        workspace           = "__warehouse_upload__"
        completed_steps     = $CompletedSteps
        total_steps         = $TotalSteps
        current_step_name   = $CurrentStepName
        phase               = $Phase
        updated_at          = (Get-Date).ToString("o")
        steps               = @()
    }
    $parent = Split-Path -Parent $ProgressPath
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $progress | ConvertTo-Json -Depth 6 | Set-Content -Path $ProgressPath -Encoding UTF8
}

function Get-ServicePrincipalAccessToken {
    # Plain OAuth2 client-credentials call against Entra's v2.0 token
    # endpoint -- what makes this upload PERMANENT: a scheduled/unattended
    # run (no signed-in user, no `az login` on this machine) still gets a
    # token, because it's the app registration's own secret, not anyone's
    # session. See 66_test_external_source_connection.ps1's identical
    # helper -- kept as a separate copy per this project's existing
    # convention of small per-script token helpers rather than a shared
    # import (see the other Get-AzureCliToken/Get-DatabaseAccessToken
    # copies across the scan scripts).
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://database.windows.net/.default"
        grant_type    = "client_credentials"
    }
    try {
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        $detail = $_.ErrorDetails.Message
        throw "Could not acquire a service-principal database token: $detail"
    }
    if (-not $response.access_token) {
        throw "Entra returned no access_token for the configured service principal."
    }
    return [string]$response.access_token
}

function Get-DatabaseAccessToken {
    param(
        [string]$AzCommand,
        # Priority, highest first: (1) a configured service principal --
        # permanent, the right choice here since this script is meant to
        # run unattended after every scan, not only while someone happens
        # to be signed in; (2) a signed-in web-app user's own delegated SQL
        # token, if the process that spawned this script set one (see
        # FABRIC_LINEAGE_USER_SQL_TOKEN in scan_manager.py) -- used for a
        # manual "Copiar datos ahora" click before a service principal is
        # configured; (3) the shared `az` CLI session, when run standalone
        # from a terminal, exactly like 34_extract_sql_endpoint_object_
        # catalog.ps1's identical helper.
        [string]$SpTenantId = "",
        [string]$SpClientId = "",
        [string]$SpClientSecret = ""
    )
    if ($SpTenantId -and $SpClientId -and $SpClientSecret) {
        return Get-ServicePrincipalAccessToken -TenantId $SpTenantId -ClientId $SpClientId -ClientSecret $SpClientSecret
    }
    if ($env:FABRIC_LINEAGE_USER_SQL_TOKEN) { return $env:FABRIC_LINEAGE_USER_SQL_TOKEN }
    $token = & $AzCommand account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "Could not acquire Azure SQL/Fabric database token with '$AzCommand account get-access-token'."
    }
    return [string]$token
}

$repoRoot = Join-Path $PSScriptRoot "../.."
$totalSteps = $Entities.Count

if (-not (Test-Path $ConfigPath)) {
    Write-Host "No write-target configured yet ($ConfigPath not found) -- nothing to upload."
    Write-UploadProgress -CurrentStepName "No write-target configured" -Phase "done" -CompletedSteps 0 -TotalSteps 1
    exit 0
}
$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
# A mirrored config/lakehouse_target.json written before the service-
# principal fields existed won't have these properties at all -- and
# Set-StrictMode (top of this script) throws on accessing a genuinely
# missing property, not just an empty one. Back-fill with blanks so an
# old file behaves exactly like a fresh one with these fields left empty
# (falls through to the user-session/az fallback in Get-DatabaseAccessToken),
# instead of crashing the whole upload over a stale mirror the admin never
# re-saved.
foreach ($spProperty in @("sp_tenant_id", "sp_client_id", "sp_client_secret_ref")) {
    if (-not (Get-Member -InputObject $config -Name $spProperty -MemberType NoteProperty)) {
        $config | Add-Member -NotePropertyName $spProperty -NotePropertyValue ""
    }
}
if (-not $config.sql_endpoint_connection_string -or -not $config.lakehouse_name) {
    Write-Host "Write-target SQL endpoint or item name not configured yet -- nothing to upload. Fill it in from the admin panel's write-target tab."
    Write-UploadProgress -CurrentStepName "Write-target not configured" -Phase "done" -CompletedSteps 0 -TotalSteps 1
    exit 0
}

if ($DryRun) {
    Write-UploadProgress -CurrentStepName "Dry run" -Phase "running" -CompletedSteps 0 -TotalSteps $totalSteps
    foreach ($entity in $Entities.Keys) {
        $path = Join-Path $repoRoot $Entities[$entity]
        $exists = Test-Path $path
        Write-Host "[dry-run] $entity -> dbo.bronze_$entity ($(if ($exists) { 'source found' } else { 'source missing, will skip' }))"
    }
    Write-UploadProgress -CurrentStepName "Dry run complete" -Phase "done" -CompletedSteps $totalSteps -TotalSteps $totalSteps
    exit 0
}

Add-Type -AssemblyName System.Data

Write-UploadProgress -CurrentStepName "Connecting" -Phase "running" -CompletedSteps 0 -TotalSteps $totalSteps
$spClientSecret = if ($config.sp_client_secret_ref) { [System.Environment]::GetEnvironmentVariable($config.sp_client_secret_ref) } else { $null }
$token = Get-DatabaseAccessToken -AzCommand $AzCommand -SpTenantId $config.sp_tenant_id -SpClientId $config.sp_client_id -SpClientSecret $spClientSecret
$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$builder["Data Source"] = $config.sql_endpoint_connection_string
$builder["Initial Catalog"] = $config.lakehouse_name
$builder["Encrypt"] = $true
$builder["TrustServerCertificate"] = $true
$builder["Connect Timeout"] = $ConnectTimeoutSeconds

$connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
$connection.AccessToken = $token
$connection.Open()

# Per-entity content hash from the last successful upload, kept in the
# Warehouse itself rather than a local file -- see the header comment
# above for why. One small table, one row per entity, read in full ONCE
# here (cheap: ~128 short rows) rather than a per-entity round trip.
$ensureStateTableCmd = $connection.CreateCommand()
$ensureStateTableCmd.CommandTimeout = $CommandTimeoutSeconds
$ensureStateTableCmd.CommandText = "IF OBJECT_ID('dbo._bronze_upload_state', 'U') IS NULL " +
    "CREATE TABLE dbo._bronze_upload_state (entity VARCHAR(200), content_hash VARCHAR(100), row_count VARCHAR(50), uploaded_at VARCHAR(50));"
$ensureStateTableCmd.ExecuteNonQuery() | Out-Null

$state = @{}
$stateReadCmd = $connection.CreateCommand()
$stateReadCmd.CommandText = "SELECT entity, content_hash FROM dbo._bronze_upload_state;"
$stateReader = $stateReadCmd.ExecuteReader()
while ($stateReader.Read()) { $state[$stateReader.GetString(0)] = @{ content_hash = $stateReader.GetString(1) } }
$stateReader.Close()

function Save-EntityState {
    param([string]$Entity, [string]$ContentHash, [int]$RowCount)
    $deleteCmd = $connection.CreateCommand()
    $deleteCmd.CommandTimeout = $CommandTimeoutSeconds
    $deleteCmd.CommandText = "DELETE FROM dbo._bronze_upload_state WHERE entity = @entity;"
    $delParam = $deleteCmd.CreateParameter(); $delParam.ParameterName = "@entity"; $delParam.Value = $Entity
    $deleteCmd.Parameters.Add($delParam) | Out-Null
    $deleteCmd.ExecuteNonQuery() | Out-Null

    $insertCmd = $connection.CreateCommand()
    $insertCmd.CommandTimeout = $CommandTimeoutSeconds
    $insertCmd.CommandText = "INSERT INTO dbo._bronze_upload_state (entity, content_hash, row_count, uploaded_at) VALUES (@entity, @hash, @rows, @uploadedAt);"
    foreach ($pair in @(@("@entity", $Entity), @("@hash", $ContentHash), @("@rows", [string]$RowCount), @("@uploadedAt", (Get-Date).ToString("o")))) {
        $p = $insertCmd.CreateParameter(); $p.ParameterName = $pair[0]; $p.Value = $pair[1]
        $insertCmd.Parameters.Add($p) | Out-Null
    }
    $insertCmd.ExecuteNonQuery() | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]
$completed = 0
try {
    foreach ($entity in $Entities.Keys) {
        Write-UploadProgress -CurrentStepName "Uploading $entity" -Phase "running" -CompletedSteps $completed -TotalSteps $totalSteps
        $sourcePath = Join-Path $repoRoot $Entities[$entity]
        $tableName = "bronze_$entity"
        if (-not (Test-Path $sourcePath)) {
            Write-Host "[skip] $entity`: source not found at $($Entities[$entity])"
            $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "skip"; rows = 0; error = "source not found" })
            $completed += 1
            continue
        }
        try {
            $rows = @(Import-Csv -Path $sourcePath)
            # Wrapping the WHOLE if/else in @() (not just its "else" branch)
            # matters: PowerShell flattens an if-statement's captured output
            # across every branch when assigning it to a variable, so a
            # branch that itself returns @() (zero pipeline objects) collapses
            # the whole assignment to $null, not an empty array -- and $null
            # has no .Count under Set-StrictMode. Real crash on
            # every header-only (zero-row) source CSV: "The property 'Count'
            # cannot be found on this object."
            $columns = @(if ($rows.Count -gt 0) { $rows[0].PSObject.Properties.Name })
            if ($columns.Count -eq 0) {
                Write-Host "[skip] $entity`: no columns found in $sourcePath (empty file)"
                $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "skip"; rows = 0; error = "no columns (empty file)" })
                $completed += 1
                continue
            }

            $contentHash = (Get-FileHash -Algorithm SHA256 -Path $sourcePath).Hash
            $priorState = $state[$entity]

            # Source of truth for "can we MERGE" is the REAL table right
            # now, not the state file (which could be stale, deleted, or
            # from a different Warehouse) -- an empty result also just
            # means the table doesn't exist yet.
            $schemaCmd = $connection.CreateCommand()
            $schemaCmd.CommandTimeout = $CommandTimeoutSeconds
            $schemaCmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @tbl ORDER BY ORDINAL_POSITION;"
            $tblParam = $schemaCmd.CreateParameter(); $tblParam.ParameterName = "@tbl"; $tblParam.Value = $tableName
            $schemaCmd.Parameters.Add($tblParam) | Out-Null
            $existingColumns = @()
            $schemaReader = $schemaCmd.ExecuteReader()
            while ($schemaReader.Read()) { $existingColumns += $schemaReader.GetString(0) }
            $schemaReader.Close()
            $schemaMatches = ($existingColumns.Count -gt 0) -and (($existingColumns | Sort-Object) -join "|") -eq (($columns | Sort-Object) -join "|")

            if ($schemaMatches -and $priorState -and $priorState["content_hash"] -eq $contentHash) {
                Write-Host "[unchanged] $entity`: content identical to last upload, skipped ($($rows.Count) rows)"
                $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "unchanged"; rows = $rows.Count; error = "" })
                $completed += 1
                continue
            }

            # Not just an NVARCHAR(MAX) length problem -- confirmed live
            # against the real Warehouse that NVARCHAR is
            # rejected outright at ANY length ("not supported in this
            # edition of SQL Server", identical error for both MAX and a
            # bounded 4000). A Fabric Warehouse's T-SQL surface area simply
            # doesn't include nvarchar today, unlike a regular Azure SQL/SQL
            # Server database -- VARCHAR(8000), verified working against the
            # same Warehouse, is the practical ceiling instead. Tradeoff:
            # VARCHAR uses the connection's single-byte collation, so a
            # source value with characters outside that codepage (accented
            # Spanish/English text is fine; wider Unicode scripts are not)
            # would get mangled rather than preserved -- acceptable for this
            # bronze layer's actual data, not a general-purpose fix.
            $columnDefs = ($columns | ForEach-Object { "[$($_ -replace '\]', ']]')] VARCHAR(8000)" }) -join ", "

            $table = New-Object System.Data.DataTable
            foreach ($col in $columns) { $table.Columns.Add($col, [string]) | Out-Null }
            foreach ($row in $rows) {
                $dataRow = $table.NewRow()
                foreach ($col in $columns) {
                    $value = [string]($row.$col)
                    # A value longer than the VARCHAR(8000) column it's going
                    # into fails the WHOLE table's bulk copy, not just that
                    # one row -- real case:
                    # deep_object_lineage_source_objects' "evidence" column
                    # had a 20,839-char value, taking all other rows in that
                    # table down with it ("Received an invalid column length
                    # from the bcp client"). Truncating with a visible marker
                    # loses detail on the rare long value but keeps the table
                    # (and every other row in it) usable -- better than an
                    # entire entity silently missing from the Warehouse.
                    if ($value.Length -gt 7990) { $value = $value.Substring(0, 7950) + " ...[truncated]" }
                    $dataRow[$col] = $value
                }
                $table.Rows.Add($dataRow) | Out-Null
            }

            if ($schemaMatches) {
                # Efficient path: table already exists with the exact same
                # columns -- load the new data into a throwaway staging
                # table and MERGE it in, so only rows that actually differ
                # get written. Matches on EVERY column (no catalogued
                # per-entity business key across these 128 varied CSVs): a
                # row that changed even in one field becomes a delete+insert
                # pair rather than a true in-place UPDATE, but a row
                # identical to what's already there is never touched --
                # that's the actual traffic/cost win being asked for, plus
                # the table stays continuously queryable (no DROP gap).
                $stagingTable = "stg_$entity"
                $stageDropCmd = $connection.CreateCommand()
                $stageDropCmd.CommandTimeout = $CommandTimeoutSeconds
                $stageDropCmd.CommandText = "IF OBJECT_ID('dbo.$stagingTable', 'U') IS NOT NULL DROP TABLE dbo.$stagingTable;"
                $stageDropCmd.ExecuteNonQuery() | Out-Null

                $stageCreateCmd = $connection.CreateCommand()
                $stageCreateCmd.CommandTimeout = $CommandTimeoutSeconds
                $stageCreateCmd.CommandText = "CREATE TABLE dbo.$stagingTable ($columnDefs);"
                $stageCreateCmd.ExecuteNonQuery() | Out-Null

                if ($table.Rows.Count -gt 0) {
                    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
                    $bulkCopy.DestinationTableName = "dbo.$stagingTable"
                    $bulkCopy.BulkCopyTimeout = $CommandTimeoutSeconds
                    foreach ($col in $columns) { $bulkCopy.ColumnMappings.Add($col, $col) | Out-Null }
                    $bulkCopy.WriteToServer($table)
                    $bulkCopy.Close()
                }

                $quotedCols = $columns | ForEach-Object { "[$($_ -replace '\]', ']]')]" }
                $onClause = ($quotedCols | ForEach-Object { "tgt.$_ = src.$_" }) -join " AND "
                $colList = $quotedCols -join ", "
                $srcColList = ($quotedCols | ForEach-Object { "src.$_" }) -join ", "
                $mergeCmd = $connection.CreateCommand()
                $mergeCmd.CommandTimeout = $CommandTimeoutSeconds
                $mergeCmd.CommandText = "MERGE dbo.$tableName AS tgt USING dbo.$stagingTable AS src ON $onClause " +
                    "WHEN NOT MATCHED BY TARGET THEN INSERT ($colList) VALUES ($srcColList) " +
                    "WHEN NOT MATCHED BY SOURCE THEN DELETE;"
                $changedRows = $mergeCmd.ExecuteNonQuery()

                $stageCleanupCmd = $connection.CreateCommand()
                $stageCleanupCmd.CommandTimeout = $CommandTimeoutSeconds
                $stageCleanupCmd.CommandText = "DROP TABLE dbo.$stagingTable;"
                $stageCleanupCmd.ExecuteNonQuery() | Out-Null

                Write-Host "[merged] $entity`: $changedRows row(s) added/removed, $($table.Rows.Count) total -> dbo.$tableName"
                $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "merged"; rows = $table.Rows.Count; error = "" })
            }
            else {
                # First-ever upload for this entity, or its CSV's column
                # set changed since the table was created -- no safe way to
                # MERGE across a schema change, so fall back to a full
                # rebuild (the only behavior that existed before this).
                $dropCmd = $connection.CreateCommand()
                $dropCmd.CommandTimeout = $CommandTimeoutSeconds
                $dropCmd.CommandText = "IF OBJECT_ID('dbo.$tableName', 'U') IS NOT NULL DROP TABLE dbo.$tableName;"
                $dropCmd.ExecuteNonQuery() | Out-Null

                $createCmd = $connection.CreateCommand()
                $createCmd.CommandTimeout = $CommandTimeoutSeconds
                $createCmd.CommandText = "CREATE TABLE dbo.$tableName ($columnDefs);"
                $createCmd.ExecuteNonQuery() | Out-Null

                if ($table.Rows.Count -gt 0) {
                    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
                    $bulkCopy.DestinationTableName = "dbo.$tableName"
                    $bulkCopy.BulkCopyTimeout = $CommandTimeoutSeconds
                    foreach ($col in $columns) { $bulkCopy.ColumnMappings.Add($col, $col) | Out-Null }
                    $bulkCopy.WriteToServer($table)
                    $bulkCopy.Close()
                }

                $reason = if ($existingColumns.Count -gt 0) { "schema changed" } else { "first upload" }
                Write-Host "[ok] $entity`: $($table.Rows.Count) rows -> dbo.$tableName (full rebuild, $reason)"
                $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "ok"; rows = $table.Rows.Count; error = "" })
            }

            Save-EntityState -Entity $entity -ContentHash $contentHash -RowCount $table.Rows.Count
        }
        catch {
            # One entity failing (a locked table, a column-count mismatch,
            # a transient timeout) must not abort the rest -- same
            # philosophy as 64_upload_bronze_to_onelake.py's per-entity
            # try/catch.
            Write-Host "[fail] $entity`: $($_.Exception.Message)"
            $results.Add([pscustomobject]@{ entity = $entity; table = $tableName; status = "fail"; rows = 0; error = $_.Exception.Message })
        }
        $completed += 1
    }
}
finally {
    $connection.Close()
}

Write-UploadProgress -CurrentStepName "Done" -Phase "done" -CompletedSteps $totalSteps -TotalSteps $totalSteps

$manifestPath = Join-Path $repoRoot "analysis/warehouse_bronze_upload_manifest.csv"
$results | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

$failedCount = @($results | Where-Object { $_.status -eq "fail" }).Count
Write-Host "Warehouse upload complete: $($results.Count) entities, $failedCount failed. Manifest: $manifestPath"
if ($failedCount -gt 0) { exit 1 }
exit 0
