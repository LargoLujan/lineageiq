# Pester tests for backend/scripts/common/LineageCommon.psm1 -- see
# docs/102_admin_panel_and_user_auth.md. Run with:
#   Invoke-Pester tests/powershell/LineageCommon.Tests.ps1

$modulePath = Join-Path $PSScriptRoot "../../backend/scripts/common/LineageCommon.psm1"
Import-Module $modulePath -Force -DisableNameChecking

Describe "Ensure-ParentDirectory" {

    $testRoot = Join-Path $env:TEMP "lineage-common-tests-$([guid]::NewGuid())"

    AfterEach {
        if (Test-Path $testRoot) {
            Remove-Item -Recurse -Force $testRoot
        }
    }

    It "creates a missing nested parent directory" {
        $targetFile = Join-Path $testRoot "a/b/c/file.csv"
        Ensure-ParentDirectory -Path $targetFile
        (Test-Path (Join-Path $testRoot "a/b/c")) | Should Be $true
    }

    It "does not throw when the parent directory already exists" {
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        $targetFile = Join-Path $testRoot "file.csv"
        { Ensure-ParentDirectory -Path $targetFile } | Should Not Throw
    }

    It "does not create anything for a bare filename with no parent segment" {
        { Ensure-ParentDirectory -Path "file.csv" } | Should Not Throw
    }
}

Describe "Write-Log" {

    It "writes an Info-level line without throwing" {
        { Write-Log -Message "hello" } | Should Not Throw
    }

    It "writes a Warn-level line without throwing" {
        { Write-Log -Message "careful" -Level "Warn" } | Should Not Throw
    }

    It "writes an Error-level line without throwing" {
        { Write-Log -Message "broken" -Level "Error" } | Should Not Throw
    }

    It "rejects an unrecognized level" {
        # Pester 3's "Should Throw" does not reliably catch a parameter-
        # binding-time ValidateSet error (a known old-Pester quirk, verified
        # directly with try/catch outside Pester) -- so this asserts the
        # same behavior explicitly instead.
        $threw = $false
        try {
            Write-Log -Message "x" -Level "Critical"
        }
        catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}
