import { useCallback, useEffect, useState } from 'react';
import { API_BASE } from '../config/apiBase';
import { useApiLang } from '../hooks/useApiLang';

/**
 * Script-Trigger-Event-Beschriftung.
 *
 * Kanonische Event-Namen (`OnRecordLoad`) werden über die kuratierte
 * fm_spec-Referenz (`/api/reference/trigger-events`, fm_spec ≥ 1.18.0) in die
 * Dialog-Beschriftung der aktiven Sprache übersetzt („BeiDatensatzLaden") und
 * anschließend Camel-Case-gesplittet („Bei Datensatz Laden"). Graceful auf
 * allen Stufen: ohne Referenz-DB, bei älterem Stand oder unbekanntem Event
 * bleibt der kanonische Name (humanisiert) stehen.
 */

/**
 * Camel-Case → lesbare Beschriftung: "OnRecordLoad" → "On Record Load",
 * "BeiObjektÄndern" → "Bei Objekt Ändern". Unicode-bewusst (Umlaute u.a.
 * zählen als Großbuchstaben-Grenze); Schriften ohne Bikameralität
 * (ja/ko/zh-Beschriftungen) passieren unverändert.
 */
export function humanizeTriggerEvent(name: string): string {
  return name.replace(/([\p{Ll}\p{Nd}])(\p{Lu})/gu, '$1 $2');
}

type EventLabels = Record<string, string>;

// Modul-weiter Cache pro Referenz-Sprache; In-flight-Dedup über `pending`.
const labelCache = new Map<string, EventLabels>();
const pending = new Map<string, Promise<EventLabels>>();

async function fetchLabels(lang: string): Promise<EventLabels> {
  try {
    const r = await fetch(`${API_BASE}/api/reference/trigger-events?lang=${encodeURIComponent(lang)}`);
    const json = await r.json();
    if (r.ok && json?.success && json.data?.labels) return json.data.labels as EventLabels;
  } catch {
    // Netz-/Serverfehler → leerer Satz, kanonischer Fallback greift.
  }
  return {};
}

function loadLabels(lang: string): Promise<EventLabels> {
  const cached = labelCache.get(lang);
  if (cached) return Promise.resolve(cached);
  let p = pending.get(lang);
  if (!p) {
    p = fetchLabels(lang).then(labels => {
      labelCache.set(lang, labels);
      pending.delete(lang);
      return labels;
    });
    pending.set(lang, p);
  }
  return p;
}

/**
 * Liefert einen Formatter `action → lokalisierte, humanisierte Beschriftung`.
 * Bis die Label-Map der aktiven Sprache geladen ist (ein Request pro Sprache,
 * modul-gecacht), formatiert er den kanonischen Namen — kein Layout-Sprung,
 * nur Text-Upgrade. Referenz-stabil via useCallback (memo-tauglich).
 */
export function useTriggerEventFormat(): (action: string) => string {
  const lang = useApiLang();
  const [labels, setLabels] = useState<EventLabels | undefined>(() => labelCache.get(lang));
  useEffect(() => {
    let alive = true;
    const cached = labelCache.get(lang);
    if (cached) {
      setLabels(cached);
      return undefined;
    }
    loadLabels(lang).then(m => { if (alive) setLabels(m); });
    return () => { alive = false; };
  }, [lang]);
  return useCallback(
    (action: string) => humanizeTriggerEvent(labels?.[action] ?? action),
    [labels],
  );
}

// ---------------------------------------------------------------------------
// Trigger compatibility (fm_spec ≥ 2.8.0, `trigger_compat` via
// /api/reference/triggers). Tri-state like step_compat: true = Yes, false =
// No, null = PARTIAL (conditionally supported — never "undocumented").
// Language-independent, one request per page load (module cache), graceful:
// an older reference / a down server yields an EMPTY map — consumers then
// show no platform line at all instead of guessing.
// ---------------------------------------------------------------------------

export type TriggerCompat = Record<'pro' | 'server' | 'go' | 'webdirect' | 'cloud' | 'dataapi' | 'cwp', boolean | null>;
type CompatMap = Map<number, TriggerCompat>;

let compatCache: CompatMap | undefined;
let compatPending: Promise<CompatMap> | undefined;

async function fetchCompat(): Promise<CompatMap> {
  const map: CompatMap = new Map();
  try {
    const r = await fetch(`${API_BASE}/api/reference/triggers?lang=en`);
    const json = await r.json();
    if (r.ok && json?.success && Array.isArray(json.data)) {
      for (const t of json.data as { triggerId: number; compat: TriggerCompat | null }[]) {
        if (t.compat) map.set(t.triggerId, t.compat);
      }
    }
  } catch {
    // network/server error → empty map, no platform line
  }
  return map;
}

function loadCompat(): Promise<CompatMap> {
  if (compatCache) return Promise.resolve(compatCache);
  if (!compatPending) {
    compatPending = fetchCompat().then((m) => { compatCache = m; compatPending = undefined; return m; });
  }
  return compatPending;
}

/**
 * Compat lookup `triggerId → TriggerCompat | null`. Returns `null` for every
 * id until loaded and for ids without a compat row (older reference) — the
 * callers render nothing in that case.
 */
export function useTriggerCompat(): (triggerId: number | null | undefined) => TriggerCompat | null {
  const [map, setMap] = useState<CompatMap | undefined>(() => compatCache);
  useEffect(() => {
    let alive = true;
    if (compatCache) { setMap(compatCache); return undefined; }
    loadCompat().then((m) => { if (alive) setMap(m); });
    return () => { alive = false; };
  }, []);
  return useCallback(
    (triggerId: number | null | undefined) => (triggerId == null ? null : (map?.get(triggerId) ?? null)),
    [map],
  );
}
