#Requires -Version 5.1
<#
    DiskAudit - snapshot-based, host-agnostic disk space auditing.

    Design notes live in docs/DESIGN.md. The short version:

      * The volume is the only source of truth: used = total - free.
      * Every path measurement is an estimate and is distorted by hard links,
        sparse / cloud placeholder files, reparse points and denied subtrees.
      * Snapshots are compared instead of memorised numbers.
      * Attribution uses non-overlapping top-level entries so deltas never
        double count.
      * Reconciliation (used - attributed) is a first-class metric: a large
        residual means something is growing outside the scanned set.

    All sizes are bytes (Int64), all timestamps are ISO-8601 UTC strings, and
    every object is shaped for direct JSON serialisation so a front-end can
    consume it without post-processing.
#>

$script:ToolName      = 'DiskAudit'
$script:ToolVersion   = '0.2.0'
$script:SchemaVersion = '1.0'

$script:NativeReady   = $false
$script:NativeError   = $null

# ---------------------------------------------------------------------------
# localisation
# ---------------------------------------------------------------------------
# Human-readable text is resolved at run time so the same code can emit
# English or Simplified Chinese. Machine-readable fields (ids, evidence,
# byte counts) never change with the language.

$script:Language = 'en'

function Set-DiskAuditLanguage {
    [CmdletBinding()]
    param([string]$Language = 'auto')

    $lang = $Language
    if ([string]::IsNullOrWhiteSpace($lang) -or $lang -eq 'auto') {
        $ui = [System.Globalization.CultureInfo]::CurrentUICulture.Name
        $lang = if ($ui -like 'zh*') { 'zh-CN' } else { 'en' }
    }
    if ($lang -match '^zh') { $script:Language = 'zh-CN' } else { $script:Language = 'en' }
    return $script:Language
}

function Get-DiskAuditLanguage { return $script:Language }

function M {
    param([Parameter(Mandatory)][string]$Key, [object[]]$FormatArgs)

    $table = $script:Messages[$script:Language]
    if (-not $table) { $table = $script:Messages['en'] }
    $tpl = $table[$Key]
    if (-not $tpl) { $tpl = $script:Messages['en'][$Key] }
    if (-not $tpl) { return $Key }
    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        try { return ($tpl -f $FormatArgs) } catch { return $tpl }
    }
    return $tpl
}

$script:Messages = @{
    en = @{
        # ---- report: text ----
        'report.header'         = ' Disk audit report   {0}'
        'report.subtitle'       = ' profile {0}  |  language {1}'
        'report.baseline'       = ' Baseline : {0}  ({1})'
        'report.current'        = ' Current  : {0}  ({1})'
        'report.elapsed'        = ' Elapsed  : {0:N2} days'
        'report.free'           = ' Free     : {0,10} -> {1,10}   ({2}{3})'
        'report.perday'         = ' Per day  : {0,10}'
        'report.perday_na'      = ' Per day  :        n/a  (interval too short to extrapolate)'
        'report.grew'           = ' -- Grew --------------------------------------------------'
        'report.shrank'         = ' -- Shrank ------------------------------------------------'
        'report.findings'       = ' -- Findings ----------------------------------------------'
        'report.recon'          = ' -- Reconciliation ----------------------------------------'
        'report.attributed'     = '   attributed : {0}'
        'report.volume_used'    = '   volume used: {0}'
        'report.residual'       = '   residual   : {0}  ({1})'
        'report.residual_na'    = '   residual   : n/a  (scan root is not the volume root)'
        'report.verdict'        = ' Verdict: {0}'
        'report.warning'        = ' !! WARNING --------------------------------------------------'
        'report.warning_reason' = '    {0}'
        'report.warning_body1'  = '    Path deltas are suppressed because the two snapshots used'
        'report.warning_body2'  = '    different scan profiles. Free space movement above is still valid.'
        'report.finding_line'   = '   [{0,-4}] {1}'
        'report.finding_detail' = '            {0}'
        'report.finding_at'     = '            at {0}'
        'report.change_row'     = '   {0,10}   {1,10} -> {2,10}   {3}'

        # ---- report: markdown ----
        'md.title'       = '# Disk audit report'
        'md.generated'   = '- Generated: {0}'
        'md.host'        = '- Host: {0}'
        'md.baseline'    = '- Baseline: {0} ({1})'
        'md.current'     = '- Current: {0} ({1})'
        'md.elapsed'     = '- Elapsed: {0:N2} days'
        'md.volume'      = '## Volume'
        'md.metric'      = '| Metric | Value |'
        'md.total'       = '| Total | {0} |'
        'md.free_before' = '| Free before | {0} |'
        'md.free_after'  = '| Free after | {0} |'
        'md.free_delta'  = '| Free delta | {0} |'
        'md.grew'        = '## Grew'
        'md.shrank'      = '## Shrank'
        'md.path'        = '| Path | Before | After | Delta | Per day |'
        'md.path4'       = '| Path | Before | After | Delta |'
        'md.findings'    = '## Findings'
        'md.warning'     = '> **Warning** - {0}'
        'md.warning2'    = '> Path deltas are suppressed because the two snapshots used different scan profiles.'

        # ---- verdict ----
        'verdict.ok'    = 'OK'
        'verdict.watch' = 'WATCH'
        'verdict.alert' = 'ALERT'

        # ---- findings ----
        'f.low_free.title'      = 'Free space is low'
        'f.low_free.detail'     = 'Only {0} ({1:N1}%) of {2} is free.'
        'f.low_free.suggestion' = 'Run a cleanup pass, then re-snapshot to confirm the change.'

        'f.burst.title'         = 'Directory received a large amount of data in the last 24h'
        'f.burst.detail'        = '{0} written in the last 24 hours (now {1}, {2} files). A steady writer like this will fill the volume.'
        'f.burst.suggestion'    = 'Identify the process writing here. If it is a diagnostic trace or log stream, disable or cap it.'

        'f.temp.title'          = 'Temporary directory is large'
        'f.temp.detail'         = '{0} in {1} across {2} files.'
        'f.temp.suggestion'     = 'Temporary data is usually safe to remove, but check for an active writer first.'

        'f.sysfile.title'       = 'System support file'
        'f.sysfile.detail'      = '{0} occupies {1}. It is created by Windows and cannot be deleted while in use.'
        'f.sysfile.suggestion'  = 'Configure through System Properties (virtual memory / hibernation), never by hand.'

        'f.stale.title'         = 'Multiple versions of the same application are present'
        'f.stale.detail'        = '{0} version directories under {1}; the {2} non-current one(s) account for {3} and were last touched {4} days before the newest.'
        'f.stale.sugg_old'      = 'The older build has not been touched in {0} days; an upgrade usually leaves it behind. Remove it after confirming the new build runs.'
        'f.stale.sugg_recent'   = 'The difference is only {0} days old, which is how browsers keep the previous build for rollback. Removing it is optional.'

        'f.updater.title'       = 'Update or installer staging area'
        'f.updater.detail'      = '{0} held in {1}.'
        'f.updater.suggestion'  = 'Usually safe to delete, but the application may download the package again on its next update.'

        'f.logs.title'          = 'Log or trace files dominate this directory'
        'f.logs.detail'         = '{0} of logs/traces out of {1} in {2}.'
        'f.logs.suggestion'     = 'Check whether verbose logging was left enabled by a tool or a driver.'

        'f.placeholder.title'   = 'Sparse or cloud placeholder files detected'
        'f.placeholder.detail'  = '{0} sparse and {1} offline files found. Their logical size overstates real disk usage; Explorer may show them as full.'
        'f.placeholder.sugg'    = 'Trust the volume free space, not the sum of folder sizes, for these locations.'

        'f.recon.title'         = 'Scanned paths do not reconcile with the volume'
        'f.recon.detail'        = '{0} of {1} ({2}). Causes: inaccessible subtrees, shadow copies / restore points, volume metadata, or hard links counted twice.'
        'f.recon.suggestion'    = 'Run with -Accurate for hard-link de-duplication, and check shadow copy storage with an elevated vssadmin query.'
        'f.recon.undercount'    = 'unattributed usage'
        'f.recon.overcount'     = 'over-counted usage'

        'f.incomplete.title'    = 'Some directories could not be read'
        'f.incomplete.detail'   = '{0} directories were denied during the scan; their contents are missing from the totals.'
        'f.incomplete.sugg'     = 'Re-run elevated if you need complete coverage.'

        # ---- cli ----
        'cli.version'      = 'DiskAudit {0}'
        'cli.banner'       = 'DiskAudit {0}   profile={1}   language={2}'
        'cli.scanning'     = 'Scanning {0} ... (profile {1}; the first full scan can take 1-2 minutes)'
        'cli.scanned'      = 'Scan finished: {0} top-level entries, {1} findings, {2:N1}s'
        'cli.saved'        = 'Snapshot saved: {0}'
        'cli.first_run'    = 'This was the first run: a baseline was recorded, so there is nothing to compare yet.'
        'cli.first_run_volume' = '  {0}  {1:N2} GB used / {2:N2} GB total  ({3:N1}% free)'
        'cli.next_run'     = 'Next: run the same command again later (or after the disk shrinks) to see what changed.'
        'cli.hint_json'    = 'Structured output:  .\bin\disk-audit.ps1 -Format json -OutFile report.json'
        'cli.hint_object'  = 'PowerShell object:  $r = .\bin\disk-audit.ps1 -PassThru'
        'cli.hint_lang'    = 'Language:           -Language zh-CN   or   -Language en'
        'cli.no_findings'  = 'No anomalies detected.'
        'cli.written'      = 'Report written: {0}'
        'cli.passthru'     = 'Result object returned to the pipeline (assign it or pipe to Format-List).'
        'cli.usage_title'  = 'Usage'
        'cli.usage_line'   = '  {0}'
    }

    'zh-CN' = @{
        # ---- report: text ----
        'report.header'         = ' 磁盘空间审计报告   {0}'
        'report.subtitle'       = ' 档位 {0}  |  语言 {1}'
        'report.baseline'       = ' 基线快照 : {0}  ({1})'
        'report.current'        = ' 当前快照 : {0}  ({1})'
        'report.elapsed'        = ' 时间间隔 : {0:N2} 天'
        'report.free'           = ' 可用空间 : {0,10} -> {1,10}   ({2}{3})'
        'report.perday'         = ' 每天变化 : {0,10}'
        'report.perday_na'      = ' 每天变化 :       不适用（间隔太短，外推没有意义）'
        'report.grew'           = ' -- 增长的目录 --------------------------------------------'
        'report.shrank'         = ' -- 缩小的目录 --------------------------------------------'
        'report.findings'       = ' -- 发现 --------------------------------------------------'
        'report.recon'          = ' -- 对账 --------------------------------------------------'
        'report.attributed'     = '   已解释 : {0}'
        'report.volume_used'    = '   卷已用 : {0}'
        'report.residual'       = '   未解释 : {0}  ({1})'
        'report.residual_na'    = '   未解释 : 不适用（扫描根目录不是卷根目录）'
        'report.verdict'        = ' 结论：{0}'
        'report.warning'        = ' !! 警告 --------------------------------------------------'
        'report.warning_reason' = '    {0}'
        'report.warning_body1'  = '    两次快照使用的扫描档位不同，因此不列出路径级差异。'
        'report.warning_body2'  = '    上方的可用空间变化仍然有效。'
        'report.finding_line'   = '   [{0,-4}] {1}'
        'report.finding_detail' = '            {0}'
        'report.finding_at'     = '            位置：{0}'
        'report.change_row'     = '   {0,10}   {1,10} -> {2,10}   {3}'

        # ---- report: markdown ----
        'md.title'       = '# 磁盘空间审计报告'
        'md.generated'   = '- 生成时间：{0}'
        'md.host'        = '- 主机：{0}'
        'md.baseline'    = '- 基线快照：{0}（{1}）'
        'md.current'     = '- 当前快照：{0}（{1}）'
        'md.elapsed'     = '- 时间间隔：{0:N2} 天'
        'md.volume'      = '## 卷'
        'md.metric'      = '| 指标 | 数值 |'
        'md.total'       = '| 总容量 | {0} |'
        'md.free_before' = '| 之前可用 | {0} |'
        'md.free_after'  = '| 现在可用 | {0} |'
        'md.free_delta'  = '| 变化 | {0} |'
        'md.grew'        = '## 增长'
        'md.shrank'      = '## 缩小'
        'md.path'        = '| 路径 | 之前 | 现在 | 变化 | 每天 |'
        'md.path4'       = '| 路径 | 之前 | 现在 | 变化 |'
        'md.findings'    = '## 发现'
        'md.warning'     = '> **警告** — {0}'
        'md.warning2'    = '> 两次快照的扫描档位不同，已隐藏路径级差异。'

        # ---- verdict ----
        'verdict.ok'    = '正常'
        'verdict.watch' = '需要关注'
        'verdict.alert' = '告警'

        # ---- findings ----
        'f.low_free.title'      = '可用空间偏低'
        'f.low_free.detail'     = '总共 {2}，只剩 {0}（{1:N1}%）可用。'
        'f.low_free.suggestion' = '清理一轮后重新快照，确认变化。'

        'f.burst.title'         = '有目录在最近 24 小时内写入了大量数据'
        'f.burst.detail'        = '过去 24 小时写入 {0}（当前共 {1}，{2} 个文件）。这种持续写入会很快占满磁盘。'
        'f.burst.suggestion'    = '找到往这里写数据的进程。如果是诊断跟踪或日志流，关掉它或限制大小。'

        'f.temp.title'          = '临时目录体积过大'
        'f.temp.detail'         = '{1} 中占用 {0}，共 {2} 个文件。'
        'f.temp.suggestion'     = '临时数据通常可以安全删除，但请先确认没有程序正在写入。'

        'f.sysfile.title'       = '系统支撑文件'
        'f.sysfile.detail'      = '{0} 占用 {1}，由 Windows 创建，使用中无法删除。'
        'f.sysfile.suggestion'  = '请通过「系统属性」（虚拟内存 / 休眠）调整，不要手工删除。'

        'f.stale.title'         = '同一程序存在多个版本目录'
        'f.stale.detail'        = '{1} 下有 {0} 个版本目录，其中 {2} 个非当前版本共占 {3}，最后一次修改比最新版早 {4} 天。'
        'f.stale.sugg_old'      = '旧版本已经 {0} 天没动过，升级时通常会留下它。确认新版能正常运行后可以删除。'
        'f.stale.sugg_recent'   = '两者只差 {0} 天，这是浏览器保留上一版以便回滚的常见做法，删不删都行。'

        'f.updater.title'       = '更新包 / 安装包暂存目录'
        'f.updater.detail'      = '{1} 中存放了 {0}。'
        'f.updater.suggestion'  = '通常可以删，但程序下次更新时可能重新下载。'

        'f.logs.title'          = '该目录几乎全是日志 / 跟踪文件'
        'f.logs.detail'         = '{2} 共 {1}，其中日志/跟踪占 {0}。'
        'f.logs.suggestion'     = '检查是否有工具或驱动把详细日志一直开着。'

        'f.placeholder.title'   = '检测到稀疏文件 / 云盘占位文件'
        'f.placeholder.detail'  = '发现 {0} 个稀疏文件、{1} 个离线占位文件。它们的逻辑大小远大于真实占用，资源管理器可能显示为"已满"。'
        'f.placeholder.sugg'    = '这些位置请以卷的可用空间为准，不要相信文件夹大小之和。'

        'f.recon.title'         = '扫描结果与卷的实际占用对不上'
        'f.recon.detail'        = '有 {0} 属于{1}（{2}）。常见原因：无权限子目录、卷影副本/还原点、卷元数据，或硬链接被重复计算。'
        'f.recon.suggestion'    = '用 -Accurate 做硬链接去重；还原点需以管理员运行 vssadmin 查看。'
        'f.recon.undercount'    = '未被解释的占用'
        'f.recon.overcount'     = '被高估的占用'

        'f.incomplete.title'    = '部分目录无法读取'
        'f.incomplete.detail'   = '扫描时有 {0} 个目录被拒绝访问，其内容未计入总量。'
        'f.incomplete.sugg'     = '如需完整覆盖，请以管理员身份重新运行。'

        # ---- cli ----
        'cli.version'      = 'DiskAudit {0}'
        'cli.banner'       = 'DiskAudit {0}   档位={1}   语言={2}'
        'cli.scanning'     = '正在扫描 {0} ...（档位 {1}，首次完整扫描约需 1-2 分钟）'
        'cli.scanned'      = '扫描完成：{0} 个顶层条目，{1} 条发现，用时 {2:N1} 秒'
        'cli.saved'        = '快照已保存：{0}'
        'cli.first_run'    = '这是第一次运行，已记录基线，暂时没有可对比的数据。'
        'cli.first_run_volume' = '  {0}  已用 {1:N2} GB / 共 {2:N2} GB（{3:N1}% 可用）'
        'cli.next_run'     = '下一步：过一段时间（或发现磁盘变小）再运行一次同样的命令，就能看到变化。'
        'cli.hint_json'    = '要结构化结果：  .\bin\disk-audit.ps1 -Format json -OutFile report.json'
        'cli.hint_object'  = '要 PowerShell 对象： $r = .\bin\disk-audit.ps1 -PassThru'
        'cli.hint_lang'    = '切换语言：      -Language zh-CN   或   -Language en'
        'cli.no_findings'  = '没有发现异常。'
        'cli.written'      = '报告已写入：{0}'
        'cli.passthru'     = '结果对象已返回（可赋值给变量或接 Format-List）。'
        'cli.usage_title'  = '用法'
        'cli.usage_line'   = '  {0}'
    }
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

function Format-DiskAuditSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Bytes)
    $abs = [math]::Abs($Bytes)
    if ($abs -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($abs -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($abs -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($abs -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function ConvertTo-IsoUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    return [string]$Value
}

# ConvertFrom-Json silently turns ISO-8601 strings into [datetime] and then
# PowerShell re-renders them in local culture. Normalise back to UTC strings so
# comparisons and reports stay timezone independent.
function ConvertTo-DiskAuditSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return $null }
    if ($Snapshot.generatedAt -is [datetime]) { $Snapshot.generatedAt = ConvertTo-IsoUtc $Snapshot.generatedAt }
    foreach ($e in @($Snapshot.entries)) {
        if ($null -ne $e -and $e.newestWriteUtc -is [datetime]) { $e.newestWriteUtc = ConvertTo-IsoUtc $e.newestWriteUtc }
    }
    foreach ($h in @($Snapshot.hotspots)) {
        if ($null -ne $h -and $h.newestWriteUtc -is [datetime]) { $h.newestWriteUtc = ConvertTo-IsoUtc $h.newestWriteUtc }
    }
    return $Snapshot
}

# Stable identifier for a path, safe to use as a key in a dashboard or a diff.
# Derived from the normalised path so it is stable across snapshots as long as
# the path does not change (drive letters are part of the identity by design).
function Get-DiskAuditPathId {
    param([Parameter(Mandatory)][string]$Path)
    $norm = $Path.TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
        return 'p_' + ([System.BitConverter]::ToString($hash, 0, 6) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertTo-DiskAuditUtcDate {    param($Value)
    if ($null -eq $Value) { throw 'Snapshot is missing generatedAt' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Resolve-DiskAuditRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $env:SystemDrive }
    # "C:" means "current directory on C:" to Resolve-Path - return the root explicitly.
    if ($Path -match '^[A-Za-z]:$') { return ($Path.Substring(0, 1).ToUpper() + ':\') }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Path does not exist: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).Path
    if ($full -match '^[A-Za-z]:\\?$') { $full = $full.Substring(0, 2) + '\' }
    return $full
}

function Test-DiskAuditDriveRoot {
    param([string]$Path)
    return ($Path -match '^[A-Za-z]:\\$')
}

# ---------------------------------------------------------------------------
# native interop (optional, used by -Accurate)
# ---------------------------------------------------------------------------

function Initialize-DiskAuditNative {
    if ($script:NativeReady) { return $true }
    if ($script:NativeError) { return $false }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DiskAuditNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(
        IntPtr hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
}
'@
        $script:NativeReady = $true
        return $true
    }
    catch {
        $script:NativeError = $_.Exception.Message
        return $false
    }
}

# Returns "volumeSerial:fileIndex" (the NTFS identity of a physical file) or $null.
function Get-DiskAuditFileIdentity {
    param([string]$Path)
    $h = $null
    try {
        # dwDesiredAccess = 0 (metadata only) so locked files still succeed more often.
        $h = [DiskAuditNative]::CreateFileW($Path, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
        if ($null -eq $h -or $h.IsInvalid) { return $null }
        $info = New-Object DiskAuditNative+BY_HANDLE_FILE_INFORMATION
        if ([DiskAuditNative]::GetFileInformationByHandle($h.DangerousGetHandle(), [ref]$info)) {
            $index = ([uint64]$info.FileIndexHigh -shl 32) -bor [uint64]$info.FileIndexLow
            return ('{0}:{1}' -f $info.VolumeSerialNumber, $index)
        }
        return $null
    }
    catch { return $null }
    finally { if ($null -ne $h) { $h.Dispose() } }
}

# Bytes actually allocated on disk (accounts for sparse / compressed files).
function Get-DiskAuditAllocatedSize {
    param([string]$Path, [long]$Fallback)
    try {
        $high = [uint32]0
        $low = [DiskAuditNative]::GetCompressedFileSizeW($Path, [ref]$high)
        if ($low -eq [uint32]::MaxValue -and $high -eq 0) { return $Fallback }
        return [long](([uint64]$high -shl 32) -bor [uint64]$low)
    }
    catch { return $Fallback }
}

# ---------------------------------------------------------------------------
# volume
# ---------------------------------------------------------------------------

function Get-DiskAuditVolume {
    [CmdletBinding()]
    param([string]$Path = $env:SystemDrive)

    $root = Resolve-DiskAuditRoot $Path
    $driveRoot = [System.IO.Path]::GetPathRoot($root)
    $di = [System.IO.DriveInfo]::new($driveRoot)
    if (-not $di.IsReady) { throw "Volume is not ready: $driveRoot" }

    $total = [long]$di.TotalSize
    $free  = [long]$di.AvailableFreeSpace
    $used  = $total - $free

    [pscustomobject][ordered]@{
        drive      = $di.Name.TrimEnd('\')
        label      = [string]$di.VolumeLabel
        fileSystem = [string]$di.DriveFormat
        totalBytes = $total
        freeBytes  = $free
        usedBytes  = $used
        freePct    = [math]::Round(($free / [double]$total) * 100, 2)
    }
}

# ---------------------------------------------------------------------------
# tree measurement
# ---------------------------------------------------------------------------

# Bytes a single file contributes to the tree, honouring hard-link deduplication.
# Returns physicalBytes (allocated, or 0 when this inode was already counted)
# and sharedBytes (logical size that was suppressed because of a hard link).
function Resolve-DiskAuditFileBytes {
    param(
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][hashtable]$Context,
        [long]$Length
    )
    if (-not $Context.Accurate) {
        return [pscustomobject]@{ physical = $Length; shared = [long]0 }
    }
    $alloc = Get-DiskAuditAllocatedSize -Path $FullName -Fallback $Length
    $id = Get-DiskAuditFileIdentity -Path $FullName
    if ($null -ne $id) {
        if ($Context.Seen.ContainsKey($id)) {
            return [pscustomobject]@{ physical = [long]0; shared = $Length }
        }
        $Context.Seen[$id] = $true
    }
    return [pscustomobject]@{ physical = $alloc; shared = [long]0 }
}

function Measure-DiskAuditNode {
    param(
        [Parameter(Mandatory)][System.IO.DirectoryInfo]$Directory,
        [int]$Depth,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $res = [pscustomobject]@{
        logicalBytes  = [long]0
        physicalBytes = [long]0
        sharedBytes   = [long]0
        fileCount     = 0
        dirCount      = 0
        errorCount    = 0
        sparseFiles   = 0
        offlineFiles  = 0
        reparseSkipped = 0
        newestUtc     = [datetime]::MinValue
        hasNewest     = $false
        bytes24h      = [long]0
        bytes7d       = [long]0
        logBytes      = [long]0
        tmpBytes      = [long]0
        installerBytes = [long]0
        depthLimited  = 0
    }

    $children = $null
    try { $children = @($Directory.EnumerateFileSystemInfos()) }
    catch { $res.errorCount++; return $res }

    $n = 0
    foreach ($entry in $children) {
        $n++
        if (($n % 512) -eq 0) {
            if ($Context.Deadline -and [datetime]::UtcNow -gt $Context.Deadline) { $Context.Truncated = $true }
            if ($Context.Truncated) { break }
        }

        if ($entry -is [System.IO.DirectoryInfo]) {
            $name = $entry.Name
            if ($Context.SkipSet.ContainsKey($name)) { continue }
            if ((-not $Context.FollowReparse) -and (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                $res.reparseSkipped++
                continue
            }
            $res.dirCount++
            if ($Context.MaxDepth -gt 0 -and ($Depth + 1) -gt $Context.MaxDepth) {
                $res.depthLimited++
                continue
            }
            $sub = Measure-DiskAuditNode -Directory $entry -Depth ($Depth + 1) -Context $Context
            $res.logicalBytes   += $sub.logicalBytes
            $res.physicalBytes  += $sub.physicalBytes
            $res.sharedBytes    += $sub.sharedBytes
            $res.fileCount      += $sub.fileCount
            $res.dirCount       += $sub.dirCount
            $res.errorCount     += $sub.errorCount
            $res.sparseFiles    += $sub.sparseFiles
            $res.offlineFiles   += $sub.offlineFiles
            $res.reparseSkipped += $sub.reparseSkipped
            $res.bytes24h       += $sub.bytes24h
            $res.bytes7d        += $sub.bytes7d
            $res.logBytes       += $sub.logBytes
            $res.tmpBytes       += $sub.tmpBytes
            $res.installerBytes += $sub.installerBytes
            if ($sub.hasNewest -and ($res.hasNewest -eq $false -or $sub.newestUtc -gt $res.newestUtc)) {
                $res.newestUtc = $sub.newestUtc
                $res.hasNewest = $true
            }
            continue
        }

        # regular file
        $len = [long]$entry.Length
        $res.fileCount++
        $res.logicalBytes += $len

        $attr = $entry.Attributes
        if (($attr -band [System.IO.FileAttributes]::SparseFile) -ne 0) { $res.sparseFiles++ }
        if (($attr -band [System.IO.FileAttributes]::Offline) -ne 0)    { $res.offlineFiles++ }

        if ($Context.Accurate) {
            $fb = Resolve-DiskAuditFileBytes -FullName $entry.FullName -Context $Context -Length $len
            $res.physicalBytes += $fb.physical
            $res.sharedBytes   += $fb.shared
        }
        else {
            $res.physicalBytes += $len
        }

        $writeUtc = $entry.LastWriteTimeUtc
        if (-not $res.hasNewest -or $writeUtc -gt $res.newestUtc) {
            $res.newestUtc = $writeUtc
            $res.hasNewest = $true
        }

        $ageHours = ($Context.Now - $writeUtc).TotalHours
        if ($ageHours -le 24)  { $res.bytes24h += $len }
        if ($ageHours -le 168) { $res.bytes7d  += $len }

        $ext = $entry.Extension
        if ($ext) {
            switch ($ext.ToLowerInvariant()) {
                '.log'  { $res.logBytes += $len }
                '.etl'  { $res.logBytes += $len }
                '.evtx' { $res.logBytes += $len }
                '.dmp'  { $res.logBytes += $len }
                '.tmp'  { $res.tmpBytes += $len }
                '.temp' { $res.tmpBytes += $len }
                '.msi'  { $res.installerBytes += $len }
                '.msp'  { $res.installerBytes += $len }
            }
        }
    }

    # Depth-1 nodes are already reported as entries; hotspots start one level down.
    if ($Depth -ge 2 -and $Depth -le $Context.HotspotDepth -and $res.physicalBytes -gt 0) {
        $parentPath = $null
        if ($null -ne $Directory.Parent) { $parentPath = $Directory.Parent.FullName }
        $Context.Nodes.Add([pscustomobject]@{
            id             = (Get-DiskAuditPathId $Directory.FullName)
            path           = $Directory.FullName
            name           = $Directory.Name
            parentPath     = $parentPath
            depth          = $Depth
            logicalBytes   = $res.logicalBytes
            physicalBytes  = $res.physicalBytes
            sharedBytes    = $res.sharedBytes
            fileCount      = $res.fileCount
            dirCount       = $res.dirCount
            errorCount     = $res.errorCount
            sparseFiles    = $res.sparseFiles
            offlineFiles   = $res.offlineFiles
            newestWriteUtc = $(if ($res.hasNewest) { ConvertTo-IsoUtc $res.newestUtc } else { $null })
            bytesLast24h   = $res.bytes24h
            bytesLast7d    = $res.bytes7d
            logBytes       = $res.logBytes
            tmpBytes       = $res.tmpBytes
            installerBytes = $res.installerBytes
        })
    }

    return $res
}

# ---------------------------------------------------------------------------
# rules / findings
# ---------------------------------------------------------------------------

function New-DiskAuditFinding {
    param(
        [string]$Id,
        [string]$Severity,
        [string]$Title,
        [string]$Detail,
        [string]$Path,
        [long]$ReclaimableBytes = 0,
        [hashtable]$Evidence = @{},
        [string]$Suggestion = ''
    )
    [pscustomobject][ordered]@{
        id               = $Id
        severity         = $Severity      # info | warn | high
        title            = $Title
        detail           = $Detail
        path             = $Path
        reclaimableBytes = $ReclaimableBytes
        evidence         = $Evidence
        suggestion       = $Suggestion
    }
}

function Get-DiskAuditFindings {
    param([Parameter(Mandatory)]$Snapshot)

    $out     = New-Object System.Collections.Generic.List[object]
    $vol     = $Snapshot.volume
    $total   = [double]$vol.totalBytes
    $used    = [double]$vol.usedBytes
    $free    = [double]$vol.freeBytes
    $hot     = @($Snapshot.hotspots)
    $entries = @($Snapshot.entries)

    # --- V1 free space pressure -------------------------------------------
    if ($free -lt ($total * 0.10) -or $free -lt 10GB) {
        $sev = if ($free -lt ($total * 0.05)) { 'high' } else { 'warn' }
        $out.Add((New-DiskAuditFinding -Id 'VOLUME_LOW_FREE' -Severity $sev `
            -Title (M 'f.low_free.title') `
            -Detail (M 'f.low_free.detail' @((Format-DiskAuditSize $free), $vol.freePct, (Format-DiskAuditSize $total))) `
            -Path $Snapshot.scan.root `
            -Evidence @{ freeBytes = [long]$free; totalBytes = [long]$total; freePct = $vol.freePct } `
            -Suggestion (M 'f.low_free.suggestion')))
    }

    # --- V2 recent write burst --------------------------------------------
    # A node's counter includes its descendants, so only the most specific node
    # is reported; ancestors would otherwise repeat the same finding.
    $burstThreshold = [math]::Max(2GB, [long]($total * 0.01))
    $highThreshold  = [math]::Max(10GB, [long]($total * 0.03))
    $burstCandidates = @($hot | Where-Object { $_.bytesLast24h -ge $burstThreshold })
    $burstKeep = New-Object System.Collections.Generic.List[object]
    foreach ($c in ($burstCandidates | Sort-Object { $_.path.Length } -Descending)) {
        $hasKeptDescendant = $false
        foreach ($k in $burstKeep) {
            if ($k.path.StartsWith($c.path + '\', [StringComparison]::OrdinalIgnoreCase)) { $hasKeptDescendant = $true; break }
        }
        if (-not $hasKeptDescendant) { $burstKeep.Add($c) }
    }
    foreach ($node in ($burstKeep | Sort-Object bytesLast24h -Descending)) {
        $perDay = [long]$node.bytesLast24h
        $sev = if ($perDay -ge $highThreshold) { 'high' } else { 'warn' }
        $out.Add((New-DiskAuditFinding -Id 'RECENT_WRITE_BURST' -Severity $sev `
            -Title (M 'f.burst.title') `
            -Detail (M 'f.burst.detail' @((Format-DiskAuditSize $perDay), (Format-DiskAuditSize $node.physicalBytes), $node.fileCount)) `
            -Path $node.path `
            -ReclaimableBytes ([long]$node.physicalBytes) `
            -Evidence @{ bytesLast24h = [long]$node.bytesLast24h; bytesLast7d = [long]$node.bytesLast7d; fileCount = $node.fileCount } `
            -Suggestion (M 'f.burst.suggestion')))
    }

    # --- V3 temp bloat ------------------------------------------------------
    $tempPaths = @()
    if ($env:TEMP)        { $tempPaths += $env:TEMP }
    if ($env:SystemDrive) { $tempPaths += (Join-Path $env:SystemDrive 'Windows\Temp') }
    foreach ($tp in ($tempPaths | Select-Object -Unique)) {
        $node = $hot | Where-Object { $_.path -eq $tp } | Select-Object -First 1
        if (-not $node) { continue }
        if ($node.physicalBytes -ge 2GB -or $node.physicalBytes -ge ($total * 0.01)) {
            $out.Add((New-DiskAuditFinding -Id 'TEMP_BLOAT' -Severity 'warn' `
                -Title (M 'f.temp.title') `
                -Detail (M 'f.temp.detail' @((Format-DiskAuditSize $node.physicalBytes), $node.path, $node.fileCount)) `
                -Path $node.path -ReclaimableBytes ([long]$node.physicalBytes) `
                -Evidence @{ fileCount = $node.fileCount; bytesLast24h = [long]$node.bytesLast24h } `
                -Suggestion (M 'f.temp.suggestion')))
        }
    }

    # --- V4 system support files -------------------------------------------
    foreach ($e in ($entries | Where-Object { $_.kind -eq 'file' })) {
        if ($e.path -match '(?i)\\(pagefile\.sys|hiberfil\.sys|swapfile\.sys)$') {
            $out.Add((New-DiskAuditFinding -Id 'SYSTEM_SUPPORT_FILE' -Severity 'info' `
                -Title (M 'f.sysfile.title') `
                -Detail (M 'f.sysfile.detail' @((Split-Path -Leaf $e.path), (Format-DiskAuditSize $e.physicalBytes))) `
                -Path $e.path `
                -Evidence @{ file = (Split-Path -Leaf $e.path); bytes = [long]$e.physicalBytes } `
                -Suggestion (M 'f.sysfile.suggestion')))
        }
    }

    # --- V5 duplicate application versions ---------------------------------
    $semver = '^\d+(\.\d+){1,3}$'
    $byParent = $hot | Where-Object { $_.name -match $semver } | Group-Object parentPath
    foreach ($g in $byParent) {
        if ($g.Count -lt 2) { continue }
        $versions = @($g.Group | Sort-Object { [version]($_.name -replace '[^0-9.]', '') } -Descending)
        $newest = $versions[0]
        $stale  = @($versions | Select-Object -Skip 1)
        if ($stale.Count -eq 0) { continue }
        $bytes = ($stale | Measure-Object physicalBytes -Sum).Sum
        if ($bytes -lt 100MB) { continue }

        $newestWrite = $null
        if ($newest.newestWriteUtc) { $newestWrite = ConvertTo-DiskAuditUtcDate $newest.newestWriteUtc }
        $oldestWrite = $null
        foreach ($st in $stale) {
            if (-not $st.newestWriteUtc) { continue }
            $d = ConvertTo-DiskAuditUtcDate $st.newestWriteUtc
            if ($null -eq $oldestWrite -or $d -lt $oldestWrite) { $oldestWrite = $d }
        }
        $ageDays = 0
        if ($null -ne $newestWrite -and $null -ne $oldestWrite) {
            $ageDays = [int][math]::Round(($newestWrite - $oldestWrite).TotalDays)
        }
        $sev  = if ($ageDays -ge 45) { 'warn' } else { 'info' }
        $hint = if ($ageDays -ge 45) { M 'f.stale.sugg_old' @($ageDays) } else { M 'f.stale.sugg_recent' @($ageDays) }

        $out.Add((New-DiskAuditFinding -Id 'STALE_VERSION_DIRS' -Severity $sev `
            -Title (M 'f.stale.title') `
            -Detail (M 'f.stale.detail' @($versions.Count, $g.Name, $stale.Count, (Format-DiskAuditSize $bytes), $ageDays)) `
            -Path $g.Name -ReclaimableBytes ([long]$bytes) `
            -Evidence @{ versions = @($versions | ForEach-Object { $_.name }); staleBytes = [long]$bytes; ageGapDays = $ageDays } `
            -Suggestion $hint))
    }

    # --- V6 updater / installer staging ------------------------------------
    $updaterPattern = '(?i)(update|updater|pending|patch|hotfix|download|installer)'
    foreach ($node in ($hot | Where-Object { $_.name -match $updaterPattern -and $_.physicalBytes -ge 200MB } | Sort-Object physicalBytes -Descending)) {
        $out.Add((New-DiskAuditFinding -Id 'UPDATER_STAGING' -Severity 'info' `
            -Title (M 'f.updater.title') `
            -Detail (M 'f.updater.detail' @((Format-DiskAuditSize $node.physicalBytes), $node.path)) `
            -Path $node.path -ReclaimableBytes ([long]$node.physicalBytes) `
            -Evidence @{ fileCount = $node.fileCount; installerBytes = [long]$node.installerBytes } `
            -Suggestion (M 'f.updater.suggestion')))
    }

    # --- V7 log / trace accumulation ---------------------------------------
    $logCandidates = $hot | Where-Object { $_.logBytes -ge 500MB -and $_.logBytes -ge ([long]$_.physicalBytes * 0.5) }
    foreach ($node in ($logCandidates | Sort-Object logBytes -Descending)) {
        $out.Add((New-DiskAuditFinding -Id 'LOG_ACCUMULATION' -Severity 'warn' `
            -Title (M 'f.logs.title') `
            -Detail (M 'f.logs.detail' @((Format-DiskAuditSize $node.logBytes), (Format-DiskAuditSize $node.physicalBytes), $node.path)) `
            -Path $node.path -ReclaimableBytes ([long]$node.logBytes) `
            -Evidence @{ logBytes = [long]$node.logBytes; fileCount = $node.fileCount } `
            -Suggestion (M 'f.logs.suggestion')))
    }

    # --- V8 cloud placeholders / sparse files ------------------------------
    $sparse  = ($hot | Measure-Object sparseFiles -Sum).Sum
    $offline = ($hot | Measure-Object offlineFiles -Sum).Sum
    if ($sparse -gt 0 -or $offline -gt 0) {
        $out.Add((New-DiskAuditFinding -Id 'PLACEHOLDER_FILES' -Severity 'info' `
            -Title (M 'f.placeholder.title') `
            -Detail (M 'f.placeholder.detail' @($sparse, $offline)) `
            -Path $null `
            -Evidence @{ sparseFiles = [int]$sparse; offlineFiles = [int]$offline } `
            -Suggestion (M 'f.placeholder.sugg')))
    }

    # --- V9 reconciliation gap ---------------------------------------------
    $rec = $Snapshot.reconciliation
    if ($null -ne $rec -and $null -ne $rec.residualBytes) {
        $gap = [math]::Abs([double]$rec.residualBytes)
        if ($gap -ge ($total * 0.02) -and $gap -ge 1GB) {
            $dir = if ($rec.residualBytes -gt 0) { M 'f.recon.undercount' } else { M 'f.recon.overcount' }
            $out.Add((New-DiskAuditFinding -Id 'RECONCILIATION_GAP' -Severity 'warn' `
                -Title (M 'f.recon.title') `
                -Detail (M 'f.recon.detail' @((Format-DiskAuditSize $gap), $dir, $rec.residualKind)) `
                -Path $Snapshot.scan.root `
                -Evidence @{ residualBytes = [long]$rec.residualBytes; attributedBytes = [long]$rec.attributedBytes; accurate = $rec.accurate } `
                -Suggestion (M 'f.recon.suggestion')))
        }
    }

    # --- V10 scan incompleteness -------------------------------------------
    $errs = ($entries | Measure-Object errorCount -Sum).Sum
    if ($errs -gt 0) {
        $out.Add((New-DiskAuditFinding -Id 'SCAN_INCOMPLETE' -Severity 'info' `
            -Title (M 'f.incomplete.title') `
            -Detail (M 'f.incomplete.detail' @($errs)) `
            -Path $null `
            -Evidence @{ deniedDirectories = [int]$errs } `
            -Suggestion (M 'f.incomplete.sugg')))
    }

    return @($out | Sort-Object @{ Expression = { switch ($_.severity) { 'high' { 0 } 'warn' { 1 } default { 2 } } } }, id)
}


# ---------------------------------------------------------------------------
# snapshot
# ---------------------------------------------------------------------------

function New-DiskAuditSnapshot {
    [CmdletBinding()]
    param(
        [string]$Path = $env:SystemDrive,
        [ValidateSet('quick', 'standard', 'deep')][string]$Profile = 'standard',
        [switch]$Accurate,
        [string[]]$Exclude = @(),
        [int]$MaxDepth = 0,
        [int]$HotspotDepth = 4,
        [int]$MaxSeconds = 0,
        [switch]$FollowReparse,
        [switch]$Redact,
                [string]$OutFile,
        [ValidateSet('auto','en','zh-CN')][string]$Language = 'auto'
    )

    # Only switch when the caller asked explicitly; otherwise keep the current
    # language (Invoke-DiskAudit sets it once for the whole run).
    if ($PSBoundParameters.ContainsKey('Language')) { [void](Set-DiskAuditLanguage $Language) }
    $root = Resolve-DiskAuditRoot $Path
    $volume = Get-DiskAuditVolume -Path $root

    # profile defaults
    # PowerShell hashtables are case-insensitive by default, which matches NTFS semantics
    $skipNames = @{}
    $skipNames['System Volume Information'] = $true
    $useAccurate = $Accurate.IsPresent

    switch ($Profile) {
        'quick' {
            if ($MaxDepth -le 0) { $MaxDepth = 4 }
            foreach ($n in 'WinSxS', 'DriverStore', 'WindowsApps', 'System32', 'Installer', 'SoftwareDistribution') { $skipNames[$n] = $true }
        }
        'standard' {
            # full tree, hard links not de-duplicated
        }
        'deep' {
            $useAccurate = $true
        }
    }
    foreach ($n in $Exclude) { if ($n) { $skipNames[$n] = $true } }

    if ($useAccurate -and -not (Initialize-DiskAuditNative)) {
        Write-Warning ("Accurate mode unavailable (Add-Type failed: {0}). Falling back to logical sizes." -f $script:NativeError)
        $useAccurate = $false
    }

    $deadline = $null
    if ($MaxSeconds -gt 0) { $deadline = [datetime]::UtcNow.AddSeconds($MaxSeconds) }

    $ctx = @{
        Seen          = @{}
        Accurate      = [bool]$useAccurate
        Now           = [datetime]::UtcNow
        HotspotDepth  = $HotspotDepth
        MaxDepth      = $MaxDepth
        SkipSet       = $skipNames
        FollowReparse = [bool]$FollowReparse.IsPresent
        Deadline      = $deadline
        Truncated     = $false
        Nodes         = (New-Object System.Collections.Generic.List[object])
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "Scanning $root (profile=$Profile, accurate=$useAccurate)"

    $entries = New-Object System.Collections.Generic.List[object]
    $dirs = $null
    try { $dirs = @(([System.IO.DirectoryInfo]::new($root)).EnumerateDirectories()) } catch { $dirs = @() }
    $files = $null
    try { $files = @(([System.IO.DirectoryInfo]::new($root)).EnumerateFiles()) } catch { $files = @() }

    foreach ($d in $dirs) {
        if ($skipNames.ContainsKey($d.Name)) { continue }
        if ((-not $FollowReparse.IsPresent) -and (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
        $r = Measure-DiskAuditNode -Directory $d -Depth 1 -Context $ctx
        $entries.Add([pscustomobject][ordered]@{
            kind           = 'dir'
            systemFile     = $false
            id             = (Get-DiskAuditPathId $d.FullName)
            path           = $d.FullName
            name           = $d.Name
            depth          = 1
            logicalBytes   = $r.logicalBytes
            physicalBytes  = $r.physicalBytes
            sharedBytes    = $r.sharedBytes
            fileCount      = $r.fileCount
            dirCount       = $r.dirCount
            errorCount     = $r.errorCount
            sparseFiles    = $r.sparseFiles
            offlineFiles   = $r.offlineFiles
            reparseSkipped = $r.reparseSkipped
            newestWriteUtc = $(if ($r.hasNewest) { ConvertTo-IsoUtc $r.newestUtc } else { $null })
            bytesLast24h   = $r.bytes24h
            bytesLast7d    = $r.bytes7d
            logBytes       = $r.logBytes
            tmpBytes       = $r.tmpBytes
            installerBytes = $r.installerBytes
        })
    }

    foreach ($f in $files) {
        $len = [long]$f.Length
        $attr = $f.Attributes
        # pagefile / hiberfil / swapfile are re-written by the OS on every boot;
        # their timestamps say nothing about user data growth.
        $isSystem = ($f.Name -match '^(pagefile|hiberfil|swapfile)\.sys$')
        $fb = Resolve-DiskAuditFileBytes -FullName $f.FullName -Context $ctx -Length $len
        $entries.Add([pscustomobject][ordered]@{
            kind           = 'file'
            systemFile     = $isSystem
            id             = (Get-DiskAuditPathId $f.FullName)
            path           = $f.FullName
            name           = $f.Name
            depth          = 1
            logicalBytes   = $len
            physicalBytes  = $fb.physical
            sharedBytes    = $fb.shared
            fileCount      = 1
            dirCount       = 0
            errorCount     = 0
            sparseFiles    = $(if (($attr -band [System.IO.FileAttributes]::SparseFile) -ne 0) { 1 } else { 0 })
            offlineFiles   = $(if (($attr -band [System.IO.FileAttributes]::Offline) -ne 0) { 1 } else { 0 })
            reparseSkipped = 0
            newestWriteUtc = ConvertTo-IsoUtc $f.LastWriteTimeUtc
            bytesLast24h   = $(if ((-not $isSystem) -and ([datetime]::UtcNow - $f.LastWriteTimeUtc).TotalHours -le 24) { $len } else { 0 })
            bytesLast7d    = $(if ((-not $isSystem) -and ([datetime]::UtcNow - $f.LastWriteTimeUtc).TotalHours -le 168) { $len } else { 0 })
            logBytes       = [long]0
            tmpBytes       = [long]0
            installerBytes = [long]0
        })
    }

    $sw.Stop()

    $entriesArr = @($entries | Sort-Object physicalBytes -Descending)
    $hotspots   = @($ctx.Nodes | Sort-Object physicalBytes -Descending | Select-Object -First 120)

    # reconciliation: only depth-1 entries count, they never overlap.
    # It is only meaningful when the scan root *is* the volume root.
    $isVolumeRoot = Test-DiskAuditDriveRoot $root
    $attributed = ([long]0)
    foreach ($e in $entriesArr) { $attributed += [long]$e.physicalBytes }
    if ($isVolumeRoot) {
        $residual = [long]$volume.usedBytes - $attributed
        $residualKind = if ($residual -ge 0) { 'undercount' } else { 'overcount' }
        $reconciliation = [pscustomobject][ordered]@{
            usedBytes       = [long]$volume.usedBytes
            attributedBytes = $attributed
            residualBytes   = $residual
            residualKind    = $residualKind
            accurate        = [bool]$useAccurate
            method          = 'sum of non-overlapping depth-1 entries'
        }
    }
    else {
        $reconciliation = [pscustomobject][ordered]@{
            usedBytes       = [long]$volume.usedBytes
            attributedBytes = $attributed
            residualBytes   = $null
            residualKind    = 'not-applicable'
            accurate        = [bool]$useAccurate
            method          = 'skipped: scan root is not the volume root'
        }
    }

    $hostInfo = [pscustomobject][ordered]@{
        name        = $(if ($Redact) { '<HOST>' } else { $env:COMPUTERNAME })
        user        = $(if ($Redact) { '<USER>' } else { $env:USERNAME })
        os          = [System.Environment]::OSVersion.VersionString
        psVersion   = $PSVersionTable.PSVersion.ToString()
        isElevated  = $(try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false })
    }

    $skipped = @($skipNames.Keys)
    if ($Redact) {
        $root = $root.Replace($env:USERPROFILE, '<USERPROFILE>')
        foreach ($e in $entriesArr) {
            $e.path = $e.path.Replace($env:USERPROFILE, '<USERPROFILE>')
        }
        foreach ($h in $hotspots) {
            $h.path = $h.path.Replace($env:USERPROFILE, '<USERPROFILE>')
            if ($h.parentPath) { $h.parentPath = $h.parentPath.Replace($env:USERPROFILE, '<USERPROFILE>') }
        }
    }

    $snapshot = [pscustomobject][ordered]@{
        schemaVersion = $script:SchemaVersion
        kind          = 'snapshot'
        generatedAt   = ConvertTo-IsoUtc (Get-Date)
        tool          = [pscustomobject][ordered]@{ name = $script:ToolName; version = $script:ToolVersion }
        host          = $hostInfo
        scan          = [pscustomobject][ordered]@{
            root             = $root
            profile          = $Profile
            accurate         = [bool]$useAccurate
            followReparse    = [bool]$FollowReparse.IsPresent
            maxDepth         = $MaxDepth
            hotspotDepth     = $HotspotDepth
            durationMs       = $sw.ElapsedMilliseconds
            truncated        = [bool]$ctx.Truncated
            skippedNames     = $skipped
            entryCount       = $entriesArr.Count
            hotspotCount     = $hotspots.Count
        }
        volume        = $volume
        entries       = $entriesArr
        hotspots      = $hotspots
        reconciliation = $reconciliation
        findings      = @()
    }

    $snapshot.findings = @(Get-DiskAuditFindings -Snapshot $snapshot)

    if ($OutFile) {
        Save-DiskAuditSnapshot -Snapshot $snapshot -Path $OutFile | Out-Null
    }
    return $snapshot
}

function Save-DiskAuditSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Snapshot | ConvertTo-Json -Depth 12
    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

# ---------------------------------------------------------------------------
# compare
# ---------------------------------------------------------------------------

function Compare-DiskAuditSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Baseline,
        [Parameter(Mandatory)]$Current,
        [long]$WarnBytes = 300MB,
                [int]$Top = 15,
        [ValidateSet('auto','en','zh-CN')][string]$Language = 'auto'
    )

    if ($PSBoundParameters.ContainsKey('Language')) { [void](Set-DiskAuditLanguage $Language) }
    $Baseline = ConvertTo-DiskAuditSnapshot $Baseline
    $Current  = ConvertTo-DiskAuditSnapshot $Current
    $baseTime = ConvertTo-DiskAuditUtcDate $Baseline.generatedAt
    $currTime = ConvertTo-DiskAuditUtcDate $Current.generatedAt
    $elapsedDays = [math]::Max((($currTime - $baseTime).TotalDays), 1.0 / 1440.0)
    # Extrapolating a 5 MB change over 72 seconds produces a meaningless "GB/day".
    $rateMeaningful = ($elapsedDays -ge 0.05)   # 0.05 d = 72 minutes

    # A quick scan never sees the same bytes as a standard scan, so their path
    # deltas are meaningless. Free-space movement is still valid.
    $comparable = ([string]$Baseline.scan.profile -eq [string]$Current.scan.profile) -and
                  ([bool]$Baseline.scan.accurate -eq [bool]$Current.scan.accurate)
    $incomparableReason = $null
    if (-not $comparable) {
        $incomparableReason = "baseline profile '{0}' (accurate={1}) vs current '{2}' (accurate={3})" -f `
            $Baseline.scan.profile, $Baseline.scan.accurate, $Current.scan.profile, $Current.scan.accurate
    }

    $baseMap = @{}
    foreach ($e in @($Baseline.entries)) { $baseMap[$e.path.ToLowerInvariant()] = $e }
    $currMap = @{}
    foreach ($e in @($Current.entries))  { $currMap[$e.path.ToLowerInvariant()] = $e }

    $changes = New-Object System.Collections.Generic.List[object]
    $keys = @($baseMap.Keys) + @($currMap.Keys) | Select-Object -Unique
    foreach ($k in $keys) {
        $b = $null; $c = $null
        if ($baseMap.ContainsKey($k)) { $b = $baseMap[$k] }
        if ($currMap.ContainsKey($k)) { $c = $currMap[$k] }

        $before = if ($b) { [long]$b.physicalBytes } else { [long]0 }
        $after  = if ($c) { [long]$c.physicalBytes } else { [long]0 }
        $path   = if ($c) { $c.path } else { $b.path }
        $delta  = $after - $before
        if ([math]::Abs($delta) -lt 1MB) { continue }
        $changes.Add([pscustomobject][ordered]@{
            path        = $path
            kind        = if ($c) { $c.kind } else { $b.kind }
            beforeBytes = $before
            afterBytes  = $after
            deltaBytes  = $delta
            deltaPerDay = $(if ($rateMeaningful) { [long][math]::Round($delta / $elapsedDays) } else { $null })
            change      = if ($delta -gt 0) { 'grew' } else { 'shrank' }
        })
    }

    $sorted = @($changes | Sort-Object { [math]::Abs($_.deltaBytes) } -Descending)
    $grew   = @($changes | Where-Object { $_.deltaBytes -gt 0 } | Sort-Object deltaBytes -Descending)
    $shrank = @($changes | Where-Object { $_.deltaBytes -lt 0 } | Sort-Object deltaBytes)

    $freeDelta = [long]$Current.volume.freeBytes - [long]$Baseline.volume.freeBytes
    $usedDelta = [long]$Current.volume.usedBytes - [long]$Baseline.volume.usedBytes

    $verdict = 'ok'
    if ($freeDelta -le -5GB) { $verdict = 'alert' }
    elseif ($freeDelta -le -1GB) { $verdict = 'watch' }

    [pscustomobject][ordered]@{
        schemaVersion = $script:SchemaVersion
        kind          = 'report'
        generatedAt   = ConvertTo-IsoUtc (Get-Date)
        tool          = [pscustomobject][ordered]@{ name = $script:ToolName; version = $script:ToolVersion }
        host          = $Current.host
        baseline      = [pscustomobject][ordered]@{
            generatedAt = $Baseline.generatedAt
            root        = $Baseline.scan.root
            profile     = $Baseline.scan.profile
            accurate    = $Baseline.scan.accurate
        }
        current       = [pscustomobject][ordered]@{
            generatedAt = $Current.generatedAt
            root        = $Current.scan.root
            profile     = $Current.scan.profile
            accurate    = $Current.scan.accurate
        }
        elapsedDays   = [math]::Round($elapsedDays, 4)
        volume        = [pscustomobject][ordered]@{
            drive           = $Current.volume.drive
            totalBytes      = [long]$Current.volume.totalBytes
            freeBeforeBytes = [long]$Baseline.volume.freeBytes
            freeAfterBytes  = [long]$Current.volume.freeBytes
            freeDeltaBytes  = $freeDelta
            usedBeforeBytes = [long]$Baseline.volume.usedBytes
            usedAfterBytes  = [long]$Current.volume.usedBytes
            usedDeltaBytes  = $usedDelta
            freePerDayBytes = $(if ($rateMeaningful) { [long][math]::Round($freeDelta / $elapsedDays) } else { $null })
        }
        totals        = [pscustomobject][ordered]@{
            grewBytes   = [long](($grew   | Measure-Object deltaBytes -Sum).Sum)
            shrankBytes = [long](($shrank | Measure-Object deltaBytes -Sum).Sum)
        }
        changes       = @($sorted | Select-Object -First $Top)
        grew          = @($grew   | Select-Object -First $Top)
        shrank        = @($shrank | Select-Object -First $Top)
        findings      = @($Current.findings)
        verdict       = $verdict
        comparable    = $comparable
        incomparableReason = $incomparableReason
        warnBytes     = $WarnBytes
        reconciliation = $Current.reconciliation
    }
}

# ---------------------------------------------------------------------------
# formatting
# ---------------------------------------------------------------------------

function Format-DiskAuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
                [ValidateSet('text', 'markdown')][string]$Style = 'text',
        [ValidateSet('auto','en','zh-CN')][string]$Language = 'auto'
    )

    if ($PSBoundParameters.ContainsKey('Language')) { [void](Set-DiskAuditLanguage $Language) }
    $sb  = New-Object System.Text.StringBuilder
    $v   = $Report.volume
    $fmt = { param($b) Format-DiskAuditSize ([long]$b) }
    $verdictText = M ('verdict.' + $Report.verdict)

    if ($Style -eq 'markdown') {
        [void]$sb.AppendLine((M 'md.title'))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine((M 'md.generated' @($Report.generatedAt)))
        [void]$sb.AppendLine((M 'md.host' @($Report.host.name)))
        [void]$sb.AppendLine((M 'md.baseline' @($Report.baseline.generatedAt, $Report.baseline.profile)))
        [void]$sb.AppendLine((M 'md.current' @($Report.current.generatedAt, $Report.current.profile)))
        [void]$sb.AppendLine((M 'md.elapsed' @($Report.elapsedDays)))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine((M 'md.volume'))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine((M 'md.metric'))
        [void]$sb.AppendLine('| --- | --- |')
        [void]$sb.AppendLine((M 'md.total' @((& $fmt $v.totalBytes))))
        [void]$sb.AppendLine((M 'md.free_before' @((& $fmt $v.freeBeforeBytes))))
        [void]$sb.AppendLine((M 'md.free_after' @((& $fmt $v.freeAfterBytes))))
        [void]$sb.AppendLine((M 'md.free_delta' @((& $fmt $v.freeDeltaBytes))))
        [void]$sb.AppendLine('')

        if (-not $Report.comparable) {
            [void]$sb.AppendLine((M 'md.warning' @($Report.incomparableReason)))
            [void]$sb.AppendLine((M 'md.warning2'))
            [void]$sb.AppendLine('')
        }

        if ($Report.comparable -and @($Report.grew).Count -gt 0) {
            [void]$sb.AppendLine((M 'md.grew'))
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((M 'md.path'))
            [void]$sb.AppendLine('| --- | --- | --- | --- | --- |')
            foreach ($c in $Report.grew) {
                $perDay = if ($null -eq $c.deltaPerDay) { 'n/a' } else { & $fmt $c.deltaPerDay }
                [void]$sb.AppendLine(("| ``{0}`` | {1} | {2} | {3} | {4} |" -f $c.path, (& $fmt $c.beforeBytes), (& $fmt $c.afterBytes), (& $fmt $c.deltaBytes), $perDay))
            }
            [void]$sb.AppendLine('')
        }

        if ($Report.comparable -and @($Report.shrank).Count -gt 0) {
            [void]$sb.AppendLine((M 'md.shrank'))
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((M 'md.path4'))
            [void]$sb.AppendLine('| --- | --- | --- | --- |')
            foreach ($c in $Report.shrank) {
                [void]$sb.AppendLine(("| ``{0}`` | {1} | {2} | {3} |" -f $c.path, (& $fmt $c.beforeBytes), (& $fmt $c.afterBytes), (& $fmt $c.deltaBytes)))
            }
            [void]$sb.AppendLine('')
        }

        [void]$sb.AppendLine((M 'md.findings'))
        [void]$sb.AppendLine('')
        foreach ($f in $Report.findings) {
            [void]$sb.AppendLine(("- **[{0}/{1}] {2}** — {3}" -f $f.severity, $f.id, $f.title, $f.detail))
        }
        return $sb.ToString()
    }

    # ---- text ----
    $line = '=' * 62
    [void]$sb.AppendLine($line)
    [void]$sb.AppendLine((M 'report.header' @($Report.host.name)))
    [void]$sb.AppendLine((M 'report.subtitle' @($Report.current.profile, (Get-DiskAuditLanguage))))
    [void]$sb.AppendLine($line)
    [void]$sb.AppendLine((M 'report.baseline' @($Report.baseline.generatedAt, $Report.baseline.profile)))
    [void]$sb.AppendLine((M 'report.current' @($Report.current.generatedAt, $Report.current.profile)))
    [void]$sb.AppendLine((M 'report.elapsed' @($Report.elapsedDays)))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((M 'report.free' @((& $fmt $v.freeBeforeBytes), (& $fmt $v.freeAfterBytes), $(if ($v.freeDeltaBytes -ge 0) { '+' } else { '' }), (& $fmt $v.freeDeltaBytes))))
    if ($null -eq $v.freePerDayBytes) {
        [void]$sb.AppendLine((M 'report.perday_na'))
    }
    else {
        [void]$sb.AppendLine((M 'report.perday' @((& $fmt $v.freePerDayBytes))))
    }
    [void]$sb.AppendLine('')

    if (-not $Report.comparable) {
        [void]$sb.AppendLine((M 'report.warning'))
        [void]$sb.AppendLine((M 'report.warning_reason' @($Report.incomparableReason)))
        [void]$sb.AppendLine((M 'report.warning_body1'))
        [void]$sb.AppendLine((M 'report.warning_body2'))
        [void]$sb.AppendLine('')
    }

    if ($Report.comparable -and @($Report.grew).Count -gt 0) {
        [void]$sb.AppendLine((M 'report.grew'))
        foreach ($c in $Report.grew) {
            [void]$sb.AppendLine((M 'report.change_row' @((& $fmt $c.deltaBytes), (& $fmt $c.beforeBytes), (& $fmt $c.afterBytes), $c.path)))
        }
        [void]$sb.AppendLine('')
    }

    if ($Report.comparable -and @($Report.shrank).Count -gt 0) {
        [void]$sb.AppendLine((M 'report.shrank'))
        foreach ($c in $Report.shrank) {
            [void]$sb.AppendLine((M 'report.change_row' @((& $fmt $c.deltaBytes), (& $fmt $c.beforeBytes), (& $fmt $c.afterBytes), $c.path)))
        }
        [void]$sb.AppendLine('')
    }

    if (@($Report.findings).Count -gt 0) {
        [void]$sb.AppendLine((M 'report.findings'))
        foreach ($f in $Report.findings) {
            [void]$sb.AppendLine((M 'report.finding_line' @($f.severity, $f.title)))
            [void]$sb.AppendLine((M 'report.finding_detail' @($f.detail)))
            if ($f.path) { [void]$sb.AppendLine((M 'report.finding_at' @($f.path))) }
        }
        [void]$sb.AppendLine('')
    }

    $rec = $Report.reconciliation
    [void]$sb.AppendLine((M 'report.recon'))
    [void]$sb.AppendLine((M 'report.attributed' @((& $fmt $rec.attributedBytes))))
    [void]$sb.AppendLine((M 'report.volume_used' @((& $fmt $rec.usedBytes))))
    if ($null -eq $rec.residualBytes) {
        [void]$sb.AppendLine((M 'report.residual_na'))
    }
    else {
        [void]$sb.AppendLine((M 'report.residual' @((& $fmt $rec.residualBytes), $rec.residualKind)))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((M 'report.verdict' @($verdictText)))
    return $sb.ToString()
}


# ---------------------------------------------------------------------------
# orchestrator
# ---------------------------------------------------------------------------

function Invoke-DiskAudit {
    [CmdletBinding()]
    param(
        [string]$Path = $env:SystemDrive,
        [ValidateSet('quick', 'standard', 'deep')][string]$Profile = 'standard',
        [switch]$Accurate,
        [string]$SnapshotDir,
        [string]$Baseline,
        [switch]$NoCompare,
        [switch]$SaveSnapshot,
        [ValidateSet('text', 'json', 'markdown')][string]$Format = 'text',
        [string]$OutFile,
        [switch]$Redact,
        [long]$WarnBytes = 300MB,
        [int]$MaxSeconds = 0,
        [ValidateSet('auto', 'en', 'zh-CN')][string]$Language = 'auto',
        [switch]$PassThru,
        [switch]$Quiet
    )

    $lang = Set-DiskAuditLanguage $Language
    if (-not $SnapshotDir) { $SnapshotDir = Join-Path (Get-Location) 'snapshots' }
    $root = Resolve-DiskAuditRoot $Path

    $banner = (-not $Quiet) -and ($Format -eq 'text')
    if ($banner) {
        Write-Host ''
        Write-Host (M 'cli.banner' @($script:ToolVersion, $Profile, $lang)) -ForegroundColor Cyan
        Write-Host (M 'cli.scanning' @($root, $Profile)) -ForegroundColor DarkGray
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $current = New-DiskAuditSnapshot -Path $Path -Profile $Profile -Accurate:$Accurate -Redact:$Redact -MaxSeconds $MaxSeconds -Language $Language
    $sw.Stop()

    if ($banner) {
        Write-Host (M 'cli.scanned' @($current.scan.entryCount, @($current.findings).Count, $sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray
    }

    # ---- baseline -------------------------------------------------------
    $baselineSnapshot = $null
    $baselinePath = $Baseline
    if (-not $NoCompare -and -not $baselinePath) {
        if (Test-Path -LiteralPath $SnapshotDir) {
            $matching = Get-ChildItem -LiteralPath $SnapshotDir -Filter ("snapshot-*-{0}-*.json" -f $Profile) -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $matching) {
                $matching = Get-ChildItem -LiteralPath $SnapshotDir -Filter 'snapshot-*.json' -File -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }
            if ($matching) { $baselinePath = $matching.FullName }
        }
    }
    if (-not $NoCompare -and $baselinePath -and (Test-Path -LiteralPath $baselinePath)) {
        $baselineSnapshot = ConvertTo-DiskAuditSnapshot (Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json)
    }

    $report = $null
    if ($baselineSnapshot) {
        $report = Compare-DiskAuditSnapshot -Baseline $baselineSnapshot -Current $current -WarnBytes $WarnBytes -Language $Language
    }

    # ---- persist snapshot ------------------------------------------------
    $savedPath = $null
    if ($SaveSnapshot -or (-not $NoCompare)) {
        if (-not (Test-Path -LiteralPath $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }
        $stamp  = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $accTag = if ($current.scan.accurate) { 'acc' } else { 'std' }
        $savedPath = Join-Path $SnapshotDir ("snapshot-$stamp-$($current.scan.profile)-$accTag.json")
        Save-DiskAuditSnapshot -Snapshot $current -Path $savedPath | Out-Null
    }

    $payload = if ($report) { $report } else { $current }

    if ($OutFile) {
        $json = $payload | ConvertTo-Json -Depth 12
        $full = [System.IO.Path]::GetFullPath($OutFile)
        $dir2 = Split-Path -Parent $full
        if ($dir2 -and -not (Test-Path -LiteralPath $dir2)) { New-Item -ItemType Directory -Path $dir2 -Force | Out-Null }
        [System.IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    # ---- display ---------------------------------------------------------
    if ($Format -eq 'json' -and -not $PassThru) {
        if ($OutFile) {
            # Already written above; keep the pipeline clean for scripts.
            if (-not $Quiet) { Write-Host (M 'cli.written' @([System.IO.Path]::GetFullPath($OutFile))) }
        }
        else {
            $payload | ConvertTo-Json -Depth 12
        }
        return
    }

    # The report (or the first-run summary) is the result of the command and is
    # always printed; -Quiet only removes the chrome around it.
    Write-Host ''
    if ($report) {
        Write-Host (Format-DiskAuditReport -Report $report -Style $(if ($Format -eq 'markdown') { 'markdown' } else { 'text' }))
    }
    else {
        Write-Host (M 'cli.first_run') -ForegroundColor Yellow
        Write-Host ''
        $vol = $current.volume
        Write-Host (M 'cli.first_run_volume' @($vol.drive, ($vol.usedBytes / 1GB), ($vol.totalBytes / 1GB), $vol.freePct))
        foreach ($f in @($current.findings)) {
            Write-Host (M 'report.finding_line' @($f.severity, $f.title))
            Write-Host (M 'report.finding_detail' @($f.detail))
        }
        if (@($current.findings).Count -eq 0) { Write-Host (M 'cli.no_findings') -ForegroundColor Green }
    }

    if (-not $Quiet) {
        Write-Host ''
        if ($savedPath) { Write-Host (M 'cli.saved' @($savedPath)) -ForegroundColor DarkGray }
        if ($OutFile)   { Write-Host (M 'cli.written' @([System.IO.Path]::GetFullPath($OutFile))) -ForegroundColor DarkGray }
        if (-not $report) { Write-Host (M 'cli.next_run') -ForegroundColor Yellow }
        if ($Format -eq 'text') {
            Write-Host ''
            Write-Host (M 'cli.hint_json')   -ForegroundColor DarkGray
            Write-Host (M 'cli.hint_object') -ForegroundColor DarkGray
            Write-Host (M 'cli.hint_lang')   -ForegroundColor DarkGray
        }
        if ($PassThru) { Write-Host (M 'cli.passthru') -ForegroundColor DarkGray }
    }

    if ($PassThru) { return $payload }
    return
}


Export-ModuleMember -Function @(
    'Get-DiskAuditVolume',
    'New-DiskAuditSnapshot',
    'Save-DiskAuditSnapshot',
    'ConvertTo-DiskAuditSnapshot',
    'Compare-DiskAuditSnapshot',
    'Format-DiskAuditReport',
    'Format-DiskAuditSize',
    'Invoke-DiskAudit',
    'Set-DiskAuditLanguage',
    'Get-DiskAuditLanguage'
)
