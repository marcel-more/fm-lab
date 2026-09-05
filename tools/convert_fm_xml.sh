#!/bin/bash
# Kompat-Wrapper — die Import-Engine lebt in ingestion/ (Katana XML Engine).
# Erhaelt den dokumentierten Aufrufpfad (FMS-Schedules, cron/launchd, Forks).
# bash-3.2-konform; exec = Exit-Codes/Signale unverfaelscht (Lock-Kontrakt exit 7).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ingestion/convert_fm_xml.sh" "$@"
