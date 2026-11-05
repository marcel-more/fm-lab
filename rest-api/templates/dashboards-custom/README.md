# Custom dashboards

This folder holds **your own** dashboards. Everything you put here appears in
the dashboard overview under **Custom**, either directly on that level or
grouped in sub-folders (up to four levels deep).

A dashboard comes in one of two forms: a **single-file dashboard** — one
`<id>.sql` with a `-- @` header (title, description, click action, default
result, …), shown as a sortable, searchable table — or a **bundle** — a
directory `<id>/` with `manifest.json`, `layout.json`, `data/` and `locales/`
for tiles, filters and several panels. The `/create-custom-dashboard` skill
builds either and recommends the form.

- Only this README, `folder.json` and `.gitkeep` are tracked by git. Your
  dashboards are ignored, so `git pull` and fm-lab updates never touch them.
- Create a dashboard with the `/create-custom-dashboard` skill, or copy a
  shipped one from `../dashboards/` and give it a new id.
- The id is the file name without `.sql` or the bundle directory name (which
  must equal `manifest.id`); both forms share one namespace.
- Group dashboards in sub-folders. An optional `folder.json` in a sub-folder sets
  its label (`title`, `locales`), `description` and sort `order`.
- An id that matches a shipped content dashboard overrides it; the overview
  marks yours as overriding the default. Ids of system and module bundles
  (`home`, `_generic`, `dashboards`, `docs`, …) are reserved — a custom
  dashboard with such an id is ignored; a single file must also not be named
  like an internal template in `../queries/`.

```
dashboards-custom/
├── my_list.sql            Dashboards / Custom / <title>   (single file)
├── my_dashboard/          Dashboards / Custom / <title>   (bundle)
└── team/                  Dashboards / Custom / Team
    ├── folder.json        optional: title, description, order, locales
    └── weekly_report/     Dashboards / Custom / Team / <title>
```
