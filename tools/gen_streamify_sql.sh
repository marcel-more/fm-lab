#!/bin/bash
# Kompat-Wrapper — der Streamify-Generator lebt in ingestion/ (Katana XML Engine).
# bash-3.2-konform; exec = rc-Kontrakt (0/2/3/4) unverfaelscht.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ingestion/gen_streamify_sql.sh" "$@"
