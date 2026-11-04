# Phase 66 - External source connection test: a standalone connectivity
# check (no data extraction) for any external database engine this project
# might need to reach, used by the admin panel's "Probar conexion" button
# for each configured external source. Supports both SQL auth and AAD
# token auth for the SQL Server family; other engines are tested via their
# own native connectivity check where implemented.
param(
    [ValidateSet(
        "sql_server", "azure_sql", "azure_synapse", "postgresql", "mysql", "mariadb",
        "oracle", "ibm_db2", "sap_hana", "teradata", "vertica", "amazon_redshift",
        "snowflake", "google_bigquery", "sqlite",
        "sybase_ase", "informix", "clickhouse", "firebird", "progress_openedge",
        "databricks_sql", "presto_trino", "sharepoint"
    )]
    [string]$EngineType = "sql_server",
    [string]$SourceHost = "",
    [string]$Database = "",
    [string]$ServiceName = "",
    [int]$Port = 0,
    [ValidateSet("sql_auth", "aad_token")]
    [string]$AuthMode = "sql_auth",
    [string]$User = "",
    [string]$PasswordEnvVar = "",
    [string]$FilePath = "",
    [string]$SiteUrl = "",
    [string]$AzCommand = "az",
    [switch]$TrustServerCertificate,
    [int]$ConnectTimeoutSeconds = 15,
    # Permanent (non-user) credential for a write-target Warehouse/Lakehouse:
    # an Entra app registration's own client-credentials grant, so this
    # connection keeps working unattended -- no signed-in user, no `az
    # login` session on this machine -- exactly what a recurring/automated
    # scan needs to write into Fabric on a schedule. See Get-DatabaseAccessToken
    # below for the priority order against the other two token sources.
    [string]$SpTenantId = "",
    [string]$SpClientId = "",
    [string]$SpClientSecretEnvVar = ""
)

# Read-only connectivity check for one row of config/admin_settings.json's
# external_sources list (see the admin panel's "Probar conexion" button and
# docs/102_admin_panel_and_user_auth.md). Covers the ~15 most
# common relational/analytical engines an external source might be, in two
# tiers of honesty rather than pretending every engine is equally supported:
#
#  1. SQL Server family (sql_server/azure_sql/azure_synapse) -- full, proven
#     support via System.Data.SqlClient, same pattern already used in
#     backend/scripts/20_extract_source_object_type_metadata.ps1: SQL-auth via
#     SqlConnectionStringBuilder, or AAD-token via SqlConnection.AccessToken.
#  2. Everything else that speaks a host/port/database/user/password
#     dialect (PostgreSQL, MySQL, MariaDB, Oracle, Db2, SAP HANA, Teradata,
#     Vertica, Redshift) -- attempted via a generic System.Data.Odbc
#     connection using whichever ODBC driver for that engine happens to be
#     registered on this machine. This is best-effort, not guaranteed: some
#     drivers expect different connection-string key names than the common
#     Server/Port/Database/Uid/Pwd shape used here (Oracle's classic ODBC
#     driver in particular often wants a TNS name via "DBQ" instead of a
#     bare host/port). A missing/incompatible driver is reported as a clear,
#     distinct outcome ("no local ODBC driver"), never as a fake success.
#  3. Snowflake, Google BigQuery, SQLite -- no connector is installed in
#     this environment (each needs its own SDK/driver, not a small add-on),
#     so these report "not testable from this server yet" rather than
#     attempting and failing in a confusing way. Their configuration is
#     still saved and ready to use the moment that connector is added here.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-TestResult {
    param([bool]$Ok, [string]$Message)
    [pscustomobject]@{ ok = $Ok; message = $Message } | ConvertTo-Json -Compress
}

function Get-EscapedOdbcValue {
    # Braces are the standard ODBC connection-string escape for a value
    # that might itself contain a delimiter-looking character (';', '=',
    # ...); a literal '}' inside has to be doubled per that same
    # convention. The generic-ODBC branch below builds its connection
    # string by string-joining raw values (Server/Database/ServiceName/
    # Uid/Pwd) with no escaping at all -- these all come from an already-
    # authenticated admin's own saved config (POST /api/admin/external-
    # sources/test), so this is defense-in-depth rather than closing a
    # remotely-exploitable hole, but cheap enough that there's no reason not to.
    param([string]$Value)
    return "{" + $Value.Replace("}", "}}") + "}"
}

function Get-ServicePrincipalAccessToken {
    # A plain OAuth2 client-credentials call against Entra's own v2.0 token
    # endpoint -- no MSAL/Az PowerShell module needed, same "just call the
    # REST API directly" style already used everywhere else in this project.
    # This is what makes a Warehouse write-target connection PERMANENT: it
    # doesn't depend on any person being signed in or on this machine having
    # its own `az login` session, only on the app registration's own secret
    # (which the admin controls the lifetime/rotation of from Entra).
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
        # permanent, the right choice for a write-target that must keep
        # working unattended; (2) a signed-in web-app user's own delegated
        # SQL token, if the process that spawned this script set one (see
        # FABRIC_LINEAGE_USER_SQL_TOKEN in scan_manager.py); (3) the shared
        # `az` CLI session, when run standalone from a terminal, exactly as
        # before per-user auth existed.
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
        throw "Could not acquire an Azure SQL/Fabric database token with '$AzCommand account get-access-token'."
    }
    return [string]$token
}

# Default ports only used when the caller didn't specify one (Port -eq 0).
$DefaultPortByEngine = @{
    sql_server       = 1433
    azure_sql        = 1433
    azure_synapse    = 1433
    postgresql       = 5432
    mysql            = 3306
    mariadb          = 3306
    oracle           = 1521
    ibm_db2          = 50000
    sap_hana         = 30015
    teradata         = 1025
    vertica          = 5433
    amazon_redshift  = 5439
    sybase_ase       = 5000
    informix         = 9088
    clickhouse       = 8123
    firebird         = 3050
    progress_openedge = 5162
    databricks_sql   = 443
    presto_trino     = 8080
}

# Best-effort ODBC driver name per engine -- the exact string installed on
# any given machine varies by vendor/version, so this is a reasonable
# common default, not a guarantee. The error message on failure names the
# driver string that was tried so an admin knows what to check/install.
$OdbcDriverByEngine = @{
    postgresql        = "PostgreSQL Unicode(x64)"
    mysql             = "MySQL ODBC 9.0 Unicode Driver"
    mariadb           = "MariaDB ODBC 3.1 Driver"
    oracle            = "Oracle in OraClient19Home1"
    ibm_db2           = "IBM DB2 ODBC DRIVER"
    sap_hana          = "HDBODBC"
    teradata          = "Teradata Database ODBC Driver"
    vertica           = "Vertica"
    amazon_redshift   = "Amazon Redshift ODBC Driver (x64)"
    sybase_ase        = "Adaptive Server Enterprise"
    informix          = "IBM INFORMIX ODBC DRIVER"
    clickhouse        = "ClickHouse ODBC Driver (Unicode)"
    firebird          = "Firebird/InterBase(r) driver"
    progress_openedge = "Progress OpenEdge 11.7 driver"
    databricks_sql    = "Simba Spark ODBC Driver"
    presto_trino      = "Simba Presto ODBC Driver"
}

$NotYetTestableEngines = @("snowflake", "google_bigquery", "sqlite")

$effectivePort = if ($Port -gt 0) { $Port } elseif ($DefaultPortByEngine.ContainsKey($EngineType)) { $DefaultPortByEngine[$EngineType] } else { 0 }

try {
    if ($EngineType -in @("sql_server", "azure_sql", "azure_synapse")) {
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder["Data Source"] = "tcp:$SourceHost,$effectivePort"
        if ($Database) { $builder["Initial Catalog"] = $Database }
        $builder["Encrypt"] = $true
        $builder["TrustServerCertificate"] = if ($TrustServerCertificate) { "True" } else { "False" }
        $builder["Connect Timeout"] = $ConnectTimeoutSeconds

        $accessToken = $null
        if ($AuthMode -eq "sql_auth") {
            $password = if ($PasswordEnvVar) { [System.Environment]::GetEnvironmentVariable($PasswordEnvVar) } else { $null }
            if (-not $User -or -not $password) {
                Write-TestResult -Ok $false -Message "Missing user or password (check the password_ref environment variable is actually set)."
                exit 0
            }
            $builder["User ID"] = $User
            $builder["Password"] = $password
        }
        else {
            $spClientSecret = if ($SpClientSecretEnvVar) { [System.Environment]::GetEnvironmentVariable($SpClientSecretEnvVar) } else { $null }
            $accessToken = Get-DatabaseAccessToken -AzCommand $AzCommand -SpTenantId $SpTenantId -SpClientId $SpClientId -SpClientSecret $spClientSecret
        }

        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        if ($accessToken) { $connection.AccessToken = $accessToken }
        try {
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandTimeout = $ConnectTimeoutSeconds
            $command.CommandText = "select 1"
            $command.ExecuteScalar() | Out-Null
        }
        finally {
            # Always released, even if Open() succeeded but the query
            # itself threw -- otherwise that connection leaks until GC.
            $connection.Close()
        }

        Write-TestResult -Ok $true -Message "Connected successfully."
        exit 0
    }

    # SharePoint doesn't speak a database wire protocol at all -- it's a
    # Microsoft Graph site lookup, using the exact same "az account
    # get-access-token" pattern this whole project already uses for Fabric
    # (see Get-DatabaseAccessToken above), just against Graph's resource
    # instead of Azure SQL's. A real GET against the site path, not a
    # ping -- confirms both that the token/tenant is right AND that the
    # site itself actually exists and is reachable with it.
    if ($EngineType -eq "sharepoint") {
        if (-not $SiteUrl) {
            Write-TestResult -Ok $false -Message "Falta la URL del sitio de SharePoint."
            exit 0
        }
        $siteUri = [System.Uri]$SiteUrl
        $sitePath = $siteUri.AbsolutePath.Trim('/')
        $graphToken = & $AzCommand account get-access-token --resource "https://graph.microsoft.com" --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $graphToken) {
            Write-TestResult -Ok $false -Message "Could not acquire a Microsoft Graph token with '$AzCommand account get-access-token'."
            exit 0
        }
        $graphUrl = if ($sitePath) {
            "https://graph.microsoft.com/v1.0/sites/$($siteUri.Host):/$sitePath"
        } else {
            "https://graph.microsoft.com/v1.0/sites/$($siteUri.Host)"
        }
        $siteInfo = Invoke-RestMethod -Uri $graphUrl -Headers @{ Authorization = "Bearer $graphToken" } -Method Get -TimeoutSec $ConnectTimeoutSeconds
        Write-TestResult -Ok $true -Message "Connected successfully. Site: $($siteInfo.displayName)."
        exit 0
    }

    if ($EngineType -in $NotYetTestableEngines) {
        Write-TestResult -Ok $false -Message "Probar conexion todavia no esta soportado desde este servidor para $EngineType (necesita su propio conector). La configuracion se guarda igualmente."
        exit 0
    }

    if ($OdbcDriverByEngine.ContainsKey($EngineType)) {
        $password = if ($PasswordEnvVar) { [System.Environment]::GetEnvironmentVariable($PasswordEnvVar) } else { $null }
        if (-not $User -or -not $password) {
            Write-TestResult -Ok $false -Message "Missing user or password (check the password_ref environment variable is actually set)."
            exit 0
        }

        $driverName = $OdbcDriverByEngine[$EngineType]
        $connectionStringParts = @("Driver={$driverName}", "Server=$(Get-EscapedOdbcValue $SourceHost)", "Port=$effectivePort")
        if ($Database) { $connectionStringParts += "Database=$(Get-EscapedOdbcValue $Database)" }
        if ($ServiceName) { $connectionStringParts += "ServiceName=$(Get-EscapedOdbcValue $ServiceName)" }
        $connectionStringParts += "Uid=$(Get-EscapedOdbcValue $User)"
        $connectionStringParts += "Pwd=$(Get-EscapedOdbcValue $password)"
        $connectionString = ($connectionStringParts -join ";") + ";"

        $connection = [System.Data.Odbc.OdbcConnection]::new($connectionString)
        $connection.ConnectionTimeout = $ConnectTimeoutSeconds
        try {
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandTimeout = $ConnectTimeoutSeconds
            $command.CommandText = "select 1"
            $command.ExecuteScalar() | Out-Null
        }
        finally {
            $connection.Close()
        }

        Write-TestResult -Ok $true -Message "Connected successfully via ODBC driver '$driverName'."
        exit 0
    }

    Write-TestResult -Ok $false -Message "Unknown engine type: $EngineType"
}
catch {
    if ($OdbcDriverByEngine.ContainsKey($EngineType) -and $_.Exception.Message -match "data source name not found|driver could not be loaded|no default driver") {
        $driverName = $OdbcDriverByEngine[$EngineType]
        Write-TestResult -Ok $false -Message "No se encontro el driver ODBC '$driverName' en esta maquina. La configuracion se guarda igualmente; instala el driver correspondiente para poder probarla."
    }
    else {
        Write-TestResult -Ok $false -Message $_.Exception.Message
    }
}
