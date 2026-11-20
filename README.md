# DiskAudit

[![CI](https://github.com/tianyuec11-design/DiskAudit/actions/workflows/ci.yml/badge.svg)](https://github.com/tianyuec11-design/DiskAudit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207-5391FE.svg)](https://github.com/tianyuec11-design/DiskAudit)

**Portable, snapshot-based disk space auditing for Windows.**

DiskAudit answers one question honestly: *"why is this volume full, and what changed?"*

Most disk tools show you folder sizes that don't add up to the free space you actually have.
DiskAudit treats the volume as the only source of truth, measures what it can, and then tells you
exactly how much it could **not** account for — instead of quietly presenting a wrong number.

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
     +11.9 GB      0.00 GB ->    11.90 GB   C:\Users\me\AppData\Local\Cache

 -- Findings ----------------------------------------------
   [high] Directory received a large amount of data in the last 24h
          26.3 GB written in the last 24 hours (now 26.5 GB, 2861 files).
          at C:\Users\me\AppData\Local\Temp\DiagOutputDir
   [warn] Multiple versions of the same application are present
          2 version directories under C:\Program Files\Vendor\App; keeping only 1.2.9 would release 1.51 GB.

 -- Reconciliation ----------------------------------------
   attributed : 337.4 GB
   volume used: 400.0 GB
   residual   :  62.6 GB  (undercount)

 Verdict: ALERT
```

---

## Why another disk tool?

Because "folder sizes" are a lie in four different ways, and every naive tool trips on at least one:

| Distortion | Effect | DiskAudit handles it by |
| --- | --- | --- |
| **Hard links** (`WinSxS`, `System32`, `DriverStore`) | the same 4 GB file is counted once per link | de-duplicating by NTFS file identity across the **whole** scan (`-Accurate`) |
| **Sparse / cloud placeholder files** (OneDrive, WPS, iCloud) | logical size says 2 GB, disk holds 0 | reading the **allocated** size via `GetCompressedFileSize` |
| **Reparse points** (junctions, symlinks) | infinite loops or silent double counting | never followed by default |
| **Denied subtrees** (`System Volume Information`, other users) | content silently missing | counted, reported, and surfaced as a reconciliation gap |

The result of all four is that `sum(folder sizes) ≠ used space`. DiskAudit makes that difference a
first-class metric instead of hiding it.

### Measured on a reference machine

`C:\Windows` on a stock Windows 11 install, scanned with `-Profile deep -Accurate`:

| | |
| --- | --- |
| logical bytes (what a naive tool reports) | **44.92 GB** |
| allocated, de-duplicated (what the volume holds) | **32.89 GB** |
| bytes that are hard-link duplicates | **11.52 GB (25.6 %)** |
| scan time | 135 s |

That is a quarter of the tree being counted twice by any tool that just adds up `FileInfo.Length`.

---

## Quick start

Requirements: Windows 10/11, PowerShell 5.1 or PowerShell 7. No dependencies.

```powershell
git clone https://github.com/<tianyuec11-design>/DiskAudit.git
cd DiskAudit

# First run: records a baseline snapshot
pwsh ./bin/disk-audit.ps1

# Second run: prints what changed since the baseline
pwsh ./bin/disk-audit.ps1
```

A snapshot is stored in `./snapshots/` on every run (override with `-SnapshotDir`).

> **One run is not enough.** The first run only records a baseline; the diagnosis appears on the
> second run, when there is something to compare against. Run it now, then again tomorrow (or after
> the disk starts shrinking).

### Running it on someone else's machine

Nothing has to be installed on that machine. PowerShell 5.1 already ships with Windows 10/11, and
DiskAudit has no dependencies — the whole project is a few hundred KB of text files.

```powershell
# with git
git clone https://github.com/<tianyuec11-design>/DiskAudit.git
cd DiskAudit
pwsh ./bin/disk-audit.ps1

# without git: download the ZIP from the GitHub page, extract it, then
cd DiskAudit-main
powershell -ExecutionPolicy Bypass -File .\bin\disk-audit.ps1
```

Good to know:

- **No administrator rights needed.** Elevation only improves coverage (`C:\System Volume Information`
  and other users' profiles become readable); without it those bytes show up in the reconciliation
  residual instead of being silently dropped.
- **Execution policy.** If scripts are blocked, `-ExecutionPolicy Bypass` on the command line applies
  to that one process only and changes nothing system-wide. If you extracted a ZIP, `Unblock-File`
  on the folder is the alternative.
- **Writing the report somewhere.** `-OutFile report.json` works from any directory; snapshots go to
  `./snapshots/` next to the script unless you pass `-SnapshotDir`.

### Letting an AI agent run it

DiskAudit does not require DSH, Copilot, Claude Code or any other agent — it is a plain PowerShell
tool a human can run in one line. But it works well *under* an agent, because everything it produces
is machine-readable and self-explaining:

```powershell
pwsh ./bin/disk-audit.ps1 -Profile standard -Format json -OutFile report.json
```

An agent can then reason over three fields instead of re-parsing a 400 GB tree:

| Field | What it answers |
| --- | --- |
| `grew[]` / `shrank[]` | which paths changed, by how much, per day |
| `findings[]` | which *shapes* look wrong, with evidence and a suggestion |
| `reconciliation.residualBytes` | how much of the volume nothing could explain |

Two caveats worth telling the agent:

1. **It must be able to read the drive.** Sandboxed agents that only see their workspace will report
   a volume where everything is "unattributed".
2. **It should run twice.** A single snapshot cannot show a trend — the useful question is always
   "what changed", not "what is big".

### Common invocations

```powershell
# Fast pass (~30 s): depth-limited, skips the expensive system trees
pwsh ./bin/disk-audit.ps1 -Profile quick

# Full pass, no exclusions (~2 min)
pwsh ./bin/disk-audit.ps1 -Profile standard

# Full pass + hard-link de-duplication + allocated sizes (~5 min)
pwsh ./bin/disk-audit.ps1 -Profile deep -Accurate

# Machine-readable output for a dashboard or a diff in CI
pwsh ./bin/disk-audit.ps1 -Format json -OutFile report.json

# Audit a different volume, or just one folder
pwsh ./bin/disk-audit.ps1 -Path D:
pwsh ./bin/disk-audit.ps1 -Path "$env:LOCALAPPDATA"

# Share a report without leaking the host name / user profile path
pwsh ./bin/disk-audit.ps1 -Format json -Redact -OutFile report.json
```

---

## How the model works

1. **The volume is authoritative.** `used = total - free` comes from the filesystem, not from adding
   up folders.
2. **Measure once, attribute once.** A single tree walk measures every path. Attribution then uses
   only the *non-overlapping* top-level entries, so a byte is never counted in both a parent and a
   child.
3. **Reconcile.** `residual = used - attributed`. It is reported, never swept under the rug.
4. **Compare, don't remember.** Every run stores a snapshot; the value of the tool is the delta over
   time, not an absolute number that nobody can interpret in isolation.
5. **Rules describe shapes, not products.** DiskAudit does not know about any specific vendor's
   bug. It knows that *a directory which receives 25 GB/day is a problem*, that *sibling folders
   named like version numbers mean an upgrade left the old build behind*, and that *a directory that
   is 90 % `.etl` files is a trace stream that was left on*.

See **[docs/DESIGN.md](docs/DESIGN.md)** for the full reasoning, the rejected alternatives, and the
known failure modes.

---

## What it detects

| Rule | What it looks for |
| --- | --- |
| `VOLUME_LOW_FREE` | free space below 10 % or 10 GB |
| `RECENT_WRITE_BURST` | a directory that received a lot of bytes in the last 24 h (the classic runaway-writer leak) |
| `TEMP_BLOAT` | temporary directories that grew beyond a sane size |
| `SYSTEM_SUPPORT_FILE` | pagefile / hiberfil / swapfile, with their real sizes |
| `STALE_VERSION_DIRS` | sibling folders named like version numbers (upgrade left the old build behind) |
| `UPDATER_STAGING` | `update` / `pending` / `patch` / `installer` staging areas |
| `LOG_ACCUMULATION` | a directory dominated by `.log` / `.etl` / `.dmp` files |
| `PLACEHOLDER_FILES` | sparse / cloud placeholder files (logical size overstates disk usage) |
| `RECONCILIATION_GAP` | scanned paths do not add up to the volume |
| `SCAN_INCOMPLETE` | directories that were denied during the scan |

Every finding carries `severity`, `evidence`, `reclaimableBytes` (when estimable) and a
`suggestion` — and it is **advice, not an action**. DiskAudit never deletes anything.

---

## Output formats

| Format | Use |
| --- | --- |
| `text` (default) | terminal report |
| `markdown` | drop into an issue or a PR comment |
| `json` | snapshots and reports for tooling / dashboards |

The JSON is versioned (`schemaVersion`) and documented in **[docs/SCHEMA.md](docs/SCHEMA.md)** with
JSON Schema files in [`schema/`](schema/).

---

## Profiles

| Profile | Depth | System trees | Hard links | Typical time |
| --- | --- | --- | --- | --- |
| `quick` | 4 | skipped (`WinSxS`, `WindowsApps`, `DriverStore`, …) | logical only | ~30 s |
| `standard` | unlimited | included | logical only | ~2 min |
| `deep` | unlimited | included | **de-duplicated, allocated sizes** | several minutes (≈10× `standard`) |

`-MaxSeconds` caps a scan for very large volumes; truncated scans are marked in the snapshot
(`scan.truncated = true`) and reported.

---

## Limitations (read these)

- **Windows only.** The identity/allocated-size path uses Win32 APIs through PowerShell.
- **No elevation requirements**, but `C:\System Volume Information` and other users' profiles are
  unreadable without it — this shows up as a reconciliation gap, not as a wrong number.
- **Shadow copies / restore points** cannot be measured from user space; they are part of the
  residual by definition.
- **`-Accurate` is slower** — it opens a handle per file to resolve the NTFS file identity. Measured on a reference laptop: 70k files took 3.6 s in `standard` and 37 s in `deep -Accurate`.
- **A single snapshot cannot prove a leak.** Two snapshots can.

---

## Roadmap

The JSON model is designed to feed a web dashboard (treemap, growth timeline, rule findings,
snapshot diff). See **[docs/ROADMAP.md](docs/ROADMAP.md)** — the schema is deliberately stable so the
front-end can be built independently.

---

## Contributing

Issues and pull requests are welcome. Please run `./tests/run-tests.ps1` before submitting; CI runs
it on Windows with PowerShell 5.1 and 7.

## License

MIT — see [LICENSE](LICENSE).
