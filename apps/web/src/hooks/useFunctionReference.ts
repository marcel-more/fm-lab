import { useEffect, useState } from 'react';
import { fetchFunctionDetail, resolveFunctionLang, type FunctionDetail } from '../api/fmSpecApi';

// Session-scoped cache pro (function_id, Referenz-Sprache). `null` cached einen
// erfolglosen Lookup mit — ohne ihn würde jeder Besuch derselben Funktion den
// fehlschlagenden Call wiederholen.
const cache = new Map<string, FunctionDetail | null>();

/**
 * Referenz-Schicht einer Built-in-Funktion aus `fm_spec` (Kategorie,
 * Rückgabetyp, Ursprungs-Version, Claris-Doku-Seite / Online-Hilfe).
 *
 * `functionId === null` heißt: der Katalog-Knoten trägt keine Identität
 * (BuiltinFunctionIdentity) — z. B. JSON-Typkonstanten wie `JSONString`, die
 * die Referenz gar nicht als Funktion kennt. Dann wird nicht gefragt.
 *
 * Eine nicht angehängte oder zu alte Referenz degradiert auf `data = null`
 * statt auf einen Fehler: die Katalog-Fakten der Detailseite bleiben ohne die
 * Referenz-Schicht vollständig lesbar, nur die Zusatz-Metadaten und die
 * Querlinks entfallen.
 */
export function useFunctionReference(
  functionId: number | null | undefined,
  uiLang: string,
): { data: FunctionDetail | null; loading: boolean } {
  const fnLang = resolveFunctionLang(uiLang);
  const key = functionId != null ? `${functionId}::${fnLang}` : null;
  const [data, setData] = useState<FunctionDetail | null>(() => (key ? cache.get(key) ?? null : null));
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!key || functionId == null) {
      setData(null);
      setLoading(false);
      return;
    }
    if (cache.has(key)) {
      setData(cache.get(key) ?? null);
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    // `content: 'none'` — die Detailseite zeigt die Hilfe-Seite nicht ein,
    // sie verlinkt sie nur; das gerenderte Hilfe-HTML wäre reiner Ballast.
    fetchFunctionDetail(functionId, fnLang, { content: 'none' })
      .then((d) => {
        cache.set(key, d);
        if (!cancelled) { setData(d); setLoading(false); }
      })
      .catch(() => {
        cache.set(key, null);
        if (!cancelled) { setData(null); setLoading(false); }
      });
    return () => { cancelled = true; };
  }, [key, functionId, fnLang]);

  return { data, loading };
}
