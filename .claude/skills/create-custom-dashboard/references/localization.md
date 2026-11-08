# Localization of dashboard bundles

The bundle files (`manifest.json`, `layout.json`) hold the **English defaults**.
Every other supported language lives in `locales/<lang>.json`, resolved at request
time by the REST API (`rest-api/src/services/dashboard-i18n.service.js`).

## Languages

Create **10** files: `de`, `es`, `fr`, `it`, `nl`, `pt`, `sv`, `ja`, `ko`,
`zh-Hans`. Do **not** create `en.json` — English resolves from the bundle files.
Generate all 10 in one pass; keep the key structure identical across languages,
only the values change.

## File structure

Path: `rest-api/templates/dashboards-custom/[<folder>/]<id>/locales/<lang>.json`

```json
{
  "manifest": {
    "title": "<title in target language>",
    "description": "<description in target language>"
  },
  "layout": {
    "summary_kpistrip.props.items[0].label": "<KPI label>",
    "url_details.props.title": "<section card title>",
    "url_details_table.props.columns[0].label": "<column label>",
    "url_details_table.props.searchPlaceholder": "<search hint>",
    "url_details_table.props.empty.message": "<empty-state message>",
    "url_comment_filter.props.options[0].label": "<chip label>"
  }
}
```

## Override key forms

1. **ID form (use this):** `"<node-id>.<relative.path>"` — the part before the
   first dot is the node's `id` from `layout.json`; the rest is resolved relative
   to that node. Survives inserting/reordering cards. This is why every generated
   node carries an `id`.
2. **Legacy path form (read-only knowledge):** `"root.children[0].props.title"` —
   absolute positional path. Exists in older bundles; never generate it.

Array indices use `[0]`, `[1]`, …. Unresolved keys are logged as warnings by the
API — after generating locales, the validation gate's log check will surface typos.

## What to translate

**Only user-visible literals:**
- card `title` / `subtitle`
- KPI / DefinitionList item `label`s
- table column `label`s and the captions of a column's `valueLabels` — one key
  per code: `"<table-id>.props.columns[3].valueLabels.dead_branch": "Toter Ast"`
  (the code itself is the key and stays English)
- List `primary`/`secondary`/… template **text** (keep the `{{tokens}}` intact)
- `searchPlaceholder`, `empty.message`
- `FilterChips` / `Select` option `label`s, `Slider` `label`
- `Markdown` `content` (translate the prose; keep object names/SQL identifiers)

**Never translate:** dataset IDs, `field` names, `param` names / option `value`s,
`format` values, icon names, action names/args, node `id`s.

Reference bundles (shipped, under `rest-api/templates/dashboards/`):
`developer-workflow/script_todos/locales/de.json` (compact),
`modularization/external_apis/locales/fr.json` (ID-form with full layout overrides).

## Folder bundles

When a bundle lives in a folder
(`dashboards-custom/<folder>/<id>/`), the folder's optional `folder.json` carries
its own inline translations — no locales/ directory. The area level "Custom"
itself is a fixed name and is never translated:

```json
{ "title": "Modularization", "icon": "boxes", "description": "…", "order": 2,
  "locales": { "de": "Modularisierung", "fr": "Modularisation", … } }
```
