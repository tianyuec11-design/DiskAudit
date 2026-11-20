# JSON schema reference

Two payloads are produced:

| Payload | Produced by | Purpose |
| --- | --- | --- |
| **snapshot** | `New-DiskAuditSnapshot`, every run | a point-in-time measurement |
| **report** | `Compare-DiskAuditSnapshot` | the diff between two snapshots |

Machine-readable JSON Schema files live in [`../schema/`](../schema/):
[`snapshot.schema.json`](../schema/snapshot.schema.json) · [`report.schema.json`](../schema/report.schema.json)

Conventions used everywhere:

- **bytes are integer `Int64`**, never strings, never pre-formatted.
- **timestamps are ISO-8601 UTC strings** (`2026-11-20T11:49:57Z`).
- **ids are stable**: `p_` + first 12 hex chars of `sha1(lowercased path)`.
- enums: `kind` = `dir|file`, `severity` = `info|warn|high`, `change` = `grew|shrank`,
  `residualKind` = `undercount|overcount|not-applicable`, `verdict` = `ok|watch|alert`.
- `schemaVersion` is present on both payloads and follows semver of the *data contract*, not of the tool.

---

## Snapshot

```jsonc
{
  "schemaVersion": "1.0",
  "kind": "snapshot",
  "generatedAt": "2026-11-20T11:49:57Z",
  "tool":  { "name": "DiskAudit", "version": "0.1.0" },
  "host":  { "name": "...", "user": "...", "os": "...", "psVersion": "7.7.0", "isElevated": false },
  "scan":  { },
  "volume":{ },
  "entries": [ ],
  "hotspots": [ ],
  "reconciliation": { },
  "findings": [ ]
}
```

### `host`

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string | `COMPUTERNAME`, or `<HOST>` with `-Redact` |
| `user` | string | `USERNAME`, or `<USER>` |
| `os` | string | `Environment.OSVersion` string |
| `psVersion` | string | PowerShell version that produced it |
| `isElevated` | bool | whether the scan ran as Administrator |

### `scan`

| Field | Type | Notes |
| --- | --- | --- |
| `root` | string | scan root, e.g. `C:\` |
| `profile` | `quick\|standard\|deep` | |
| `accurate` | bool | hard-link de-duplication + allocated sizes were active |
| `followReparse` | bool | reparse points followed (default `false`) |
| `maxDepth` | int | `0` = unlimited |
| `hotspotDepth` | int | how deep `hotspots` was recorded |
| `durationMs` | int | wall clock of the scan |
| `truncated` | bool | `-MaxSeconds` cut the scan short |
| `skippedNames` | string[] | leaf names deliberately not traversed |
| `entryCount` | int | length of `entries` |
| `hotspotCount` | int | length of `hotspots` |

### `volume`

| Field | Type | Notes |
| --- | --- | --- |
| `drive` | string | `C:` |
| `label` | string | volume label, may be empty |
| `fileSystem` | string | `NTFS`, `ReFS`, … |
| `totalBytes` | int64 | |
| `freeBytes` | int64 | |
| `usedBytes` | int64 | `total - free` — **the only authoritative number** |
| `freePct` | number | 2 decimals |

### `entries[]` — depth-1, non-overlapping

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `dir\|file` | |
| `systemFile` | bool | `pagefile.sys` / `hiberfil.sys` / `swapfile.sys` |
| `id` | string | stable id |
| `path`, `name` | string | |
| `depth` | int | always `1` for entries |
| `logicalBytes` | int64 | sum of file lengths |
| `physicalBytes` | int64 | allocated (accurate) or logical (fast); **use this for charts** |
| `sharedBytes` | int64 | logical bytes suppressed because the inode was already counted |
| `fileCount`, `dirCount` | int | |
| `errorCount` | int | directories that could not be read |
| `sparseFiles`, `offlineFiles` | int | placeholder detection |
| `reparseSkipped` | int | reparse points not followed |
| `newestWriteUtc` | string\|null | newest write time anywhere below |
| `bytesLast24h`, `bytesLast7d` | int64 | written inside those windows (0 for system files) |
| `logBytes` | int64 | `.log`, `.etl`, `.evtx`, `.dmp` |
| `tmpBytes` | int64 | `.tmp`, `.temp` |
| `installerBytes` | int64 | `.msi`, `.msp` |

### `hotspots[]` — depth ≥ 2, ranked by `physicalBytes`

Same shape as an entry minus `kind`/`systemFile`, plus `parentPath`. Capped at 120 nodes.
A hotspot's counters **include** its descendants; use them for drill-down, not for summing.

### `reconciliation`

| Field | Type | Notes |
| --- | --- | --- |
| `usedBytes` | int64 | from the volume |
| `attributedBytes` | int64 | Σ `entries[].physicalBytes` |
| `residualBytes` | int64\|null | `used - attributed`; `null` when the root is not the volume root |
| `residualKind` | enum | `undercount` (positive gap), `overcount` (negative), `not-applicable` |
| `accurate` | bool | |
| `method` | string | describes the attribution rule |

### `findings[]`

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | rule id, e.g. `RECENT_WRITE_BURST` |
| `severity` | `info\|warn\|high` | |
| `title`, `detail` | string | human readable |
| `path` | string\|null | subject of the finding |
| `reclaimableBytes` | int64 | estimate, `0` when unknown |
| `evidence` | object | rule-specific, all values JSON scalars/arrays |
| `suggestion` | string | advice, never an action taken |

---

## Report

```jsonc
{
  "schemaVersion": "1.0",
  "kind": "report",
  "generatedAt": "...",
  "tool": { }, "host": { },
  "baseline": { "generatedAt": "...", "root": "C:\\", "profile": "standard", "accurate": false },
  "current":  { "generatedAt": "...", "root": "C:\\", "profile": "standard", "accurate": false },
  "elapsedDays": 2.45,
  "volume": { },
  "totals": { "grewBytes": 0, "shrankBytes": 0 },
  "changes": [ ], "grew": [ ], "shrank": [ ],
  "findings": [ ],
  "verdict": "alert",
  "warnBytes": 314572800,
  "reconciliation": { }
}
```

### `volume`

| Field | Type | Notes |
| --- | --- | --- |
| `totalBytes` | int64 | |
| `freeBeforeBytes`, `freeAfterBytes` | int64 | |
| `freeDeltaBytes` | int64 | negative = space was lost |
| `usedBeforeBytes`, `usedAfterBytes`, `usedDeltaBytes` | int64 | |
| `freePerDayBytes` | int64\|null | normalised slope — the leak rate; `null` when the interval is under 72 minutes (extrapolating it would be fake precision) |

### `changes[]` / `grew[]` / `shrank[]`

| Field | Type | Notes |
| --- | --- | --- |
| `path` | string | |
| `kind` | `dir\|file` | |
| `beforeBytes`, `afterBytes` | int64 | `physicalBytes` on each side |
| `deltaBytes` | int64 | signed |
| `deltaPerDay` | int64\|null | `deltaBytes / elapsedDays`, `null` for intervals under 72 minutes |
| `change` | `grew\|shrank` | |

`changes` is sorted by `abs(deltaBytes)`; `grew` and `shrank` are the two directions, top 15 each by
default (`-Top`).

### `verdict`

| Value | Trigger |
| --- | --- |
| `ok` | free space changed by less than 1 GB |
| `watch` | free space dropped by 1 GB or more |
| `alert` | free space dropped by 5 GB or more |

### `comparable` / `incomparableReason`

`comparable: false` means the two snapshots were produced with different `profile` or `accurate`
settings. The **free-space** movement is still valid, but every path-level delta must be ignored: a
`quick` scan stops at depth 4 and legitimately reports less than a `standard` scan of the same volume.
Report renderers suppress the growth tables in that case.

---

## Versioning policy

- Adding a field → minor bump.
- Removing / renaming / changing the type of a field → major bump, and the old field is kept for one
  major release as deprecated.
- `schemaVersion` follows the same rule independently of the tool version.
