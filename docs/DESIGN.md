# Design notes

This document explains *why* DiskAudit is built the way it is, including the reasoning that led
here, the alternatives that were rejected, and where the model breaks down.

---

## 1. The question

> "The drive is full again. Where did it go?"

Every existing tool answers a subtly different question: *"how big is each folder?"*.
That question has a clean answer and a wrong one. The clean answer is a number. The correct answer
is: **it doesn't matter, because those numbers do not add up to the free space you have.**

A concrete case that started this project (Windows 11, 400 GB volume, 126 GB free):

```
sum of top-level directories     252.9 GB
root system files (pagefile etc)  26.3 GB
------------------------------------------------
accounted                        279.2 GB
actual used (total - free)       273.2 GB
```

The gap is not a bug. It is the accumulated effect of four different measurement distortions, and
every one of them pulls in a different direction.

---

## 2. The four distortions

### 2.1 Hard links — counted many times

NTFS allows one physical file to have many names. `C:\Windows\WinSxS` is largely hard links into
`C:\Windows\System32`; `DriverStore` and `System32` overlap the same way.

A recursive `sum(file.length)` therefore counts the same bytes once **per link**. On a stock Windows
install this alone can inflate a directory tree by several gigabytes.

*DiskAudit:* with `-Accurate`, every file is resolved to its NTFS identity
`(VolumeSerialNumber, FileIndex)` through `GetFileInformationByHandle`, and the scan keeps a global
set of seen identities. The first occurrence is charged its **allocated** size; every later
occurrence is charged `0` and its logical size is reported separately as `sharedBytes`.

### 2.2 Sparse files and cloud placeholders — counted as if they were real

OneDrive, iCloud, WPS, Dropbox and friends keep "dehydrated" files: the directory entry and the
logical length exist, the data does not. A folder can legitimately report `2.18 GB` while occupying
**zero** bytes of the volume. Compressed NTFS files behave similarly, just less dramatically.

`FileInfo.Length` returns the *logical* size. Only `GetCompressedFileSize` returns what the volume
actually holds.

*DiskAudit:* `-Accurate` charges `GetCompressedFileSize` (allocated) instead of `Length`, and counts
sparse/offline files so a report can say *"logical size here is misleading"* instead of silently
reporting a phantom 2 GB.

### 2.3 Reparse points — followed, and then everything is wrong

Junctions and symlinks create cycles (`C:\Users\<u>\AppData\Local\Application Data` famously points
back at `AppData\Local`), break naive recursion, and double count when the target lives elsewhere in
the same tree.

*DiskAudit:* never followed by default; skipped and counted (`reparseSkipped`) so the report can show
that something was deliberately not traversed.

### 2.4 Denied subtrees — counted as zero

`C:\System Volume Information` holds shadow copies and restore points and is unreadable without
elevation. Other users' profiles are likewise invisible. A tool that silently ignores them reports a
total that is simply missing gigabytes.

*DiskAudit:* records the denied directory count (`SCAN_INCOMPLETE`) and, more importantly, folds the
missing bytes into the reconciliation residual.

---

## 3. The reconciliation model

The core idea of the project:

```
used        = total - free                 (authoritative, from the volume)
attributed  = Σ physical bytes of depth-1 entries   (non-overlapping)
residual    = used - attributed
```

`residual` is reported on every run. It is not an error code; it is a **measurement of ignorance**.

| residual | meaning | typical cause |
| --- | --- | --- |
| ≈ 0 | the scan explains the volume | healthy |
| **> 0** (`undercount`) | something is using space that was not scanned | denied subtrees, shadow copies, restore points, NTFS metadata |
| **< 0** (`overcount`) | scanned bytes exceed used bytes | hard links counted twice, sparse files charged at logical size |

This single number converts "the tool is wrong" into "the tool knows exactly what it does not know",
which is the only honest position for a user-space disk analyser.

**The attribution set must not overlap.** Summing `C:\Users` *and* `C:\Users\me\AppData` would count
AppData twice. DiskAudit only sums depth-1 entries, and the rest of the snapshot exists for drill-down
and for the rule engine.

### Worked example

| | naive sum | DiskAudit (`-Accurate`) |
| --- | --- | --- |
| logical bytes, whole volume | 279.2 GB | — |
| allocated, de-duplicated | — | 273.1 GB |
| volume used | 273.2 GB | 273.2 GB |
| residual | **+5.9 GB error** | **≈ 0.1 GB** (real, unexplained) |

---

## 4. Snapshots instead of absolute numbers

A single measurement cannot distinguish "this folder is big" from "this folder is *growing*".
The second question is the one that matters: a 20 GB folder that has been 20 GB for a year is not a
problem; a 200 MB folder that gained 26 GB in three days is an emergency.

Design consequences:

- Every run writes a snapshot; runs compare against the most recent stored snapshot.
- Snapshots store **ISO-8601 UTC strings**, not local times and not `DateTime` objects.
  This is not pedantry: PowerShell's `ConvertFrom-Json` silently converts ISO strings into
  `[datetime]` and then re-renders them in the local culture, which shifts timelines by the UTC
  offset and produces nonsense such as "elapsed 0.33 days" for two runs one second apart.
  DiskAudit normalises on load (`Normalize-DiskAuditSnapshot`).
- Deltas are also expressed per day (`deltaPerDay`) so intervals of wildly different length are
  comparable.

Charts and dashboards later only need the same JSON: a series of snapshots is a time series.

---

## 5. Rules: detect shapes, not products

The temptation is to write a list of known offenders — *"delete the WSL trace directory"*, *"WPS logs
grow"*, *"doubao updater cache"*. That is unmaintainable and worthless on the next machine.

DiskAudit instead asks: **what shape does a leak have?**

| Shape | Rule | Why it generalises |
| --- | --- | --- |
| a directory that keeps receiving data | `RECENT_WRITE_BURST` | any runaway logger, any trace stream, any botched cache — no product names needed |
| sibling folders named like versions | `STALE_VERSION_DIRS` | describes the *pattern* of an in-place upgrade leaving the old build |
| a folder that is mostly `.etl`/`.log` | `LOG_ACCUMULATION` | diagnostics left enabled |
| `update`/`pending`/`patch` staging | `UPDATER_STAGING` | every vendor's updater does this |
| sparse + offline files | `PLACEHOLDER_FILES` | explains away phantom size without needing to know the cloud vendor |
| the residual | `RECONCILIATION_GAP` | when nothing found explains the volume |

Each rule emits `severity`, `evidence` and, where it can be estimated, `reclaimableBytes`.
Rules **never act**. Deleting is a human decision; the tool's job is to make the decision cheap.

Severity is relative to the volume, not absolute: 5 GB is noise on a 4 TB drive and fatal on a 64 GB
tablet.

Importantly, a rule that fires on an ancestor *and* a descendant is noise. `RECENT_WRITE_BURST`
therefore reports only the most specific node: if `...\Temp\DiagOutputDir` is the writer, reporting
`C:\Users` as well would be technically true and practically useless.

---

## 6. Data model for a future dashboard

The JSON is the product. Decisions taken so the front-end can be written independently:

- **Stable path ids.** `id = "p_" + sha1(lowercased path)[0..12]`. A dashboard can key nodes, diffs and
  alerts on `id` without relying on array positions.
- **Integers for bytes.** No "1.23 GB" strings in the data; formatting is a presentation concern.
- **UTC ISO-8601 for every timestamp**, including `generatedAt`, so a browser can `new Date(...)` it.
- **Enums, not prose**, for `kind` (`dir|file`), `severity` (`info|warn|high`), `change`
  (`grew|shrank`), `residualKind` (`undercount|overcount|not-applicable`).
- **`schemaVersion` on every payload**, so the site can migrate instead of guessing.
- **`-Redact`** rewrites the host name and the user profile path, so users can share a report publicly
  without leaking `C:\Users\<their real name>`.

See [SCHEMA.md](SCHEMA.md) and [ROADMAP.md](ROADMAP.md).

---

## 7. Failure modes and limitations

| Situation | What happens | Mitigation |
| --- | --- | --- |
| Volume with millions of files | scan takes minutes | `-Profile quick`, `-MaxSeconds`, `scan.truncated` is reported |
| `Add-Type` blocked (ConstrainedLanguage, AppLocker) | accurate mode unavailable | warns and falls back to logical sizes; `scan.accurate = false` is recorded |
| Files locked during scan | allocated size falls back to logical | identity still attempted; discrepancy shows up in the residual |
| Volume root is not the scan root | reconciliation is meaningless | `residualBytes = null`, `residualKind = "not-applicable"` |
| System restore points | never visible from user space | part of the residual by definition |
| Everything is fine | residual ≈ 0, no findings | `verdict: ok` — the tool must be able to say "nothing is wrong" |

The last row matters. A detector that always finds something is not a detector.

---

## 8. What would prove this design wrong

- A volume where `used - Σ(depth-1, de-duplicated, allocated)` is consistently large **and** no
  candidate cause (shadow copies, denied trees, metadata) explains it.
- A hard-link-heavy tree where the identity set fails to converge (would show up as `overcount`
  while `-Accurate` is on).
- A front-end that cannot render a snapshot without recomputing sizes client-side — that would mean
  the payload is wrong for its purpose.

If you hit one of these, it is a bug worth filing.
