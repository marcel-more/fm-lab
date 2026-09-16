import React from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { components } from '@packages/shared/types';
import { Slot } from '../plugins';
import { buildObjectPath } from '../lib/navigation';
import { formatObjectDisplayName } from '../lib/objectName';

type FMObject = components['schemas']['FMObject'];

// Optionale Pseudo-Token-Felder,
// vom /api/list-Endpoint mit ?with_usage=true / ?with_category=true geliefert.
// Da der generierte FMObject-Typ diese Spalten nicht kennt, indizieren wir
// lose über das ursprüngliche Object.
type FMObjectWithAggregates = FMObject & {
  usage_count?: number;
  category?: string | null;
  category_id?: number | null;
  is_get_subparam?: boolean;
};

interface ObjectListItemProps {
  object: FMObject;
  style?: React.CSSProperties;
  // Klon-Disambiguierung: `file` ist die Zieldatei (File_Name des angeklickten
  // Objekts), die als `?file=` mitwandert. Optional → Graceful Downgrade.
  onClick?: (uuid: string, file?: string | null) => void;
  // Wenn gesetzt, klick auf die Category-Pille toggelt diesen Wert in der
  // übergeordneten Filter-Toolbar.
  onCategoryClick?: (category: string) => void;
  // Aktueller Volltext-Suchbegriff (vor Wildcard-Expansion). Wird für das
  // Highlighting des Treffers im Step_Text bei ScriptStep-Ergebnissen benutzt.
  searchTerm?: string;
}

/**
 * Hebt das erste Vorkommen von `term` (case-insensitive) im Text hervor.
 * Wildcards (`*`, `%`) werden vor dem Match entfernt; ein leerer Rest liefert
 * den unveränderten Text. Verwendet React-Fragmente statt dangerouslySetInnerHTML,
 * damit React den restlichen Text weiterhin escapen kann.
 */
function highlightMatch(text: string, term?: string): React.ReactNode {
  if (!term) return text;
  const clean = term.replace(/[*%]/g, '').trim();
  if (!clean) return text;
  const lower = text.toLowerCase();
  const needle = clean.toLowerCase();
  const idx = lower.indexOf(needle);
  if (idx < 0) return text;
  return (
    <>
      {text.slice(0, idx)}
      <mark className="search-hit">{text.slice(idx, idx + needle.length)}</mark>
      {text.slice(idx + needle.length)}
    </>
  );
}

/**
 * Object List Item Component
 * Renders a single FileMaker object in the virtual list.
 * Plugins contribute quick-actions via the `objectListItemActions` slot.
 *
 * ScriptStep-Spezialfall: Wenn `object.Step_Text` gesetzt ist, wird der
 * Klartext der Skriptzeile groß gerendert; darunter ein Breadcrumb mit
 * "Datei ▸ Skript ▸ Step N" (1-basiert wie im FileMaker-Editor).
 */
export const ObjectListItem: React.FC<ObjectListItemProps> = ({ object, style, onClick, onCategoryClick, searchTerm }) => {
  const { t } = useTranslation(['detail', 'common', 'types']);
  const navigate = useNavigate();
  const aggObject = object as FMObjectWithAggregates;
  const noName = t('detail:objectListItem.noName') as string;
  const handleClick = () => {
    onClick?.(object.Object_UUID, object.File_Name ?? null);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleClick();
    }
  };

  const hasUsage = typeof aggObject.usage_count === 'number';
  const hasCategory = aggObject.category != null && aggObject.category !== '';
  const isScriptStep = object.Object_Type === 'ScriptStep' && typeof object.Step_Text === 'string' && object.Step_Text.length > 0;
  // Treffer, der NICHT über den Objektnamen kam, wird unter dem Namen
  // ausgewiesen (analog zum Step-Text bei ScriptSteps):
  //   • ValueList      — die passenden hinterlegten Custom-Values
  //   • BuiltinFunction — die lokalisierte Schreibweise, über die gefunden
  //     wurde. Ein Built-in steht im Katalog unter seinem kanonischen
  //     englischen Namen; wer 'Seitennummer' sucht, landet auf
  //     'Get(PageNumber)' und soll sehen, warum.
  const matchedValues = (object.Object_Type === 'ValueList' || object.Object_Type === 'BuiltinFunction')
    && typeof object.Matched_Values === 'string' && object.Matched_Values.length > 0
    ? object.Matched_Values
    : null;
  // Lokalisierte Namensfassung eines Built-ins (nur mit ?lang= und nur, wenn
  // sie vom kanonischen Namen abweicht). Der kanonische Name bleibt der Titel —
  // er ist die Identität des Objekts.
  const localizedName = object.Object_Type === 'BuiltinFunction'
    && typeof object.Localized_Name === 'string' && object.Localized_Name.length > 0
    ? object.Localized_Name
    : null;

  return (
    <div style={style} className="object-list-item-wrapper">
      <div
        className="object-list-item"
        onClick={handleClick}
        onKeyDown={handleKeyDown}
        tabIndex={0}
        role="button"
        aria-label={t('detail:objectListItem.showAria', {
          type: object.Object_Type,
          name: (isScriptStep ? object.Step_Text : formatObjectDisplayName(object.Object_Type, object.Object_Name)) || noName,
        }) as string}
      >
        <div className="object-header">
          {isScriptStep ? (
            <code className="object-name object-steptext" title={object.Step_Text || ''}>
              {highlightMatch(object.Step_Text as string, searchTerm)}
            </code>
          ) : (
            <strong
              className="object-name"
              title={localizedName
                ? `${object.Object_Name} · ${localizedName}`
                : (object.Object_Name || undefined)}
            >
              {formatObjectDisplayName(object.Object_Type, object.Object_Name) || noName}
              {localizedName && (
                <span className="object-name-localized"> · {localizedName}</span>
              )}
            </strong>
          )}
          {hasCategory && (
            <span
              className="object-category-pill"
              role={onCategoryClick ? 'button' : undefined}
              tabIndex={onCategoryClick ? 0 : -1}
              onClick={(e) => {
                if (!onCategoryClick) return;
                e.stopPropagation();
                onCategoryClick(aggObject.category as string);
              }}
              onKeyDown={(e) => {
                if (!onCategoryClick) return;
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  e.stopPropagation();
                  onCategoryClick(aggObject.category as string);
                }
              }}
              title={onCategoryClick
                ? (t('detail:objectListItem.filterByCategory', { category: aggObject.category }) as string)
                : (aggObject.category as string)}
            >
              {aggObject.category}
            </span>
          )}
          {hasUsage && (
            <span
              className="object-usage-badge object-usage-badge--clickable"
              role="button"
              tabIndex={0}
              title={t('detail:objectListItem.usageBadge', { count: aggObject.usage_count }) as string}
              onClick={(e) => {
                // Direkt in den References-Tab springen — die Pille zählt
                // ja gerade die Verwendungen, da soll der User landen, nicht
                // im default-Detail-Tab. stopPropagation, weil der Row-Click
                // (parent) zum default-Tab navigiert.
                e.stopPropagation();
                navigate(buildObjectPath(object.Object_UUID, null, object.File_Name ?? null, { tab: 'references' }));
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  e.stopPropagation();
                  navigate(buildObjectPath(object.Object_UUID, null, object.File_Name ?? null, { tab: 'references' }));
                }
              }}
            >
              {aggObject.usage_count}
            </span>
          )}
          <Slot
            name="objectListItemActions"
            objectUuid={object.Object_UUID}
            objectType={object.Object_Type}
            objectName={object.Object_Name || ''}
            fileName={object.File_Name || ''}
          />
          {/* Typ-Pille → mit `object-name { flex:1 }` rechtsbündig, unabhängig von
              Category-Pille/Usage-Badge/Slot. */}
          <span className="object-type">
            {t(`types:objectTypes.${object.Object_Type}`, { defaultValue: object.Object_Type })}
          </span>
          {/* TableOccurrence: Direkt-Sprung ins Beziehungsdiagramm der Datei, mit
              dieser TO vorselektiert (`?to=<UUID>`). stopPropagation, weil der
              Row-Click sonst zusätzlich in die DetailView navigieren würde. */}
          {object.Object_Type === 'TableOccurrence' && object.File_Name && (
            <Link
              to={`/relationship-graph/${encodeURIComponent(object.File_Name)}?to=${encodeURIComponent(object.Object_UUID)}`}
              className="object-rg-link"
              title={t('common:actions.showInRelationshipGraph') as string}
              onClick={(e) => e.stopPropagation()}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') e.stopPropagation();
              }}
            >
              {t('detail:objectListItem.graphButton')}
            </Link>
          )}
        </div>
        {isScriptStep ? (
          <div className="object-details object-step-breadcrumb">
            <small>
              {object.File_Name && (
                <span className="breadcrumb-segment breadcrumb-file">{object.File_Name}</span>
              )}
              {object.File_Name && object.Script_Name && (
                <span className="breadcrumb-separator" aria-hidden="true">▸</span>
              )}
              {object.Script_Name && (
                <span className="breadcrumb-segment breadcrumb-script">{object.Script_Name}</span>
              )}
              {typeof object.Step_Index === 'number' && (
                <>
                  <span className="breadcrumb-separator" aria-hidden="true">▸</span>
                  <span className="breadcrumb-segment breadcrumb-stepindex">
                    Step {object.Step_Index + 1}
                  </span>
                </>
              )}
            </small>
          </div>
        ) : (
          (object.File_Name || matchedValues) && (
            <div className="object-details">
              {matchedValues && (
                <small className="object-value-match" title={matchedValues}>
                  <span className="value-match-label">
                    {object.Object_Type === 'BuiltinFunction'
                      ? t('detail:objectListItem.spellingMatch', { defaultValue: 'Spelling' })
                      : t('detail:objectListItem.valueListMatch')}:
                  </span>{' '}
                  {highlightMatch(matchedValues, searchTerm)}
                </small>
              )}
              {object.File_Name && <small>{object.File_Name}</small>}
            </div>
          )
        )}
      </div>
    </div>
  );
};
