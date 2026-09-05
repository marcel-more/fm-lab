-- @title: Session run metrics (B.7) — wall-clock, API/tool calls, tokens from the session transcript
-- @description: Reads the Claude Code session transcript (NDJSON) with DuckDB only — no Python,
--               no Node. Assistant records carry message.usage; one API message appears once per
--               content block, so records are de-duplicated by message.id (max per field).
-- @version: 1.0.0
-- @tags: report, metrics, session
-- @note: read-only. Run via session_usage.sh (resolves the transcript path) or directly with:
--   SET VARIABLE transcript = '<path.jsonl>';
--   SET VARIABLE since = '2026-09-05T08:00:00Z';         -- UTC ISO-8601, required
--   SET VARIABLE until = NULL;                            -- optional (default: last record)
--   SET VARIABLE marks = 'R0=<ISO>,R1=<ISO>,…';           -- optional phase boundaries, sorted by time
-- Result sets: #1 window line · #2 totals table · #3 per-phase table (only when marks given).
-- The window counts everything in the session between since and until — including user wait
-- time at the readiness gate; say so in the report when it matters.

CREATE OR REPLACE TEMP TABLE _rec AS
SELECT
  (json->>'timestamp')::TIMESTAMPTZ                                              AS ts,
  COALESCE(json->'message'->>'id', json->>'requestId', json->>'timestamp')     AS mid,
  json->'message'->>'model'                                                     AS model,
  COALESCE((json->'message'->'usage'->>'output_tokens')::BIGINT, 0)             AS out_tokens,
  COALESCE((json->'message'->'usage'->'output_tokens_details'->>'thinking_tokens')::BIGINT, 0) AS think_tokens,
  COALESCE((json->'message'->'usage'->>'cache_creation_input_tokens')::BIGINT, 0) AS cache_write,
  COALESCE((json->'message'->'usage'->>'cache_read_input_tokens')::BIGINT, 0)  AS cache_read,
  COALESCE((json->'message'->'usage'->>'input_tokens')::BIGINT, 0)              AS uncached,
  -- tool_use block ids of this record (one content block per record, but stay generic):
  -- zip (type, id), keep the id where the type is tool_use → VARCHAR[] (named type, table-safe)
  list_filter(
    list_transform(
      list_zip(from_json(json_extract(json, '$.message.content[*].type'), '["VARCHAR"]'),
               from_json(json_extract(json, '$.message.content[*].id'),   '["VARCHAR"]')),
      lambda p: CASE WHEN p[1] = 'tool_use' THEN p[2] END),
    lambda x: x IS NOT NULL)                                                     AS tool_ids
FROM read_ndjson_objects(getvariable('transcript'), ignore_errors = true)
WHERE json->>'type' = 'assistant'
  AND (json->>'timestamp')::TIMESTAMPTZ >= getvariable('since')::TIMESTAMPTZ
  AND (getvariable('until') IS NULL OR (json->>'timestamp')::TIMESTAMPTZ <= getvariable('until')::TIMESTAMPTZ);

-- one row per API message
CREATE OR REPLACE TEMP TABLE _msg AS
SELECT mid, MIN(ts) AS ts, any_value(model) AS model,
       MAX(out_tokens) AS out_tokens, MAX(think_tokens) AS think_tokens,
       MAX(cache_write) AS cache_write, MAX(cache_read) AS cache_read, MAX(uncached) AS uncached,
       len(list_distinct(flatten(list(tool_ids)))) AS tool_calls
FROM _rec GROUP BY mid;

CREATE OR REPLACE TEMP TABLE _marks AS
SELECT trim(split_part(m, '=', 1)) AS phase, trim(split_part(m, '=', 2))::TIMESTAMPTZ AS t0
FROM (SELECT unnest(string_split(COALESCE(getvariable('marks'), ''), ',')) AS m)
WHERE m LIKE '%=%';

CREATE OR REPLACE TEMP MACRO _dur(sec) AS
  CASE WHEN sec >= 3600 THEN format('{}h {:02d}min {:02d}s', sec // 3600, (sec % 3600) // 60, sec % 60)
       ELSE format('{}min {:02d}s', sec // 60, sec % 60) END;

-- #1 window
SELECT strftime(getvariable('since')::TIMESTAMPTZ, '%Y-%m-%d %H:%M:%S') || 'Z → '
       || strftime(COALESCE(getvariable('until')::TIMESTAMPTZ, (SELECT MAX(ts) FROM _rec)), '%H:%M:%S') || 'Z' AS window,
       _dur(CAST(date_diff('second', getvariable('since')::TIMESTAMPTZ,
                      COALESCE(getvariable('until')::TIMESTAMPTZ, (SELECT MAX(ts) FROM _rec))) AS INTEGER)) AS wall_clock,
       (SELECT string_agg(DISTINCT model, ', ') FROM _msg) AS model,
       regexp_extract(getvariable('transcript'), '[^/]+$') AS transcript;

-- #2 totals
SELECT 'API calls / tool calls' AS metric, COUNT(*) || ' / ' || SUM(tool_calls) AS value FROM _msg
UNION ALL SELECT 'Output tokens (of which thinking)', format('{:,} ({:,})', SUM(out_tokens), SUM(think_tokens)) FROM _msg
UNION ALL SELECT 'Cache writes (new context: scripts, profiles, signals, tests)', format('{:,}', SUM(cache_write)) FROM _msg
UNION ALL SELECT 'Cache reads (context re-use across calls)', format('{:,}', SUM(cache_read)) FROM _msg
UNION ALL SELECT 'Uncached input', format('{:,}', SUM(uncached)) FROM _msg
UNION ALL SELECT '**Fresh content** (output + cache writes + uncached)', format('**{:,}**', SUM(out_tokens + cache_write + uncached)) FROM _msg
UNION ALL SELECT 'Total processed (incl. cache reads)', format('{:,}', SUM(out_tokens + cache_write + cache_read + uncached)) FROM _msg;

-- #3 per phase (empty without marks)
WITH b AS (
  SELECT phase, t0,
         COALESCE(LEAD(t0) OVER (ORDER BY t0),
                  COALESCE(getvariable('until')::TIMESTAMPTZ, (SELECT MAX(ts) FROM _rec))) AS t1
  FROM _marks
)
SELECT b.phase,
       strftime(b.t0, '%H:%M:%S') || ' → ' || strftime(b.t1, '%H:%M:%S') AS window,
       _dur(CAST(date_diff('second', b.t0, b.t1) AS INTEGER)) AS wall_clock,
       COUNT(m.mid) AS api_calls,
       format('{:,}', COALESCE(SUM(m.out_tokens), 0)) AS output,
       format('{:,}', COALESCE(SUM(m.cache_write), 0)) AS cache_writes,
       format('{:,}', COALESCE(SUM(m.cache_read), 0)) AS cache_reads
FROM b LEFT JOIN _msg m ON m.ts >= b.t0 AND m.ts < b.t1
GROUP BY b.phase, b.t0, b.t1
ORDER BY b.t0;
