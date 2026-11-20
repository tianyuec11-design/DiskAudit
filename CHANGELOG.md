# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
数据契约（`schemaVersion`）与工具版本独立演进。

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
