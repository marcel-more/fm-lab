# Internal query templates

These SQL templates are called by the server and the web frontend by name (`queries/system/` via `/api/report` and `report:<name>`, `queries/modules/` via `/api/query`) and are not listed anywhere. Your own analyses belong in `rest-api/templates/dashboards-custom/` — a single `.sql` file with a `-- @` header is already a dashboard (`/create-custom-dashboard` builds one).
