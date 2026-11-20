#Requires -Version 5.1
<#
    Self-contained test suite. No Pester dependency.

        pwsh ./tests/run-tests.ps1

    Exit code 0 = all assertions passed, 1 = at least one failure.
#>
[CmdletBinding()]
param([switch]$KeepFixture)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here

Import-Module (Join-Path $repo 'DiskAudit.psd1') -Force

# The assertions below check English labels, so pin the language here instead of
# inheriting the OS UI culture (a zh-CN machine would otherwise produce Chinese).
$null = Set-DiskAuditLanguage 'en'

$script:Passed = 0
$script:Failed = 0

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:Passed++
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host ("  [FAIL] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function New-Fixture {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $Path 'sub\deep') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'empty') -Force | Out-Null

    $fs = [System.IO.File]::Create((Join-Path $Path 'base.txt')); $fs.SetLength(1MB); $fs.Close()
    # hard link: same physical file, must be de-duplicated in accurate mode
    New-Item -ItemType HardLink -Path (Join-Path $Path 'link.txt') -Target (Join-Path $Path 'base.txt') | Out-Null
    $fs = [System.IO.File]::Create((Join-Path $Path 'sub\b.bin')); $fs.SetLength(2MB); $fs.Close()
    $fs = [System.IO.File]::Create((Join-Path $Path 'sub\deep\c.dat')); $fs.SetLength(3MB); $fs.Close()

    # junction: must never be followed
    if (Test-Path -LiteralPath (Join-Path $Path 'linkdir')) { Remove-Item -LiteralPath (Join-Path $Path 'linkdir') -Force }
    New-Item -ItemType Junction -Path (Join-Path $Path 'linkdir') -Target (Join-Path $Path 'sub') | Out-Null
}

Write-Host ''
Write-Host '== DiskAudit test suite ==' -ForegroundColor Cyan
Write-Host ("   host: {0}  pwsh: {1}" -f $env:COMPUTERNAME, $PSVersionTable.PSVersion)

$fixture = Join-Path $here 'fixture'
New-Fixture -Path $fixture

try {
    # ---------------------------------------------------------------- volume
    Write-Host ''
    Write-Host 'volume' -ForegroundColor Yellow
    $vol = Get-DiskAuditVolume -Path $fixture
    Assert-That 'volume reports a drive letter' ($vol.drive -match '^[A-Za-z]:$') ("got '" + $vol.drive + "'")
    Assert-That 'used = total - free' (($vol.totalBytes - $vol.freeBytes) -eq $vol.usedBytes)
    Assert-That 'totalBytes is positive' ($vol.totalBytes -gt 0)

    # ------------------------------------------------------------ fast scan
    Write-Host ''
    Write-Host 'scan (logical)' -ForegroundColor Yellow
    $fast = New-DiskAuditSnapshot -Path $fixture -Profile standard
    $fastTotal = ($fast.entries | Measure-Object physicalBytes -Sum).Sum
    Assert-That 'logical total is 7 MB (1 + 1 + 2 + 3)' ($fastTotal -eq (7MB)) ("got " + $fastTotal)
    Assert-That 'entry count is 4 (sub, empty, base.txt, link.txt)' (@($fast.entries).Count -eq 4) ("got " + @($fast.entries).Count)
    Assert-That 'junction is not an entry' (-not (@($fast.entries | Where-Object { $_.name -eq 'linkdir' }).Count -gt 0))
    Assert-That 'scan reports a root' ($fast.scan.root -eq $fixture) ("got " + $fast.scan.root)
    Assert-That 'reconciliation is skipped for a sub-directory root' ($null -eq $fast.reconciliation.residualBytes)
    Assert-That 'reconciliation kind is not-applicable' ($fast.reconciliation.residualKind -eq 'not-applicable')
    Assert-That 'empty directory is listed with zero bytes' (@($fast.entries | Where-Object { $_.name -eq 'empty' -and $_.physicalBytes -eq 0 }).Count -eq 1)

    # --------------------------------------------------------- accurate scan
    Write-Host ''
    Write-Host 'scan (accurate / hard links)' -ForegroundColor Yellow
    $acc = New-DiskAuditSnapshot -Path $fixture -Profile deep -Accurate
    $accTotal = ($acc.entries | Measure-Object physicalBytes -Sum).Sum
    $accShared = ($acc.entries | Measure-Object sharedBytes -Sum).Sum
    $accLogical = ($acc.entries | Measure-Object logicalBytes -Sum).Sum

    if ($acc.scan.accurate) {
        Assert-That 'accurate mode is active' $true
        Assert-That 'physical total is 6 MB (hard link counted once)' ($accTotal -eq (6MB)) ("got " + $accTotal)
        Assert-That 'logical total is 7 MB' ($accLogical -eq (7MB)) ("got " + $accLogical)
        Assert-That 'shared bytes is 1 MB' ($accShared -eq (1MB)) ("got " + $accShared)
    }
    else {
        Write-Host '  [SKIP] accurate mode unavailable on this host (Add-Type blocked)' -ForegroundColor DarkYellow
    }

    # ------------------------------------------------------------- ids / json
    Write-Host ''
    Write-Host 'identity and serialisation' -ForegroundColor Yellow
    $ids = @($fast.entries | ForEach-Object { $_.id })
    Assert-That 'every entry has an id' (@($ids | Where-Object { $_ -match '^p_[0-9a-f]{12}$' }).Count -eq $ids.Count)
    Assert-That 'ids are unique' (@($ids | Select-Object -Unique).Count -eq $ids.Count)

    $out = Join-Path $here '_out'
    if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $snapFile = Join-Path $out 'snapshot-test.json'
    Save-DiskAuditSnapshot -Snapshot $fast -Path $snapFile | Out-Null
    Assert-That 'snapshot file was written' (Test-Path -LiteralPath $snapFile)

    $rawText = [System.IO.File]::ReadAllText($snapFile)
    Assert-That 'generatedAt is stored as an ISO-8601 UTC string' ($rawText -match '"generatedAt":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"')

    $reloaded = Get-Content -LiteralPath $snapFile -Raw | ConvertFrom-Json
    Assert-That 'snapshot kind survives a round trip' ($reloaded.kind -eq 'snapshot')
    # ConvertFrom-Json upgrades ISO strings to [datetime]; the normaliser must undo that
    $normalised = ConvertTo-DiskAuditSnapshot $reloaded
    Assert-That 'normaliser restores a UTC string' ($normalised.generatedAt -is [string] -and $normalised.generatedAt -match 'Z$') ("got " + $normalised.generatedAt)

    # ------------------------------------------------------- schema contract
    # Test-Json only exists in PowerShell 6+; skip silently on 5.1.
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        $schemaPath = Join-Path (Split-Path -Parent $repo) 'schema\snapshot.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath)) { $schemaPath = Join-Path $repo 'schema\snapshot.schema.json' }
        if (Test-Path -LiteralPath $schemaPath) {
            $valid = Test-Json -Json ([System.IO.File]::ReadAllText($snapFile)) -SchemaFile $schemaPath -ErrorAction SilentlyContinue
            Assert-That 'snapshot validates against schema/snapshot.schema.json' ([bool]$valid)
        }
        else {
            Write-Host '  [SKIP] schema file not found' -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Host '  [SKIP] Test-Json is not available in this PowerShell' -ForegroundColor DarkYellow
    }
    # ---------------------------------------------------------------- compare
    Write-Host ''
    Write-Host 'compare' -ForegroundColor Yellow

    # Regression: ConvertFrom-Json turns ISO strings into [datetime] and PowerShell
    # renders them in local culture. A naive parse then shifts the timeline by the
    # UTC offset. Two snapshots taken at the same instant must show elapsedDays = 0.
    $baseSame = $fast | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $reportSame = Compare-DiskAuditSnapshot -Baseline $baseSame -Current $fast
    Assert-That 'elapsedDays is 0 for identical timestamps' ([math]::Abs($reportSame.elapsedDays) -lt 0.01) ("got " + $reportSame.elapsedDays)
    Assert-That 'identical snapshots produce no growth' (@($reportSame.grew).Count -eq 0) ("got " + @($reportSame.grew).Count)
    Assert-That 'verdict is ok when nothing changed' ($reportSame.verdict -eq 'ok') ("got " + $reportSame.verdict)

    $grown = $fast | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $grown.entries[0].physicalBytes = [long]$grown.entries[0].physicalBytes - 2MB
    $grown.entries[0].logicalBytes  = [long]$grown.entries[0].logicalBytes - 2MB
    $reportGrow = Compare-DiskAuditSnapshot -Baseline $grown -Current $fast
    Assert-That 'shrink in baseline shows up as growth' (@($reportGrow.grew).Count -eq 1) ("got " + @($reportGrow.grew).Count)
    Assert-That 'growth delta is 2 MB' (@($reportGrow.grew)[0].deltaBytes -eq (2MB)) ("got " + @($reportGrow.grew)[0].deltaBytes)
    Assert-That 'verdict is ok for a 2 MB change' ($reportGrow.verdict -eq 'ok')

    $alert = $fast | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $alert.volume.freeBytes = [long]$alert.volume.freeBytes + 6GB
    $reportAlert = Compare-DiskAuditSnapshot -Baseline $alert -Current $fast
    Assert-That 'losing 6 GB sets verdict to alert' ($reportAlert.verdict -eq 'alert') ("got " + $reportAlert.verdict)

    $quickSnap = New-DiskAuditSnapshot -Path $fixture -Profile quick
    $reportMixed = Compare-DiskAuditSnapshot -Baseline $quickSnap -Current $fast
    Assert-That 'mixed scan profiles are flagged as not comparable' ($reportMixed.comparable -eq $false) ("comparable=" + $reportMixed.comparable)
    Assert-That 'incomparableReason explains why' ($reportMixed.incomparableReason -match 'profile')
    $textMixed = Format-DiskAuditReport -Report $reportMixed -Style text
    Assert-That 'text report warns about incompatible profiles' ($textMixed -match 'WARNING')
    # ---------------------------------------------------------- localisation
    Write-Host ''
    Write-Host 'localisation' -ForegroundColor Yellow

    $null = Set-DiskAuditLanguage 'zh-CN'
    Assert-That 'language switches to zh-CN' ((Get-DiskAuditLanguage) -eq 'zh-CN') ("got " + (Get-DiskAuditLanguage))
    $zhText = Format-DiskAuditReport -Report $reportGrow -Style text
    Assert-That 'Chinese report contains the verdict label' ($zhText -match '结论')
    Assert-That 'Chinese report still contains the data' ($zhText -match 'sub')

    $null = Set-DiskAuditLanguage 'en'
    Assert-That 'language switches back to en' ((Get-DiskAuditLanguage) -eq 'en') ("got " + (Get-DiskAuditLanguage))
    $enText = Format-DiskAuditReport -Report $reportGrow -Style text
    Assert-That 'English report contains the verdict label' ($enText -match 'Verdict')

    $null = Set-DiskAuditLanguage 'auto'
    Assert-That 'auto resolves to a supported language' (@('en','zh-CN') -contains (Get-DiskAuditLanguage)) ("got " + (Get-DiskAuditLanguage))
    $null = Set-DiskAuditLanguage 'en'   # restore for the rendering assertions below
    # -------------------------------------------------------------- rendering
    Write-Host ''
    Write-Host 'rendering' -ForegroundColor Yellow
    $text = Format-DiskAuditReport -Report $reportGrow -Style text
    Assert-That 'text report mentions the verdict' ($text -match 'Verdict') 
    Assert-That 'text report lists the grown path' ($text -match 'sub')
    $md = Format-DiskAuditReport -Report $reportGrow -Style markdown
    Assert-That 'markdown report has a table row' ($md -match '\| `')
    Assert-That 'formatting helper renders GB' ((Format-DiskAuditSize 5368709120) -match 'GB')
}
finally {
    if (-not $KeepFixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $here '_out') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('== {0} passed, {1} failed ==' -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
exit 0
