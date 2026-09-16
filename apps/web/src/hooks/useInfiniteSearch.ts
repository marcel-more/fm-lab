import { useState, useEffect, useCallback, useRef } from 'react';
import { api } from '../api/client';
import { useApiLang } from './useApiLang';
import { isConnectionError } from '../lib/netErrors';
import type { components } from '@packages/shared/types';

type FMObject = components['schemas']['FMObject'];

const CHUNK_SIZE = 100;

/**
 * Sentinel-Fehlercode für „REST-API nicht erreichbar". Wird vom Hook gesetzt
 * und in der UI (App.tsx) in eine übersetzte Hinweis-Meldung übersetzt, statt
 * einen kryptischen Laufzeitfehler (z. B. „undefined is not an object …") oder
 * die rohe Fetch-Fehlermeldung anzuzeigen.
 *
 * Zweite Ausprägung neben dem Transport-TypeError (lib/netErrors.ts): Läuft der
 * Request über den Vite-Dev-Proxy, das Backend ist aber down, liefert der Proxy
 * 5xx mit leerem Body; openapi-fetch gibt dann eine `undefined`-Response zurück
 * (siehe Aufrufer-Guards unten).
 */
export const CONNECTION_ERROR = '__NO_CONNECTION__';

interface UseInfiniteSearchOptions {
  searchName: string;
  selectedFile: string;
  objectType: string;
}

interface UseInfiniteSearchResult {
  items: FMObject[];
  loading: boolean;
  loadingMore: boolean;
  hasMore: boolean;
  totalCount: number | null;
  error: string | null;
  loadMore: () => Promise<void>;
  reset: () => void;
}

/**
 * Infinite Search Hook
 * Manages infinite scrolling with offset-based pagination
 *
 * Features:
 * - Auto-loads initial data
 * - Loads more data in chunks (100 items)
 * - Prevents duplicate requests
 * - Tracks total count
 * - Resets when search params change
 *
 * @example
 * const { items, loading, hasMore, loadMore } = useInfiniteSearch({
 *   searchName: '%',
 *   selectedFile: 'MyFile',
 *   objectType: 'Script'
 * });
 */
export const useInfiniteSearch = ({
  searchName,
  selectedFile,
  objectType,
}: UseInfiniteSearchOptions): UseInfiniteSearchResult => {
  const [items, setItems] = useState<FMObject[]>([]);
  const [offset, setOffset] = useState(0);
  const [totalCount, setTotalCount] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Prevent duplicate requests
  const isFetchingRef = useRef(false);

  // Generation-Counter: jeder Reset (synchron im Render oder via useEffect)
  // bumpt diesen Wert. In-flight Fetches (reset oder loadMore) vergleichen
  // nach ihrem await gegen den aktuellen Stand und verwerfen ihre Response,
  // wenn sich die Parameter inzwischen geändert haben. Verhindert, dass ein
  // vor dem Filterwechsel gestarteter loadMore-Chunk nachträglich an die neue
  // Trefferliste angehängt wird ("Fragmente" unterhalb von "All loaded").
  const requestGenerationRef = useRef(0);

  // Synchrone Param-Detection im Render. Wenn der Parent mit neuen Filter-
  // Werten rendert, leeren wir items/Counter im SELBEN Render — bevor das
  // Commit die alte Liste mit der neuen Filter-UI ans DOM bringt. Ohne das
  // bleibt zwischen Render und useEffect-Callback ein Frame, in dem die alte
  // (oft sehr lange) Liste sichtbar ist und der Virtualizer seinen Range
  // basierend auf der alten Gesamthöhe rendert — sichtbar als "Fragmente".
  // Pattern: "Adjusting state when a prop changes" (React-Docs).
  const [lastParams, setLastParams] = useState({ searchName, selectedFile, objectType });
  if (
    lastParams.searchName !== searchName ||
    lastParams.selectedFile !== selectedFile ||
    lastParams.objectType !== objectType
  ) {
    setLastParams({ searchName, selectedFile, objectType });
    setItems([]);
    setOffset(0);
    setTotalCount(null);
    setLoading(true);
    setLoadingMore(false);
    setError(null);
    isFetchingRef.current = false;
    requestGenerationRef.current++;
  }

  // Aktive UI-Sprache: die Trefferliste zeigt bei Built-ins die lokalisierte
  // Fassung neben dem kanonischen Namen (Localized_Name).
  const lang = useApiLang();

  // Build search params (normalize to API format)
  const buildSearchParams = useCallback((withOffset: number = 0) => {
    // Wildcard-Mapping: * → % (SQL-Wildcard)
    let pattern = searchName.trim().replace(/\*/g, '%');

    // Wenn Pattern keine Wildcards enthält, füge sie automatisch hinzu
    if (!pattern.includes('%')) {
      pattern = `%${pattern}%`;
    }

    return {
      name: pattern,
      file: selectedFile || undefined,
      type: objectType as any || undefined,
      limit: CHUNK_SIZE,
      offset: withOffset,
      lang,
    };
  }, [searchName, selectedFile, objectType, lang]);

  /**
   * Reset and load initial data
   */
  const reset = useCallback(async () => {
    // Generation bumpen → eventuell in-flight loadMore-Calls werden ihre
    // Response nach dem await verwerfen.
    const generation = ++requestGenerationRef.current;

    // Reset state
    setItems([]);
    setOffset(0);
    setTotalCount(null);
    setError(null);
    setLoading(true);
    setLoadingMore(false);
    isFetchingRef.current = false;

    try {
      const searchParams = buildSearchParams(0);

      // Parallel requests: search + count
      const [searchResponse, countResponse] = await Promise.all([
        api.search(searchParams),
        api.searchCount({
          name: searchParams.name,
          file: searchParams.file,
          type: searchParams.type,
        }),
      ]);

      if (generation !== requestGenerationRef.current) return;

      // Verbindungsfall: Steht das Backend nicht (direkter Fetch lehnt ab) oder
      // liefert der Dev-Proxy eine 5xx-Antwort mit leerem Body, gibt der
      // API-Client `undefined` zurück. Ohne diesen Guard würde `searchResponse.success`
      // den kryptischen „undefined is not an object"-Fehler werfen.
      if (!searchResponse || !countResponse) {
        setError(CONNECTION_ERROR);
        setTotalCount(null);
        return;
      }

      if (searchResponse.success && searchResponse.data) {
        const items = Array.isArray(searchResponse.data) ? searchResponse.data : [];
        setItems(items);
        setOffset(CHUNK_SIZE);
      } else {
        setError('Search failed');
      }

      // Extract total count
      if (countResponse.success && countResponse.data) {
        const countData = Array.isArray(countResponse.data)
          ? countResponse.data
          : [countResponse.data];
        if (countData.length > 0 && 'count' in countData[0]) {
          setTotalCount(countData[0].count as number);
        } else {
          setTotalCount(null);
        }
      } else {
        setTotalCount(null);
      }
    } catch (err) {
      if (generation !== requestGenerationRef.current) return;
      console.error('Search failed:', err);
      setError(
        isConnectionError(err)
          ? CONNECTION_ERROR
          : err instanceof Error ? err.message : 'Search failed'
      );
    } finally {
      if (generation === requestGenerationRef.current) {
        setLoading(false);
      }
    }
  }, [buildSearchParams]);

  /**
   * Load more items (next chunk)
   */
  const loadMore = useCallback(async () => {
    // Guard clauses
    if (isFetchingRef.current || loadingMore || loading) {
      return;
    }

    if (totalCount !== null && items.length >= totalCount) {
      return; // No more items to load
    }

    // Generation merken — kommt vor dem await ein reset() dazwischen, wird
    // unsere Response verworfen statt an die neue Liste angehängt zu werden.
    const generation = requestGenerationRef.current;
    isFetchingRef.current = true;
    setLoadingMore(true);
    setError(null);

    try {
      const searchParams = buildSearchParams(offset);

      const response = await api.search(searchParams);

      if (generation !== requestGenerationRef.current) return;

      if (!response) {
        setError(CONNECTION_ERROR);
        return;
      }

      if (response.success && response.data) {
        const newItems = Array.isArray(response.data) ? response.data : [];
        setItems((prev) => [...prev, ...newItems]);
        setOffset((prev) => prev + CHUNK_SIZE);
      } else {
        setError('Loading failed');
      }
    } catch (err) {
      if (generation !== requestGenerationRef.current) return;
      console.error('Load more failed:', err);
      setError(
        isConnectionError(err)
          ? CONNECTION_ERROR
          : err instanceof Error ? err.message : 'Failed to load'
      );
    } finally {
      if (generation === requestGenerationRef.current) {
        isFetchingRef.current = false;
        setLoadingMore(false);
      }
    }
  }, [buildSearchParams, offset, items.length, totalCount, loadingMore, loading]);

  /**
   * Reset when search params change
   */
  useEffect(() => {
    reset();
  }, [reset]);

  const hasMore = totalCount !== null && items.length < totalCount;

  return {
    items,
    loading,
    loadingMore,
    hasMore,
    totalCount,
    error,
    loadMore,
    reset,
  };
};
