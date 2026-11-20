@{
    RootModule        = 'DiskAudit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c1f1a1e7-6a5c-4d3b-9b8e-2f0d7c4a1b55'
    Author            = 'DiskAudit contributors'
    CompanyName       = 'DiskAudit'
    Copyright         = '(c) 2026 DiskAudit contributors. MIT licensed.'
    Description       = 'Snapshot-based, host-agnostic disk space auditing for Windows. Measures real allocated bytes, de-duplicates hard links, reconciles scanned paths against the volume, and emits a stable JSON schema for dashboards.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-DiskAuditVolume'
        'New-DiskAuditSnapshot'
        'Save-DiskAuditSnapshot'
        'ConvertTo-DiskAuditSnapshot'
        'Compare-DiskAuditSnapshot'
        'Format-DiskAuditReport'
        'Format-DiskAuditSize'
        'Invoke-DiskAudit'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('disk', 'storage', 'audit', 'windows', 'snapshot', 'json', 'reporting')
            LicenseUri = 'https://github.com/<tianyuec11-design>/DiskAudit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/<tianyuec11-design>/DiskAudit'
            ReleaseNotes = 'Initial public release: snapshots, comparisons, reconciliation, rule engine, JSON schema.'
        }
    }
}
