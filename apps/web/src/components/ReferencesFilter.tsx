import { useMemo, useRef, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';

type Props = {
  typeCounts: Map<string, number>;
  activeTypes: Set<string>;
  onToggleType: (type: string) => void;
  onClearTypes: () => void;
  /**
   * Kombinierte Rollen-Chips: Key = `<Link_Role>` bzw. `<Link_Role>~<Subrole_Class>`
   * (Tilde-Separator, spiegelt den `roles=`-URL-Param). Die Reihe erscheint nur,
   * wenn mehr als ein Chip existiert — sonst filtert sie nichts.
   */
  roleCounts: Map<string, number>;
  activeRoles: Set<string>;
  onToggleRole: (roleKey: string) => void;
  onClearRoles: () => void;
  /** Kurzlabel-Resolver für Slot-Klassen (eine Label-Quelle mit der Liste). */
  subroleShort: (cls: string, role?: string) => string;
  query: string;
  onQueryChange: (value: string) => void;
  matchCount: number;
  totalCount: number;
  onJumpToList?: (direction: 'first' | 'last') => void;
  /** Abschlusszeile unter Pillen und Chips (z.B. „Nicht referenziert“). */
  footer?: ReactNode;
};

/**
 * Toolbar oberhalb der Referenz-Liste. Suchfeld + Typ-Filter-Pillen
 * orientieren sich am Verhalten von LayoutTypeFilter und
 * RelationshipGraph-Suche: ESC leert die Eingabe; Pillen sind
 * Mehrfachauswahl mit OR-Verknüpfung.
 */
export function ReferencesFilter({
  typeCounts,
  activeTypes,
  onToggleType,
  onClearTypes,
  roleCounts,
  activeRoles,
  onToggleRole,
  onClearRoles,
  subroleShort,
  query,
  onQueryChange,
  matchCount,
  totalCount,
  onJumpToList,
  footer,
}: Props) {
  const { t, i18n } = useTranslation(['detail']);
  const inputRef = useRef<HTMLInputElement>(null);

  // Sort by count descending, then alphabetically — the most frequent type
  // ends up on the left and is the quickest to reach.
  const sortedTypes = useMemo(() => {
    return Array.from(typeCounts.entries())
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], i18n.language));
  }, [typeCounts, i18n.language]);

  // Rollen-Chips: gleiche Ordnung wie die Typ-Pillen. Das Chip-Label spiegelt
  // 1:1 die Zeilen-Anzeige (`reads_field · CF`).
  const sortedRoles = useMemo(() => {
    return Array.from(roleCounts.entries())
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], i18n.language));
  }, [roleCounts, i18n.language]);

  const roleChipLabel = (roleKey: string): string => {
    const tildeAt = roleKey.indexOf('~');
    if (tildeAt < 0) return roleKey;
    const role = roleKey.slice(0, tildeAt);
    return `${role} · ${subroleShort(roleKey.slice(tildeAt + 1), role)}`;
  };

  const hasAnyActive = activeTypes.size > 0;
  const hasAnyActiveRole = activeRoles.size > 0;
  const filterActive = hasAnyActive || hasAnyActiveRole || query !== '';

  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    // ESC bewusst NICHT lokal abfangen — der globale ESC-Stack auf View-Ebene
    // (siehe useEscapeStack in DetailView) regelt die Stufenlogik
    // (Suchfeld leeren → Filter leeren → Zurück).
    if (e.key === 'ArrowDown' && onJumpToList) {
      e.preventDefault();
      onJumpToList('first');
    } else if (e.key === 'ArrowUp' && onJumpToList) {
      e.preventDefault();
      onJumpToList('last');
    }
  };

  return (
    <div className="references-filter">
      <div className="references-filter-search">
        <input
          ref={inputRef}
          type="search"
          placeholder={t('detail:referencesFilter.searchPlaceholder') as string}
          value={query}
          onChange={e => onQueryChange(e.target.value)}
          onKeyDown={onKeyDown}
          title={t('detail:referencesFilter.searchTitle') as string}
          aria-label={t('detail:referencesFilter.searchAria') as string}
        />
        {filterActive && (
          <span className="references-filter-count">
            {matchCount} / {totalCount}
          </span>
        )}
      </div>
      {sortedTypes.length > 0 && (
        <div className="references-filter-pills">
          {sortedTypes.map(([type, count]) => {
            const active = activeTypes.has(type);
            return (
              <button
                key={type}
                type="button"
                className={`references-filter-pill${active ? ' active' : ''}`}
                onClick={() => onToggleType(type)}
                title={`${type} (${count})`}
              >
                {type}
                <span className="references-filter-pill-count">({count})</span>
              </button>
            );
          })}
          {hasAnyActive && (
            <button
              type="button"
              className="references-filter-link"
              onClick={onClearTypes}
              title={t('detail:referencesFilter.clearTypesTitle') as string}
            >
              {t('detail:referencesFilter.clearTypesLabel')}
            </button>
          )}
        </div>
      )}
      {sortedRoles.length > 1 && (
        <div
          className="references-filter-pills references-filter-roles"
          role="group"
          aria-label={t('detail:referencesFilter.rolesAria', { defaultValue: 'Nach Link-Rolle filtern' }) as string}
        >
          {sortedRoles.map(([roleKey, count]) => {
            const active = activeRoles.has(roleKey);
            const label = roleChipLabel(roleKey);
            return (
              <button
                key={roleKey}
                type="button"
                className={`references-filter-pill${active ? ' active' : ''}`}
                onClick={() => onToggleRole(roleKey)}
                title={`${label} (${count})`}
              >
                {label}
                <span className="references-filter-pill-count">({count})</span>
              </button>
            );
          })}
          {hasAnyActiveRole && (
            <button
              type="button"
              className="references-filter-link"
              onClick={onClearRoles}
              title={t('detail:referencesFilter.clearRolesTitle', { defaultValue: 'Alle Rollen-Filter aufheben' }) as string}
            >
              {t('detail:referencesFilter.clearRolesLabel', { defaultValue: 'Rollen zurücksetzen' })}
            </button>
          )}
        </div>
      )}
      {footer}
    </div>
  );
}
