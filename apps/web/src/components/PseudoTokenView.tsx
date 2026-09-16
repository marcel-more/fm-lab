import { API_BASE } from '../config/apiBase';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { components } from '@packages/shared/types';
import {
  PSEUDO_TYPE_DRILLDOWN,
} from '@packages/shared/constants';
import {
  PseudoTokenFilterToolbar,
  type CategoryEntry,
  type SortMode,
} from './PseudoTokenFilterToolbar';
import { ObjectListItem } from './ObjectListItem';
import { useApiLang } from '../hooks/useApiLang';

export interface PseudoTokenDrilldown {
  type: string;
  via: 'category';
  value: string;
}

type FMObject = components['schemas']['FMObject'];
type AggObject = FMObject & {
  usage_count?: number;
  category?: string | null;
  category_id?: number | null;
};

/**
 * PseudoTokenView — Listenansicht für Pseudo-Token-Typen mit Aggregations-Layer.
 *
 * Lädt /api/list mit ?with_usage / ?with_category / ?category / ?sort und
 * /api/list/categories für die Filter-Pillen. Für PluginComponent entfällt
 * die Filter-Toolbar — es ist selbst die Category-Ebene.
 */

const PSEUDO_TOKEN_TYPES = new Set<string>(['ScriptStepType', 'BuiltinFunction', 'PluginFunction']);

interface Props {
  objectType: string;
  file?: string;
  onItemClick: (uuid: string) => void;
  /**
   * Optionaler Drilldown-Handler für Pseudo-Typen, die laut
   * PSEUDO_TYPE_DRILLDOWN eine Hierarchie über einem anderen Typ bilden
   * (z.B. PluginComponent → PluginFunction). Wird bei Item-Klick statt
   * onItemClick aufgerufen, sofern ein Drilldown-Mapping existiert.
   */
  onDrilldown?: (drilldown: PseudoTokenDrilldown) => void;
  initialCategory?: string;
  initialSort?: SortMode;
  onUrlStateChange?: (state: { category?: string; sort?: SortMode }) => void;
}

async function fetchList(params: URLSearchParams) {
  const url = `${API_BASE}/api/list?${params.toString()}`;
  const res = await fetch(url);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`/api/list ${res.status}: ${text}`);
  }
  return res.json();
}

async function fetchCategories(type: string, file: string | undefined) {
  const params = new URLSearchParams({ type: type.toLowerCase() });
  if (file) params.set('file', file);
  const url = `${API_BASE}/api/list/categories?${params.toString()}`;
  const res = await fetch(url);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`/api/list/categories ${res.status}: ${text}`);
  }
  return res.json();
}

export const PseudoTokenView: React.FC<Props> = ({
  objectType,
  file,
  onItemClick,
  onDrilldown,
  initialCategory,
  initialSort,
  onUrlStateChange,
}) => {
  const { t } = useTranslation(['types', 'nav']);
  const isTokenType = PSEUDO_TOKEN_TYPES.has(objectType);
  const isComponentType = objectType === 'PluginComponent';

  const [items, setItems] = useState<AggObject[]>([]);
  const [categories, setCategories] = useState<CategoryEntry[]>([]);
  const [activeCategories, setActiveCategories] = useState<string[]>(
    initialCategory ? initialCategory.split(',').filter(Boolean) : []
  );
  const [sort, setSort] = useState<SortMode>(initialSort || 'usage');
  const [searchText, setSearchText] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // URL-State melden (für ?category= und ?sort=)
  useEffect(() => {
    onUrlStateChange?.({
      category: activeCategories.length > 0 ? activeCategories.join(',') : undefined,
      sort,
    });
  }, [activeCategories, sort, onUrlStateChange]);

  // Reset wenn der Typ wechselt. Category/Sort werden aus den initial-Props
  // re-hydratisiert, damit ein Drilldown-Wechsel (z.B. PluginComponent →
  // PluginFunction mit category=<Component>) die URL-Vorgaben übernehmen kann.
  // initialCategory/initialSort bewusst NICHT in den deps — sonst würde der
  // Effekt während eines aktiven Type-Kontexts den User-Filter überschreiben.
  useEffect(() => {
    setItems([]);
    setActiveCategories(
      initialCategory ? initialCategory.split(',').filter(Boolean) : []
    );
    setSearchText('');
    setSort(initialSort || 'usage');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [objectType]);

  // Categories laden (nur für Token-Typen)
  useEffect(() => {
    if (!isTokenType) {
      setCategories([]);
      return;
    }
    let cancelled = false;
    fetchCategories(objectType, file)
      .then((r) => {
        if (!cancelled) setCategories(r.data || []);
      })
      .catch((e) => {
        if (!cancelled) console.error('PseudoTokenView categories error:', e.message);
      });
    return () => {
      cancelled = true;
    };
  }, [objectType, file, isTokenType]);

  const lang = useApiLang();

  // Liste laden — bei Pseudo-Typen mit Aggregations
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    const params = new URLSearchParams({
      type: objectType.toLowerCase(),
      limit: '500',
      sort,
    });
    if (file) params.set('file', file);
    // Aktive UI-Sprache: Built-ins liefern damit ihre lokalisierte Namensfassung
    // mit (Localized_Name) — die Liste zeigt denselben Namen wie Detailseite
    // und Trefferliste.
    if (lang) params.set('lang', lang);

    if (isTokenType || isComponentType) {
      params.set('with_usage', 'true');
    }
    if (isTokenType) {
      params.set('with_category', 'true');
      if (activeCategories.length > 0) {
        params.set('category', activeCategories.join(','));
      }
    }

    fetchList(params)
      .then((r) => {
        if (!cancelled) setItems(r.data || []);
      })
      .catch((e) => {
        if (!cancelled) setError(e.message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [objectType, file, sort, activeCategories, isTokenType, isComponentType, lang]);

  // Clientseitiges Filtern nach searchText
  const filteredItems = useMemo(() => {
    if (!searchText.trim()) return items;
    const lower = searchText.toLowerCase();
    // Auch über die lokalisierte Fassung filtern: in einer deutschen Lösung
    // tippt man 'Seitennummer', nicht 'PageNumber'.
    return items.filter((it) =>
      (it.Object_Name || '').toLowerCase().includes(lower)
      || String((it as Record<string, unknown>).Localized_Name ?? '').toLowerCase().includes(lower));
  }, [items, searchText]);

  const handleToggleCategory = (cat: string) => {
    setActiveCategories((prev) =>
      prev.includes(cat) ? prev.filter((c) => c !== cat) : [...prev, cat]
    );
  };

  const handleClearCategories = () => {
    setActiveCategories([]);
  };

  // Bei Pseudo-Typen mit Drilldown-Hierarchie (z.B. PluginComponent →
  // PluginFunction) leiten wir den Klick auf onDrilldown um — der User
  // erwartet die enthaltenen Kinder im selben Filter-Kontext, nicht die
  // DetailView des Container-Objekts. Default: DetailView öffnen.
  const drilldown = PSEUDO_TYPE_DRILLDOWN[objectType as keyof typeof PSEUDO_TYPE_DRILLDOWN];
  const handleItemClickInternal = useCallback((uuid: string) => {
    if (drilldown && onDrilldown) {
      const item = items.find((it) => it.Object_UUID === uuid);
      if (item && item.Object_Name) {
        const value = drilldown.mapValue ? drilldown.mapValue(item.Object_Name) : item.Object_Name;
        onDrilldown({ type: drilldown.type, via: drilldown.via, value });
        return;
      }
    }
    onItemClick(uuid);
  }, [drilldown, onDrilldown, items, onItemClick]);

  const handleListItemCategoryClick = (cat: string) => {
    // Toggling-Verhalten: Klick auf Pille im Listenelement aktiviert sie.
    setActiveCategories((prev) => (prev.includes(cat) ? prev : [...prev, cat]));
    // Scroll nach oben — Konvention
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const fallbackCategoryLabel = t('types:categoryHeader.ScriptStepType', { defaultValue: 'Category' });
  const categoryLabel = isTokenType
    ? t(`types:categoryHeader.${objectType}`, { defaultValue: fallbackCategoryLabel })
    : fallbackCategoryLabel;

  return (
    <div className="pseudo-token-view">
      {isTokenType && (
        <PseudoTokenFilterToolbar
          categories={categories}
          activeCategories={activeCategories}
          onToggleCategory={handleToggleCategory}
          onClearCategories={handleClearCategories}
          sort={sort}
          onSortChange={setSort}
          searchText={searchText}
          onSearchTextChange={setSearchText}
          filteredCount={filteredItems.length}
          totalCount={items.length}
          categoryLabel={categoryLabel}
        />
      )}

      {isComponentType && (
        <div className="pseudo-token-toolbar pseudo-token-toolbar-component">
          <div className="pseudo-token-toolbar-row1">
            <div className="pseudo-token-toolbar-search">
              <label htmlFor="pseudo-token-search-input">{t('nav:pseudoToolbar.searchLabel', { ns: 'nav' })}</label>
              <input
                id="pseudo-token-search-input"
                type="text"
                value={searchText}
                onChange={(e) => setSearchText(e.target.value)}
                placeholder={t('nav:pseudoToolbar.searchPlaceholder', { ns: 'nav' }) as string}
              />
              <span className="pseudo-token-count">
                {filteredItems.length} / {items.length}
              </span>
            </div>
            <div className="pseudo-token-toolbar-sort">
              <label htmlFor="pseudo-token-sort-select">{t('nav:pseudoToolbar.sortLabel', { ns: 'nav' })}</label>
              <select
                id="pseudo-token-sort-select"
                value={sort}
                onChange={(e) => setSort(e.target.value as SortMode)}
              >
                <option value="usage">{t('nav:pseudoToolbar.sortByUsage', { ns: 'nav' })}</option>
                <option value="name">{t('nav:pseudoToolbar.sortByName', { ns: 'nav' })}</option>
              </select>
            </div>
          </div>
        </div>
      )}

      {loading && items.length === 0 && (
        <div className="virtual-list-empty">{t('nav:list.loadingTokens', { ns: 'nav' })}</div>
      )}

      {error && (
        <div className="error-message">{error}</div>
      )}

      {!loading && filteredItems.length === 0 && !error && (
        <div className="virtual-list-empty">Keine Tokens gefunden.</div>
      )}

      <div className="pseudo-token-list">
        {filteredItems.map((obj) => (
          <ObjectListItem
            key={obj.Object_UUID}
            object={obj}
            onClick={handleItemClickInternal}
            onCategoryClick={isTokenType ? handleListItemCategoryClick : undefined}
          />
        ))}
      </div>
    </div>
  );
};
