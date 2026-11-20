# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
数据契约（`schemaVersion`）与工具版本独立演进。

## [0.2.0] - 2026-11-20

### 新增

- **中文输出**：`-Language auto|en|zh-CN`。默认跟随 Windows 显示语言，
  覆盖报告正文、发现条目以及 JSON 中的 `title`/`detail`/`suggestion`。
  机器可读字段（`id`、`severity`、`evidence`、字节数）不随语言变化。
- **首次运行引导**：首次执行会明确告知"已建立基线、暂无可对比数据"，
  并给出下一步该做什么，而不是只丢一行 `Snapshot written.`
- **PowerShell 界面提示**：显示当前档位与语言、扫描开始/结束与耗时、
  快照保存路径，以及三条常用命令提示（JSON / 对象 / 语言）。
- **`-PassThru`**：把结果对象返回给管道，便于脚本二次处理。
- **`-Help`**：内置中英文帮助，列出全部参数与典型流程。
- **`-Quiet`**：只输出报告，去掉横幅与提示。
- 新增 `Set-DiskAuditLanguage` / `Get-DiskAuditLanguage` 两个导出函数。

### 修复

- `-Format json -OutFile` 时仍会把整份 JSON 打到标准输出，污染管道；
  现在只写文件并提示路径。
- CLI 用变量接收返回值，导致 `-Format json` 的输出被吞掉；改为直接进管道。
- `New-DiskAuditSnapshot` 会无条件重置语言，覆盖调用方设置的 `-Language`。
- 测试用例受本机 UI 语言影响（中文系统上断言英文标签会失败），现在固定语言后运行。

### 变更

- 版本号 0.1.0 → 0.2.0；测试数 35 → 41。

## [0.1.0] - 2026-11-20

首个公开版本。

### 新增

- **以卷为准的测量模型**：`used = total - free` 是唯一权威数据源，目录扫描只作为归因手段。
- **精确占用（`-Accurate`）**
  - 通过 `GetFileInformationByHandle` 取 NTFS 文件标识 `(卷序列号, 文件索引)`，在**整次扫描范围内**去重硬链接。
  - 通过 `GetCompressedFileSize` 读取实际分配大小，正确处理稀疏文件与云盘占位文件。
- **对账残差（reconciliation）**：`residual = used - attributed`，把"工具不知道的部分"变成一个显式指标，
  而不是悄悄给出一个错误的数字。
- **快照 + 对比**：每次运行落盘一个快照，下次运行输出变化明细与 `deltaPerDay`（泄漏速率）。
- **规则引擎（10 条）**：`VOLUME_LOW_FREE`、`RECENT_WRITE_BURST`、`TEMP_BLOAT`、`SYSTEM_SUPPORT_FILE`、
  `STALE_VERSION_DIRS`、`UPDATER_STAGING`、`LOG_ACCUMULATION`、`PLACEHOLDER_FILES`、
  `RECONCILIATION_GAP`、`SCAN_INCOMPLETE`。规则只描述**形状**（谁在持续写入、谁留下了旧版本），
  不绑定具体软件，因此可跨机器使用。
- **三种输出**：`text`、`markdown`、`json`；JSON 带版本号并有完整 JSON Schema。
- **稳定路径 id**：`p_` + `sha1(小写路径)` 前 12 位，方便未来的可视化前端做节点 key 与跨快照 diff。
- **脱敏（`-Redact`）**：把主机名与用户目录替换为 `<HOST>` / `<USERPROFILE>`，报告可直接公开分享。
- **三种扫描档位**：`quick` / `standard` / `deep`，配合 `-MaxSeconds` 时间预算；被截断的扫描会在
  `scan.truncated` 中标注。

### 修复（开发过程中发现并修正）

- `C:` 被 `Resolve-Path` 解析成"C 盘当前目录"而非根目录。
- `ConvertFrom-Json` 会把 ISO 字符串升级为 `[datetime]` 并按本地时区渲染，导致两次相隔 1 秒的快照
  被算成相差 8 小时；新增 `ConvertTo-DiskAuditSnapshot` 归一化处理。
- Markdown 表格中的反引号被 PowerShell 当成转义符吞掉。
- `hotspots` 混入了 depth-1 节点，与 `entries` 重复（由 JSON Schema 校验发现）。
- 写入爆发规则会在 `Users` / `Users\me` / `AppData` 等祖先目录上重复报告同一份数据；
  现在只报告最具体的那个节点。

### 已知限制

- 仅支持 Windows。
- `C:\System Volume Information`（卷影副本 / 还原点）在普通权限下不可读，会计入对账残差。
- 单次快照无法证明泄漏，两次及以上才行。

[0.1.0]: https://github.com/tianyuec11-design/DiskAudit/releases/tag/v0.1.0
