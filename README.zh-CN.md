# DiskAudit

[![CI](https://github.com/tianyuec11-design/DiskAudit/actions/workflows/ci.yml/badge.svg)](https://github.com/tianyuec11-design/DiskAudit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207-5391FE.svg)](https://github.com/tianyuec11-design/DiskAudit)

**面向 Windows 的、基于快照的磁盘空间审计工具。**

[English](README.md) | 简体中文

DiskAudit 只回答一个问题，并且回答得尽量诚实：**这块盘为什么满了？从什么时候开始的？**

大部分磁盘工具给你的是"每个文件夹多大"，而这些数字加起来永远对不上你实际剩下的空间。
DiskAudit 把卷本身当作唯一事实来源，只测量它能测量的部分，然后**明确告诉你它还有多少没能解释**，
而不是悄悄给你一个错误的数字。

```text
==============================================================
 Disk audit report   WORKSTATION
==============================================================
 Baseline : 2026-11-18T09:00:00Z  (standard)
 Current  : 2026-11-20T19:45:00Z  (standard)
 Elapsed  : 2.45 days

 Free     :   158.90 GB ->    96.20 GB   (-62.70 GB)
 Per day  :    -25.6 GB

 -- Grew --------------------------------------------------
     +26.3 GB      0.21 GB ->    26.51 GB   C:\Users\me\AppData\Local\Temp\DiagOutputDir
     +24.5 GB      0.00 GB ->    24.49 GB   C:\Program Files\Vendor\Models

 -- Findings ----------------------------------------------
   [high] Directory received a large amount of data in the last 24h
          26.3 GB written in the last 24 hours (now 26.5 GB, 2861 files).
   [warn] Multiple versions of the same application are present
          2 version directories under ...; the non-current one accounts for 1.51 GB.

 -- Reconciliation ----------------------------------------
   attributed : 337.4 GB
   volume used: 400.0 GB
   residual   :  62.6 GB  (undercount)

 Verdict: ALERT
```

---

## 为什么还需要一个磁盘工具

因为"文件夹大小"会因为四种原因失真，而几乎每个工具都会踩中至少一个：

| 失真来源 | 后果 | DiskAudit 的处理 |
| --- | --- | --- |
| **硬链接**（`WinSxS`、`System32`、`DriverStore`） | 同一个文件按链接数被重复统计 | `-Accurate` 下按 NTFS 文件标识**全局去重** |
| **稀疏 / 云盘占位文件**（OneDrive、WPS、iCloud） | 逻辑大小显示 2 GB，实际占 0 | 读取**实际分配大小**（`GetCompressedFileSize`） |
| **重解析点**（junction / symlink） | 递归成环或重复计数 | 默认不跟随，并记录跳过了多少 |
| **无权限目录**（`System Volume Information`） | 内容被静默忽略 | 统计并计入"对账残差" |

结论是 `Σ文件夹大小 ≠ 已用空间`。DiskAudit 把这个差额变成一等公民指标，而不是藏起来。

### 参考机实测

某台标准 Windows 11 机器上的 `C:\Windows`，用 `-Profile deep -Accurate` 扫描：

| 指标 | 数值 |
| --- | --- |
| 逻辑大小（普通工具会报的数字） | **44.92 GB** |
| 实际分配、去重后（卷上真实占用） | **32.89 GB** |
| 硬链接重复量 | **11.52 GB（25.6%）** |
| 扫描耗时 | 135 秒 |

也就是说，任何"把 `FileInfo.Length` 加起来"的工具，在这个目录上会**多报四分之一**。

---

## 快速开始

环境要求：Windows 10/11，PowerShell 5.1 或 PowerShell 7，无第三方依赖。

```powershell
git clone https://github.com/<tianyuec11-design>/DiskAudit.git
cd DiskAudit

# 第一次运行：建立基线快照
pwsh ./bin/disk-audit.ps1

# 第二次运行：打印与基线的差异
pwsh ./bin/disk-audit.ps1
```

> **只跑一次是不够的。** 第一次运行只是记录基线，真正的诊断出现在第二次——
> 有了对比对象，才知道"变了什么"。所以：现在跑一次，明天（或者发现盘开始缩水时）再跑一次。

### 在别人的机器上运行

那台机器**什么都不用装**。Windows 10/11 自带 PowerShell 5.1，而 DiskAudit 没有任何第三方依赖，
整个项目只有几百 KB 的文本文件。

```powershell
# 有 git
git clone https://github.com/<tianyuec11-design>/DiskAudit.git
cd DiskAudit
pwsh ./bin/disk-audit.ps1

# 没有 git：从 GitHub 页面下载 ZIP，解压后
cd DiskAudit-main
powershell -ExecutionPolicy Bypass -File .\bin\disk-audit.ps1
```

几点说明：

- **不需要管理员权限。** 提权只是让覆盖面更完整（`C:\System Volume Information` 和他人用户目录变得可读）；
  不提权也不会算错，那些字节会老老实实出现在对账残差里，而不是被悄悄丢掉。
- **执行策略被拦怎么办。** 命令行加 `-ExecutionPolicy Bypass` 只对当前这一次进程生效，不改系统设置。
  如果是解压 ZIP 后被标记为"来自网络"，对文件夹执行 `Unblock-File` 也可以。
- **报告写到哪。** `-OutFile report.json` 可以写到任意位置；快照默认落在脚本同级的 `./snapshots/`，
  可以用 `-SnapshotDir` 改。

### 让 AI Agent 来跑

DiskAudit 不依赖 DSH、Copilot、Claude Code 之类的任何 Agent——它就是个普通的 PowerShell 工具，
人一行命令就能跑。但它很适合**被 Agent 调用**，因为输出全部是机器可读、且能自我解释的：

```powershell
pwsh ./bin/disk-audit.ps1 -Profile standard -Format json -OutFile report.json
```

Agent 只需要读三个字段，不用自己去解析 400 GB 的目录树：

| 字段 | 回答什么问题 |
| --- | --- |
| `grew[]` / `shrank[]` | 哪些路径变了、变了多少、折算每天多少 |
| `findings[]` | 哪些**形状**不对劲，附带证据和处理建议 |
| `reconciliation.residualBytes` | 还有多少空间是"谁也没解释清楚"的 |

有两个坑要提醒 Agent：

1. **它必须能读到盘。** 被沙箱限制在某个工作目录里的 Agent，会报告"整块盘都没有归属"。
2. **它应该跑两次。** 单次快照看不出趋势——有意义的问题永远是"变了什么"，而不是"什么大"。

### 常用命令

```powershell
# 快速档（约 30 秒）：限制深度、跳过昂贵系统目录
pwsh ./bin/disk-audit.ps1 -Profile quick

# 完整档（约 2 分钟）：不加任何排除
pwsh ./bin/disk-audit.ps1 -Profile standard

# 精确档：硬链接去重 + 实际分配大小（较慢）
pwsh ./bin/disk-audit.ps1 -Profile deep -Accurate

# 输出机器可读 JSON，供看板或 CI 使用
pwsh ./bin/disk-audit.ps1 -Format json -OutFile report.json

# 审计其它盘，或只审计一个目录
pwsh ./bin/disk-audit.ps1 -Path D:
pwsh ./bin/disk-audit.ps1 -Path "$env:LOCALAPPDATA"

# 脱敏后再分享（主机名、用户目录会被替换）
pwsh ./bin/disk-audit.ps1 -Format json -Redact -OutFile report.json

# 中文输出（默认跟随系统语言，这里可强制指定）
pwsh ./bin/disk-audit.ps1 -Language zh-CN

# 查看内置帮助（跟随当前语言）
pwsh ./bin/disk-audit.ps1 -Help

# 不要文字报告，直接拿对象做二次处理
$r = pwsh ./bin/disk-audit.ps1 -PassThru
```

### 第一次运行会告诉你什么

新机器没有历史数据，所以第一次运行只能描述现状并记录基线。它会明说这一点，并告诉你下一步该做什么：

```text
DiskAudit 0.2.0   档位=standard   语言=zh-CN
正在扫描 C:\ ...（档位 standard，首次完整扫描约需 1-2 分钟）
扫描完成：23 个顶层条目，13 条发现，用时 61.2 秒

这是第一次运行，已记录基线，暂时没有可对比的数据。

  C:  已用 241.35 GB / 共 400.00 GB（39.7% 可用）
   [warn] 同一程序存在多个版本目录
            ...

快照已保存：./snapshots/snapshot-20261120T124653Z-standard-std.json
下一步：过一段时间（或发现磁盘变小）再运行一次同样的命令，就能看到变化。

要结构化结果：  .\bin\disk-audit.ps1 -Format json -OutFile report.json
要 PowerShell 对象： $r = .\bin\disk-audit.ps1 -PassThru
切换语言：      -Language zh-CN   或   -Language en
```

### 输出语言

`-Language auto`（默认）跟随 Windows 显示语言；`en` 与 `zh-CN` 可强制指定。

它影响所有**给人看**的文字：报告正文、发现条目，以及 JSON 里的 `title` / `detail` / `suggestion` 三个字段。

**机器可读的契约不随语言变化**：`id`、`severity`、`evidence`、`reclaimableBytes` 以及所有字节数完全一致，
所以看板可以直接忽略这些散文，只按 `id` 和 `evidence` 渲染。


---

## 模型是怎么成立的

1. **卷是权威**：`used = total - free` 来自文件系统，不是把文件夹加起来。
2. **只测一次、只归因一次**：一次遍历测完所有路径；归因时只用**互不包含**的顶层条目，
   一个字节不会被父子重复计算。
3. **对账**：`residual = used - attributed`，永远报告，绝不掩盖。
4. **比较，而不是记忆**：每次运行都落一个快照，工具的价值在于**变化量**，
   而不是一个孤立、无法解读的绝对数字。
5. **规则描述形状，不描述产品**：DiskAudit 不知道任何具体软件的 bug。它知道的是
   *一个每天持续写入 25 GB 的目录一定有问题*、*同级出现多个版本号目录说明升级时留下了旧版本*、
   *某个目录里 90% 是 `.etl` 说明有个追踪流没关*。

完整推导（含被否决的备选方案与已知失效场景）见 [docs/DESIGN.md](docs/DESIGN.md)。

---

## 检测规则

| 规则 | 检测内容 |
| --- | --- |
| `VOLUME_LOW_FREE` | 可用空间低于 10% 或 10 GB |
| `RECENT_WRITE_BURST` | 最近 24 小时持续大量写入的目录（最典型的泄漏形态） |
| `TEMP_BLOAT` | 临时目录异常膨胀 |
| `SYSTEM_SUPPORT_FILE` | 页面文件 / 休眠文件 / swapfile 的真实占用 |
| `STALE_VERSION_DIRS` | 同级版本号目录（升级残留），按新旧时间差判断严重程度 |
| `UPDATER_STAGING` | `update` / `pending` / `patch` / `installer` 暂存目录 |
| `LOG_ACCUMULATION` | 被 `.log` / `.etl` / `.dmp` 占主导的目录 |
| `PLACEHOLDER_FILES` | 稀疏 / 云盘占位文件（逻辑大小误导） |
| `RECONCILIATION_GAP` | 扫描结果对不上卷 |
| `SCAN_INCOMPLETE` | 扫描时被拒绝访问的目录 |

每条发现都带 `severity`、`evidence`、`reclaimableBytes` 和 `suggestion`——**只是建议，绝不自动删除**。

---

## 输出与兼容性

| 格式 | 用途 |
| --- | --- |
| `text`（默认） | 终端报告 |
| `markdown` | 粘进 issue / PR |
| `json` | 快照与报告，供工具或看板消费 |

JSON 带 `schemaVersion`，字段说明见 [docs/SCHEMA.md](docs/SCHEMA.md)，
JSON Schema 见 [`schema/`](schema/)。

---

## 三种扫描档位

| 档位 | 深度 | 系统目录 | 硬链接 | 典型耗时 |
| --- | --- | --- | --- | --- |
| `quick` | 4 | 跳过（`WinSxS`、`WindowsApps`、`DriverStore` 等） | 按逻辑大小 | ~30 秒 |
| `standard` | 不限 | 包含 | 按逻辑大小 | ~2 分钟 |
| `deep` | 不限 | 包含 | **去重 + 实际分配大小** | 数分钟（约为 `standard` 的 10 倍） |

`-MaxSeconds` 可为超大卷设置时间预算；被截断的扫描会标记 `scan.truncated = true`。

---

## 已知限制

- **仅 Windows**：文件标识与分配大小依赖 Win32 API。
- **不需要管理员权限**，但 `C:\System Volume Information` 和他人用户目录读不到——
  这体现为对账残差，而不是一个错误数字。
- **卷影副本 / 还原点**无法从用户态测量，天然属于残差。
- **`-Accurate` 明显更慢**：每个文件要开一次句柄解析文件标识。实测参考机：7 万文件 `standard` 用时 3.6 秒，`deep -Accurate` 用时 37 秒。
- **单次快照不能证明泄漏**，两次才行。

---

## 后续规划

JSON 模型是为将来的可视化看板设计的（增长时间线、差异对比、树图、规则队列）。
详见 [docs/ROADMAP.md](docs/ROADMAP.md)。数据契约刻意保持稳定，前端可以独立开发。

## 贡献

欢迎 issue 与 PR。提交前请跑 `./tests/run-tests.ps1`；CI 会在 PowerShell 5.1 与 7 下执行。

## 许可证

MIT，见 [LICENSE](LICENSE)。
