# BuiltinTokenResolution

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived during import (pipeline phase 4) from the function tokens of the calculation chunks, resolved against the generated reference seed — not extracted from the XML export
**Since:** catalog schema 1.32.0

The **per-token side** of the built-in function resolution: one row per token *form* that occurs anywhere in the solution's calculations, mapping it to the [BuiltinFunction](../object-types/BuiltinFunction.md) node it resolves to. Its sibling [BuiltinFunctionIdentity](BuiltinFunctionIdentity.md) is the per-node side — one row per node, stating which reference function it is.

Two tables exist because the mapping is **many-to-one**. FileMaker writes `Get` parameters localized, and files the sub-parameter as a `FunctionRef` chunk of its own, so one and the same `Get ( PageNumber )` reaches the import as up to three different token forms:

| `Token_Key` | `Object_Name` | `Canonical_Name` |
|---|---|---|
| `Get::PageNumber` | `Get(PageNumber)` | `PageNumber` |
| `Get::Seitennummer` | `Get(PageNumber)` | `PageNumber` |
| `Seitennummer` | `Get(PageNumber)` | `PageNumber` |

All three point at the one node. That is what collapsed the three catalog objects a localized formula used to produce into one — see [BuiltinFunction](../object-types/BuiltinFunction.md).

## Columns

| Column | Type |
|---|---|
| `Token_Key` | `VARCHAR` |
| `Object_UUID` | `VARCHAR` |
| `Object_Name` | `VARCHAR` |
| `Canonical_Name` | `VARCHAR` |
| `Function_ID` | `INTEGER` |
| `Namespace` | `VARCHAR` |

## Notes

- `Token_Key` is the **previous identity string** — `Get::<Sub>` for a `Get` pair, the bare token otherwise. It is the string every call site already forms, which makes this table the mapping *old → new* and keeps every call site a plain equi-join on a small table: one row per token form, not per occurrence.
- `Object_UUID` and `Object_Name` are the node the token resolves to, computed with the unchanged UUID formula over a canonicalized input. A token that was already canonical English therefore keeps the UUID it had before the normalization.
- **`Canonical_Name IS NULL` means the reference did not know the token.** Such a token keeps its name-based identity — the node is still created, it just carries no reference identity and gets no row in [BuiltinFunctionIdentity](BuiltinFunctionIdentity.md). This is the audit trail: after the import you can still tell whether a given token resolved or fell back.

```sql
-- Which tokens fell back to name-based identity?
SELECT Token_Key, Object_Name
FROM BuiltinTokenResolution
WHERE Canonical_Name IS NULL
ORDER BY Token_Key;
```

- `Namespace` (`function` or `getparameter`) is the name set that matched, and `NULL` on a fallback row. Resolution is namespace-aware because one localized spelling can belong to both sets: a `Get` pair resolves only in the parameter namespace, a free token prefers the function namespace and falls back to the parameter one.
- The table is **persistent, not temporary**, because one of its consumers is the calculation mirror in the view `v_calculation_links` — a view over session state would break after the import.
- Consumers that know a built-in only by name need neither this table nor its sibling directly: the view `v_builtin_token_lookup` maps `lower(<name>)` — in every reference language, in both namespaces and in both the decoded and the entity-encoded spelling — to the node.

**See also:** [BuiltinFunctionIdentity](BuiltinFunctionIdentity.md) · [BuiltinFunction](../object-types/BuiltinFunction.md) · [DesignFunctionNames](DesignFunctionNames.md) · [DDR_Calculations](DDR_Calculations.md) · [fm-spec](../../Wiki/fm-spec.md)
