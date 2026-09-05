import { useEffect, useState } from 'react';
import { API_BASE } from '../config/apiBase';

/**
 * Lädt das zentrale Versions-Manifest (`GET /api/version-manifest`) — das
 * modul-granulare version.json. Einmaliger Fetch, modulweit gecached (das
 * Manifest ändert sich pro Session nicht). Wirft nie nach außen: bei
 * Fehler/Offline bleibt `manifest` null und der Versions-Balken rendert nichts
 * (kein harter Fehler).
 *
 * Hinweis: bewusst `/api/version-manifest`, NICHT `/api/version` — letzteres ist
 * der Health-/Feature-Endpoint (Plugin-Flags, Erreichbarkeit).
 */

export type VersionComponent = {
  scheme: string;
  version: string | null;
  /** Internal engine version next to the display version (xml_import:
   *  CONVERTER_VERSION) — present since manifests carry engine_source. */
  engine_version?: string | null;
  source: string;
  on_change: string;
  filemaker_coverage?: string | null;
};

export type VersionManifest = {
  manifest_schema: string;
  version: string;
  generated_at: string;
  source_commit: string | null;
  components: Record<string, VersionComponent>;
  plugins: { name: string; version: string; on_change: string }[];
  skills: { name: string; version: string | null }[];
  engine_baseline: { duckdb_min: string | null; webbed_min: string | null } | null;
};

type ApiEnvelope<T> = { success: boolean; data: T; error?: { message: string } };

// Modulweiter Cache: einmal laden, danach synchron wiederverwenden.
let cachedManifest: VersionManifest | null = null;
let inFlight: Promise<VersionManifest | null> | null = null;

async function fetchManifest(): Promise<VersionManifest | null> {
  if (cachedManifest) return cachedManifest;
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      const res = await fetch(`${API_BASE}/api/version-manifest`);
      if (!res.ok) return null;
      const json: ApiEnvelope<VersionManifest> = await res.json();
      if (!json.success || !json.data) return null;
      cachedManifest = json.data;
      return cachedManifest;
    } catch {
      return null;
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

export function useVersionManifest(): VersionManifest | null {
  const [manifest, setManifest] = useState<VersionManifest | null>(cachedManifest);

  useEffect(() => {
    if (manifest) return;
    let cancelled = false;
    fetchManifest().then((m) => {
      if (!cancelled && m) setManifest(m);
    });
    return () => {
      cancelled = true;
    };
  }, [manifest]);

  return manifest;
}
