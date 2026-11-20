# Roadmap

The tool is deliberately split: **measurement** (this repository) and **presentation** (a future
web dashboard). Nothing in the measurement layer depends on the dashboard, and the JSON contract is
designed so the dashboard can be built without touching the PowerShell code.

---

## Phase 0 — done

- Volume-authoritative measurement, allocated sizes, hard-link de-duplication.
- Snapshot + compare model with reconciliation residual.
- Rule engine based on shapes rather than product names.
- Versioned JSON for both payloads, `-Redact` for sharing.
- Stable path ids so a UI can key nodes across snapshots.

## Phase 1 — ingestion (next)

A tiny service that stores snapshots and serves aggregated queries. The PowerShell side already
produces the payload; ingestion should stay dumb.

```
POST /api/v1/hosts/{hostId}/snapshots      body: snapshot.schema.json
GET  /api/v1/hosts                          -> [{ hostId, lastSeen, volume, verdict }]
GET  /api/v1/hosts/{hostId}/timeline        -> [{ t, usedBytes, freeBytes }]
GET  /api/v1/hosts/{hostId}/snapshots       -> [{ id, generatedAt, profile }]
GET  /api/v1/snapshots/{id}/entries         -> entries + hotspots
GET  /api/v1/hosts/{hostId}/findings        -> open findings, deduplicated across snapshots
```

Design constraints:

- **Idempotent by `(host, generatedAt)`** — re-uploading the same snapshot must not duplicate it.
- **Store the raw JSON**, plus one denormalised table of `(snapshotId, pathId, path, physicalBytes)`
  for fast diffs. SQLite or DuckDB is enough for a single user; Postgres if multi-tenant.
- **Never recompute sizes server-side.** If a number is missing, the schema is wrong — fix the schema.
- Retention: keep the last N snapshots per host (default 90), never aggregate them away; the timeline
  is the most valuable artefact.

## Phase 2 — dashboard

Views, in the order that makes sense for the problem:

1. **Host overview** — one card per machine: free space, slope (GB/day), verdict, top finding.
2. **Growth timeline** — free/used over time, with snapshot markers and rule firings as annotations.
   This is the view that answers "when did it start?".
3. **Diff view** — two snapshots side by side, changed paths sorted by `deltaBytes`, drill-down into
   `hotspots`. This is the view that answers "what did it?".
4. **Treemap** — `entries` + `hotspots` by `physicalBytes`, colour by growth rate instead of size.
   Colour-by-growth is far more useful than the usual colour-by-size.
5. **Findings queue** — group by rule `id`, show `evidence`, let a human mark
   dismissed / accepted / fixed. Persisting that state is the only server-side logic worth writing.
6. **Reconciliation banner** — if `residualBytes` is large, say so at the top. The dashboard must be
   as honest as the CLI, otherwise the whole model is lost in the UI.

## Phase 3 — alerting

- Rate-based, not absolute: alert when `freePerDayBytes` stays below a threshold for K consecutive
  snapshots, or when the projected time-to-full drops under N days.
- Per-host baselines: a build server legitimately writes 200 GB/day.
- Silence windows and a "known noisy path" list, keyed by `id` so it survives path casing changes.

## Non-goals

- **Deleting files.** The tool recommends, the human decides. Automating deletion on a rule engine is
  how people lose data.
- **Cross-platform.** The measurement layer is Windows-specific by design (NTFS identity, Win32
  allocation sizes). A Linux port would be a separate module behind the same JSON schema.
- **Real-time monitoring.** Snapshots are periodic by nature; a file-system watcher would be a
  different product.

---

## Compatibility contract

The website may be built years later against this JSON. Therefore:

- `schemaVersion` is independent of the tool version.
- Enums never gain silent synonyms; new values are additive and documented.
- Byte counts never change units.
- `id` derivation (`sha1` of the lowercased path) is frozen; if it must change, both ids are emitted
  for one major version.
