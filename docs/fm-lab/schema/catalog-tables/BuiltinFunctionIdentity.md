# BuiltinFunctionIdentity

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived during import (pipeline phase 4) from the DDR calculation tokens and the layout symbol inventory, resolved against the generated reference seed — not extracted from the XML export
**Since:** catalog schema 1.32.0

The **reference identity** of every resolved [BuiltinFunction](../object-types/BuiltinFunction.md) node: which function of the standard reference a catalog node stands for. One row per node, and only for nodes the reference could resolve.

The table exists because the identity of a built-in must be *looked up*, not recomputed. FileMaker's export carries no function identity at all — a calculation chunk holds nothing but the name in the language of the client that wrote the formula:

```xml
<Chunk type="FunctionRef">Length</Chunk>
<Chunk type="FunctionRef">Get</Chunk>
```

The import therefore resolves every token against the reference name sets ([DesignFunctionNames](DesignFunctionNames.md) and the `Get`-parameter list in the same seed) and registers the node under the **canonical English name** — see [BuiltinFunction](../object-types/BuiltinFunction.md) for what that changed. This table records the outcome of that resolution, so every consumer (reference-count pills, token cross-navigation, category aggregation) can join it instead of re-deriving the rule from the object name.

## Columns

| Column | Type |
|---|---|
| `Object_UUID` | `VARCHAR` |
| `Function_ID` | `INTEGER` |
| `Canonical_Name` | `VARCHAR` |
| `Namespace` | `VARCHAR` |

## Notes

- `Object_UUID` is the primary key and references the node in [ObjectCatalog](../object-catalog/ObjectCatalog.md) (`Object_Type = 'BuiltinFunction'`). The table can never claim a node the catalog does not carry.
- `Canonical_Name` is the **identity key** — the English name the node's name and UUID were built from. The reference declares it its stable lookup key, which is why identity hangs on it and not on `Function_ID`: that column is a plain primary key in the reference, without a stability promise, so binding catalog UUIDs to it would move every built-in UUID whenever a reference rebuild renumbers.
- `Function_ID` is the reference's `functions.function_id` and is meant as a **join key within one import** (it is what a reference-documentation count joins on). Its long-term stability is deliberately irrelevant.
- `Namespace` is `function` or `getparameter` and says which name set resolved the node. Resolution is namespace-aware because one localized spelling can belong to both sets (Italian `NomeScript` is the design function `ScriptNames` *and* the `Get` parameter `ScriptName`); a `Get` sub-parameter resolves only in the parameter namespace, a free function token prefers the function namespace.
- **Absence is information.** A node whose token the reference does not know keeps its name-based identity and gets **no row** — the `Get` wrapper of a dynamic `Get ( $var )`, the keyword and constant tokens (`True`, `False`, `and`, `or`, `not`, `Bold`), the JSON type constants, and functions newer than the bundled reference. List them per anti-join:

```sql
SELECT oc.Object_Name
FROM ObjectCatalog oc
WHERE oc.Object_Type = 'BuiltinFunction'
  AND oc.Object_UUID NOT IN (SELECT Object_UUID FROM BuiltinFunctionIdentity);
```

- Rows come from both usage classes, because a `Get` parameter can appear **only** as a layout symbol (`{{PageNumber}}`) with no formula call anywhere in the solution — see [LayoutObjectSymbols](LayoutObjectSymbols.md).
- The generated seed is a hard precondition of the import: without it the pipeline aborts before phase 1 instead of quietly building a catalog with name-based identities.

## Two sides of the same resolution

This table is the **per-node** side: one row per catalog node, stating which reference function it is. Its sibling [BuiltinTokenResolution](BuiltinTokenResolution.md) is the **per-token** side: one row per token form that occurs in the calculations, mapping the identity string a token had before the normalization to the node it resolves to. That is where the namespace-aware rule lives, and it is what makes the resolution auditable after the fact — several token forms (`Get(PageNumber)`, `Get(Seitennummer)`, bare `Seitennummer`) point at the one node.

Consumers that know a built-in only by name do not need either table directly: the view `v_builtin_token_lookup` maps `lower(<name>)` — in every reference language, in both namespaces, and in both the decoded and the entity-encoded spelling — to the node.

**See also:** [BuiltinFunction](../object-types/BuiltinFunction.md) · [DesignFunctionNames](DesignFunctionNames.md) · [DDR_Calculations](DDR_Calculations.md) · [LayoutObjectSymbols](LayoutObjectSymbols.md) · [fm-spec](../../Wiki/fm-spec.md)
