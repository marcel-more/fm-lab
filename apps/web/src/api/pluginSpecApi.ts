import { API_BASE } from '../config/apiBase';
import type { DocsCategoryRef, DocsEntryRef } from './docsApi';

/**
 * Plugin-Spec API client (`/api/plugin-spec/*`).
 *
 * Read-only access to the plug-in platform map (reference/plugin_spec.duckdb,
 * derived from the vendor docs mirror). Plain fetch like the rest of the
 * frontend. Consumers must degrade silently: 503 = map not installed,
 * 404 = function unknown — both mean "no platform statement", never an error.
 */

const API = `${API_BASE}/api`;

type Envelope<T> = { success: boolean; data: T; error?: { message?: string } };

export interface PluginFunctionPlatform {
  platform: string;
  supported: boolean;
  qualifier: string | null;
}

export interface PluginFunctionSpec {
  plugin_id: string;
  plugin_name: string;
  function_name: string;
  alias: string | null;
  alias_kind: string | null;
  component: string | null;
  since_version: string | null;
  status: 'active' | 'deprecated' | 'removed';
  status_note: string | null;
  /** Documented successor from the deprecation note (may name a component). */
  replacement: string | null;
  /** Plugin release that removed the function (status 'removed' only). */
  removed_in: string | null;
  doc_version: string | null;
  platforms: PluginFunctionPlatform[];
  /**
   * Seite dieser Funktion im Doku-Browser. Server-seitig null, wenn das
   * Hersteller-Docset nicht installiert ist oder die Funktion nicht mehr im
   * Doku-Index steht (entfernte Funktionen) — dann bleibt `online_url`.
   */
  docsEntry?: DocsEntryRef | null;
  /**
   * Herstellerseite der Funktion, aus dem Namen abgeleitet und damit auch ohne
   * installiertes Docset verfügbar. Fehlt nur bei unbekannter Doku-Quelle.
   */
  online_url?: string | null;
}

/**
 * Referenz-Schicht einer Plugin-KOMPONENTE: ihre Größe laut Hersteller-Map und
 * die beiden Doku-Querlinks (Rubrikseite im installierten Docset, sonst die
 * Rubrikseite des Herstellers).
 */
export interface PluginComponentSpec {
  plugin_id: string;
  plugin_name: string;
  component: string;
  doc_version: string | null;
  /**
   * Komponentenname beim Hersteller — null, wenn weder der Katalogname noch
   * die mitgegebene Mitglieds-Funktion in der Map stehen. Dann bleiben auch
   * beide Doku-Links leer.
   */
  vendor_component: string | null;
  /** Wie viele Funktionen der Hersteller in dieser Komponente führt. */
  documented_functions: number;
  docsCategory?: DocsCategoryRef | null;
  online_url?: string | null;
}

/** Returns null when no statement exists (map missing or component unknown). */
export async function fetchPluginComponentSpec(
  prefix: string,
  component: string,
  /**
   * Name einer Mitglieds-Funktion. Der Katalog-Komponentenname ist der
   * Funktions-Namenspräfix ('GMImage') und deckt sich nicht immer mit der
   * Komponente des Herstellers ('GraphicsMagick') — über eine Mitglieds-Funktion
   * löst der Server den echten Namen auf.
   */
  viaFunction?: string | null,
): Promise<PluginComponentSpec | null> {
  const q = viaFunction ? `?fn=${encodeURIComponent(viaFunction)}` : '';
  const url = `${API}/plugin-spec/components/${encodeURIComponent(prefix)}/${encodeURIComponent(component)}${q}`;
  try {
    const r = await fetch(url);
    if (r.status === 404 || r.status === 503) return null;
    const json: Envelope<PluginComponentSpec> = await r.json();
    if (!r.ok || !json.success) return null;
    return json.data;
  } catch {
    return null;
  }
}

/** Returns null when no statement exists (map missing or function unknown). */
export async function fetchPluginFunctionSpec(
  prefix: string,
  name: string,
): Promise<PluginFunctionSpec | null> {
  const url = `${API}/plugin-spec/functions/${encodeURIComponent(prefix)}/${encodeURIComponent(name)}`;
  try {
    const r = await fetch(url);
    if (r.status === 404 || r.status === 503) return null;
    const json: Envelope<PluginFunctionSpec> = await r.json();
    if (!r.ok || !json.success) return null;
    return json.data;
  } catch {
    return null;
  }
}
