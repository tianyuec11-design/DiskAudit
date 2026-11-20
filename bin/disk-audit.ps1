#Requires -Version 5.1
<#
.SYNOPSIS
    Command line entry point for DiskAudit.

.DESCRIPTION
    Takes a snapshot of a volume (or any directory), compares it with the most
    recent stored snapshot, and prints a report. Every run stores a snapshot in
    -SnapshotDir so the next run has a baseline.

.EXAMPLE
    pwsh ./bin/disk-audit.ps1

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Profile quick

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Format json -OutFile report.json -Redact

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Baseline ./snapshots/snapshot-20260101T000000Z.json
#>
[CmdletBinding()]
param(
    [string]$Path = $env:SystemDrive,

    [ValidateSet('quick', 'standard', 'deep')]
    [string]$Profile = 'standard',

    [switch]$Accurate,

    [string]$SnapshotDir,

    [string]$Baseline,

    [switch]$NoCompare,

    [switch]$SaveSnapshot,

    [ValidateSet('text', 'json', 'markdown')]
    [string]$Format = 'text',

    [string]$OutFile,

    [switch]$Redact,

    [long]$WarnMB = 300,

    [int]$MaxSeconds = 0,

    [switch]$Version
)

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$modulePath = Join-Path $root 'DiskAudit.psd1'

if ($Version) {
    Import-Module $modulePath -Force
    Write-Host ("DiskAudit {0}" -f (Get-Module DiskAudit).Version)
    return
}

Import-Module $modulePath -Force

$invokeArgs = @{
    Path      = $Path
    Profile   = $Profile
    Format    = $Format
    WarnBytes = [long]$WarnMB * 1MB
}
if ($Accurate)    { $invokeArgs.Accurate = $true }
if ($NoCompare)   { $invokeArgs.NoCompare = $true }
if ($SaveSnapshot){ $invokeArgs.SaveSnapshot = $true }
if ($OutFile)     { $invokeArgs.OutFile = $OutFile }
if ($Redact)      { $invokeArgs.Redact = $true }
if ($Baseline)    { $invokeArgs.Baseline = $Baseline }
if ($SnapshotDir) { $invokeArgs.SnapshotDir = $SnapshotDir }
if ($MaxSeconds -gt 0) { $invokeArgs.MaxSeconds = $MaxSeconds }

Invoke-DiskAudit @invokeArgs | Out-Null
