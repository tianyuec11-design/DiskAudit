#Requires -Version 5.1
<#
.SYNOPSIS
    Command line entry point for DiskAudit.

.DESCRIPTION
    Takes a snapshot of a volume (or any directory), compares it with the most
    recent stored snapshot, prints a localised report and stores the new
    snapshot so the next run has a baseline.

    The result object is returned to the pipeline when -PassThru is used.

.EXAMPLE
    pwsh ./bin/disk-audit.ps1

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Language zh-CN

.EXAMPLE
    $report = pwsh ./bin/disk-audit.ps1 -Profile quick -PassThru

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Format json -OutFile report.json

.EXAMPLE
    pwsh ./bin/disk-audit.ps1 -Help
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

    [ValidateSet('auto', 'en', 'zh-CN')]
    [string]$Language = 'auto',

    [switch]$PassThru,

    [switch]$Quiet,

    [switch]$Version,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$modulePath = Join-Path $root 'DiskAudit.psd1'

Import-Module $modulePath -Force
$lang = Set-DiskAuditLanguage $Language

function Write-Hint([string]$Text) { Write-Host $Text -ForegroundColor DarkGray }

if ($Version) {
    # Version does not need translating; keep the CLI free of module internals.
    Write-Host ("DiskAudit {0}" -f (Get-Module DiskAudit).Version)
    return
}

if ($Help) {
    if ($lang -eq 'zh-CN') {
        Write-Host ''
        Write-Host 'DiskAudit - 磁盘空间审计' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '用法：'
        Write-Host '  pwsh ./bin/disk-audit.ps1 [参数]'
        Write-Host ''
        Write-Host '常用参数：'
        Write-Host '  -Path <路径>        要审计的卷或目录，默认当前系统盘（如 C:）'
        Write-Host '  -Profile             扫描档位：quick（快）| standard（默认）| deep（精确）'
        Write-Host '  -Accurate            硬链接去重 + 读取实际分配大小（较慢，但最准）'
        Write-Host '  -Language            输出语言：auto（默认，跟随系统）| zh-CN | en'
        Write-Host '  -PassThru            把结果对象返回给管道，便于二次处理'
        Write-Host '  -Format              输出格式：text（默认）| markdown | json'
        Write-Host '  -OutFile <文件>      把结果写成 JSON / Markdown 文件'
        Write-Host '  -SnapshotDir <目录>  快照存放位置，默认 ./snapshots'
        Write-Host '  -Baseline <文件>     指定用于对比的历史快照'
        Write-Host '  -NoCompare           只扫描，不对比'
        Write-Host '  -SaveSnapshot        只保存快照'
        Write-Host '  -Redact              脱敏：隐藏主机名与用户目录后再输出'
        Write-Host '  -MaxSeconds <秒>     扫描时间上限，超时会标记为截断'
        Write-Host '  -Quiet               不打印提示，只输出报告'
        Write-Host ''
        Write-Host '典型流程：'
        Write-Host '  1) 现在先跑一次，建立基线：   pwsh ./bin/disk-audit.ps1'
        Write-Host '  2) 过一段时间再跑一次：        pwsh ./bin/disk-audit.ps1'
        Write-Host '     第二次会告诉你「这期间哪里变大了、每天涨多少」'
        Write-Host ''
        Write-Host '常见组合：'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Profile quick              # 30 秒快速体检'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Profile deep -Accurate     # 精确核对（约 5 分钟）'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Format json -OutFile r.json # 交给程序处理'
        Write-Host '  $r = pwsh ./bin/disk-audit.ps1 -PassThru               # 拿到对象'
        Write-Host ''
    }
    else {
        Write-Host ''
        Write-Host 'DiskAudit - disk space auditing' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:'
        Write-Host '  pwsh ./bin/disk-audit.ps1 [options]'
        Write-Host ''
        Write-Host 'Options:'
        Write-Host '  -Path <path>        Volume or directory to audit, default the system drive'
        Write-Host '  -Profile            quick | standard (default) | deep'
        Write-Host '  -Accurate           Hard-link de-duplication + allocated sizes (slower, exact)'
        Write-Host '  -Language           auto (default, follows the OS) | zh-CN | en'
        Write-Host '  -PassThru           Return the result object to the pipeline'
        Write-Host '  -Format             text (default) | markdown | json'
        Write-Host '  -OutFile <file>     Write the result to a JSON / Markdown file'
        Write-Host '  -SnapshotDir <dir>  Where snapshots are stored, default ./snapshots'
        Write-Host '  -Baseline <file>    Compare against a specific snapshot'
        Write-Host '  -NoCompare          Scan only, do not compare'
        Write-Host '  -SaveSnapshot       Only save the snapshot'
        Write-Host '  -Redact             Mask the host name and the user profile path'
        Write-Host '  -MaxSeconds <n>     Time budget for the scan; a cut scan is marked truncated'
        Write-Host '  -Quiet              Suppress hints, print the report only'
        Write-Host ''
        Write-Host 'Typical flow:'
        Write-Host '  1) record a baseline:  pwsh ./bin/disk-audit.ps1'
        Write-Host '  2) run it again later: pwsh ./bin/disk-audit.ps1'
        Write-Host '     the second run tells you what changed and at what rate'
        Write-Host ''
        Write-Host 'Common combinations:'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Profile quick              # 30 s health check'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Profile deep -Accurate     # exact (about 5 min)'
        Write-Host '  pwsh ./bin/disk-audit.ps1 -Format json -OutFile r.json # machine readable'
        Write-Host '  $r = pwsh ./bin/disk-audit.ps1 -PassThru               # get the object'
        Write-Host ''
    }
    return
}

$invokeArgs = @{
    Path      = $Path
    Profile   = $Profile
    Format    = $Format
    WarnBytes = [long]$WarnMB * 1MB
    Language  = $Language
}
if ($Accurate)     { $invokeArgs.Accurate = $true }
if ($NoCompare)    { $invokeArgs.NoCompare = $true }
if ($SaveSnapshot) { $invokeArgs.SaveSnapshot = $true }
if ($OutFile)      { $invokeArgs.OutFile = $OutFile }
if ($Redact)       { $invokeArgs.Redact = $true }
if ($Baseline)     { $invokeArgs.Baseline = $Baseline }
if ($SnapshotDir)  { $invokeArgs.SnapshotDir = $SnapshotDir }
if ($MaxSeconds -gt 0) { $invokeArgs.MaxSeconds = $MaxSeconds }
if ($PassThru)     { $invokeArgs.PassThru = $true }
if ($Quiet)        { $invokeArgs.Quiet = $true }

# -PassThru: hand the object back to the caller.
# Otherwise let Invoke-DiskAudit write straight to the pipeline so that
# `-Format json` stays pure JSON and nothing is swallowed by an assignment.
if ($PassThru) {
    return (Invoke-DiskAudit @invokeArgs)
}
Invoke-DiskAudit @invokeArgs
