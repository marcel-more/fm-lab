# trigger_compat

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

The platform compatibility matrix of every script-trigger event: whether the event fires in Pro, on Server, in Go, WebDirect, Cloud, via the Data API and via Custom Web Publishing. One row per [trigger slot](script_triggers.md), same seven columns and the same vocabulary as [step_compat](step_compat.md) — a consumer reads both tables with one platform vocabulary.

**The source is tri-state, the columns are not.** Claris documents each cell as *Yes*, *No* or *Partial*, and the BOOLEAN columns lose the third value: `true` = Yes, `false` = No, and **`NULL` = Partial — conditionally supported, see the trigger's notes on its Claris help page**. `NULL` never means "undocumented" and never means "compatible"; only a trigger missing from the table entirely would mean Claris states nothing (the table is closed at 26 rows, so on a reference that carries it that case does not occur). Consumers must preserve this distinction — reporting a Partial event as unsupported (or as fully supported) is exactly the misreading this note exists to prevent.

Where the tri-state matters in practice: `OnLayoutKeystroke` fires only partially in Go and WebDirect, the object-level `OnObjectEnter`, `OnObjectExit`, `OnObjectModify` and `OnObjectKeystroke` only partially in WebDirect, `OnLastWindowClose` only partially via the Data API and Custom Web Publishing. Four events are exclusive to FileMaker Go (`OnExternalCommandReceived`, `OnFileAVPlayerChange`, `OnObjectAVPlayerChange`; `OnGestureTap` in Pro and Go) — the same exclusivity predicate the platform tests apply to steps derives them from the table, without a list of slot ids.

**Runtime axis, not OS axis.** Like [step_compat](step_compat.md) the columns name FileMaker *runtimes*; the OS layer ([step_os_affinity](step_os_affinity.md), [runtime_os_matrix](runtime_os_matrix.md)) is separate and has no trigger rows.

**Join key.** The solution catalog joins over the slot id (`ScriptTriggers.Trigger_ID = trigger_id`) — never over the raw event name, which is a localizable passthrough of the export. No version columns: the introduction version of an event lives in [script_triggers](script_triggers.md).

## Columns

| Column | Type |
|---|---|
| `trigger_id` | `INTEGER` |
| `pro` | `BOOLEAN` |
| `server` | `BOOLEAN` |
| `go` | `BOOLEAN` |
| `webdirect` | `BOOLEAN` |
| `cloud` | `BOOLEAN` |
| `dataapi` | `BOOLEAN` |
| `cwp` | `BOOLEAN` |
| `evidence` | `VARCHAR` |
| `verified_doc_build` | `VARCHAR` |

**See also:** [script_triggers](script_triggers.md) · [step_compat](step_compat.md) · [ScriptTrigger](../object-types/ScriptTrigger.md) · [Analysis Tests](../../Wiki/Analysis%20Tests.md)
