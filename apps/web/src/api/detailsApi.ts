import { API_BASE } from '../config/apiBase';
// Details API - Fetch wrapper for /api/get-details endpoint
// Uses the REST API template dispatcher to get type-specific object details.

const baseUrl = API_BASE;

export interface ObjectDetailsMeta {
  execution_time_ms?: number;
  result_count?: number;
  template_type?: string;
  object_type?: string;
  object_name?: string;
  file_name?: string;
  template_used?: string;
  has_dedicated_template?: boolean;
  [key: string]: unknown;
}

export interface ObjectDetailsResponse {
  success: boolean;
  data: Array<Record<string, unknown>>;
  meta?: ObjectDetailsMeta;
}

/**
 * Fetch type-specific object details via /api/get-details.
 * The API automatically dispatches to the correct SQL template based on Object_Type.
 *
 * `file` (Klon-Disambiguierung): optionaler File_Name, der zusammen mit der UUID
 * das Objekt eindeutig auflöst (geteilte Klon-UUIDs). Fehlt er, gilt Graceful
 * Downgrade (bare UUID, solange eindeutig; sonst 409 AMBIGUOUS_UUID).
 */
export async function fetchObjectDetails(
  uuid: string,
  file?: string | null,
  lang?: string | null,
): Promise<ObjectDetailsResponse> {
  const searchParams = new URLSearchParams({
    uuid,
    format: 'json',
    meta: 'true',
  });
  if (file) searchParams.set('file', file);
  // Aktive UI-Sprache: Detail-Templates zeigen damit die lokalisierte
  // Schreibweise neben dem Katalognamen. Betrifft heute BuiltinFunction, dessen
  // Katalogname sprachunabhängig der kanonische englische Referenzname ist;
  // andere Typen ignorieren den Parameter.
  if (lang) searchParams.set('lang', lang);

  const response = await fetch(`${baseUrl}/api/get-details?${searchParams}`);

  if (!response.ok) {
    const errorData = await response.json().catch(() => null);
    throw new Error(
      errorData?.error?.message || `Details request failed: ${response.status}`
    );
  }

  return response.json();
}
