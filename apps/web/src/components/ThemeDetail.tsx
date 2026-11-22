import React, { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useThemeStyleLayouts } from '../hooks/useThemeStyleLayouts';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildObjectPath } from '../lib/navigation';
import {
  buildThemeModel,
  cutLayouts,
  filterStyles,
  LAYOUT_PREVIEW,
  styleCounts,
  tokenKey,
  type StyleFilter,
  type ThemeStyleRow,
} from '../lib/themeDetail';
import { DisclosureChevron } from './DisclosureChevron';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './FieldViewer.css';
import './BaseTableViewer.css';
import './ThemeDetail.css';

const FILTERS: readonly StyleFilter[] = ['all', 'used', 'unused'];

interface StyleLayoutsProps {
  themeUuid: string;
  file: string;
  style: ThemeStyleRow;
}

/**
 * Layouts of one expanded style, loaded on expand. Most objects first; above
 * LAYOUT_PREVIEW layouts a search field appears and the rest waits behind
 * "show all" — a style on hundreds of layouts stays a short list. A layout opens
 * in the canvas filtered by the style (`style=<class>`).
 */
const StyleLayouts: React.FC<StyleLayoutsProps> = ({ themeUuid, file, style }) => {
  const { t } = useTranslation(['detail', 'common']);
  const { status, layouts, retry } = useThemeStyleLayouts(themeUuid, file, style.style_class);
  const [query, setQuery] = useState('');
  const [showAll, setShowAll] = useState(false);

  if (status === 'loading') {
    return <div className="fm-td-layouts-status">{t('detail:themeDetail.layoutsLoading')}</div>;
  }
  if (status === 'error') {
    return (
      <div className="fm-td-layouts-status">
        {t('detail:themeDetail.layoutsError')}{' '}
        <button type="button" className="fm-td-more" onClick={retry}>{t('detail:themeDetail.retry')}</button>
      </div>
    );
  }
  const long = layouts.length > LAYOUT_PREVIEW;
  const cut = cutLayouts(layouts, query, showAll);
  return (
    <div className="fm-td-layouts-wrap">
      {long && (
        <input
          type="search"
          className="fm-bt-search fm-td-layout-search"
          value={query}
          onChange={e => setQuery(e.target.value)}
          placeholder={t('detail:themeDetail.layoutSearchPlaceholder', { n: layouts.length }) as string}
          aria-label={t('detail:themeDetail.layoutSearchPlaceholder', { n: layouts.length }) as string}
        />
      )}
      {cut.matched === 0 ? (
        <div className="fm-td-layouts-status">{t('detail:themeDetail.noLayoutMatch')}</div>
      ) : (
        <ul className="fm-td-layouts">
          {cut.shown.map(l => (
            <li key={l.layout_uuid}>
              <Link
                className="fm-field-link"
                to={buildObjectPath(l.layout_uuid, null, file, { style: style.style_class })}
                title={t('detail:themeDetail.showInLayoutTitle') as string}
              >
                {l.layout_name ?? l.layout_uuid}
              </Link>
              <span className="fm-td-layout-count">
                {t('detail:themeDetail.objectsValue', { count: l.objects })}
              </span>
            </li>
          ))}
        </ul>
      )}
      {cut.hidden > 0 && (
        <button type="button" className="fm-td-more" onClick={() => setShowAll(true)}>
          {t('detail:themeDetail.showAllLayouts', { n: cut.matched, hidden: cut.hidden })}
        </button>
      )}
      {showAll && long && cut.matched > LAYOUT_PREVIEW && (
        <button type="button" className="fm-td-more" onClick={() => setShowAll(false)}>
          {t('detail:themeDetail.showFewerLayouts', { n: LAYOUT_PREVIEW })}
        </button>
      )}
    </div>
  );
};

interface StyleTableProps {
  styles: ThemeStyleRow[];
  themeUuid: string;
  file: string;
}

/**
 * Style list of one group (custom or built-in): name, object types, objects,
 * layouts. A used style expands into its layouts (StyleLayouts, loaded then).
 */
const StyleTable: React.FC<StyleTableProps> = ({ styles, themeUuid, file }) => {
  const { t } = useTranslation(['detail']);
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const toggle = (cls: string) => setOpen(prev => {
    const next = new Set(prev);
    if (next.has(cls)) next.delete(cls); else next.add(cls);
    return next;
  });
  const tokenLabel = (token: string): string => {
    const key = tokenKey(token);
    return key ? (t(key, { defaultValue: token }) as string) : token;
  };

  return (
    <table className="fm-bt-table fm-td-table">
      <thead>
        <tr>
          <th className="fm-td-col-toggle" aria-hidden="true" />
          <th>{t('detail:themeDetail.colName')}</th>
          <th>{t('detail:themeDetail.colType')}</th>
          <th className="fm-td-num">{t('detail:themeDetail.colObjects')}</th>
          <th className="fm-td-num">{t('detail:themeDetail.colLayouts')}</th>
        </tr>
      </thead>
      <tbody>
        {styles.map(s => {
          const used = s.objects > 0;
          const isOpen = used && open.has(s.style_class);
          const types = (s.type_tokens ?? []).map(tokenLabel).join(', ');
          return (
            <React.Fragment key={s.style_class}>
              <tr className={'fm-td-row' + (used ? '' : ' is-unused')}>
                <td className="fm-td-col-toggle">
                  {used && (
                    <button
                      type="button"
                      className="fm-td-toggle"
                      aria-expanded={isOpen}
                      aria-label={t('detail:themeDetail.showLayouts', { name: s.style_display || s.style_class }) as string}
                      onClick={() => toggle(s.style_class)}
                    >
                      <DisclosureChevron open={isOpen} />
                    </button>
                  )}
                </td>
                <td className="fm-td-name" title={s.style_class}>
                  {used ? (
                    <button type="button" className="fm-td-name-btn" onClick={() => toggle(s.style_class)}>
                      {s.style_display || s.style_class}
                    </button>
                  ) : (
                    s.style_display || s.style_class
                  )}
                </td>
                <td className="fm-td-types">{types || '—'}</td>
                <td className="fm-td-num">{s.objects}</td>
                <td className="fm-td-num">
                  {used ? s.layouts : <span className="fm-td-unused-badge">{t('detail:themeDetail.unused')}</span>}
                </td>
              </tr>
              {isOpen && (
                <tr className="fm-td-layouts-row">
                  <td />
                  <td colSpan={4}>
                    <StyleLayouts themeUuid={themeUuid} file={file} style={s} />
                  </td>
                </tr>
              )}
            </React.Fragment>
          );
        })}
      </tbody>
    </table>
  );
};

interface ThemeDetailProps {
  uuid: string;
}

/**
 * Detail view of a theme (design): properties (kind, base theme, internal name,
 * default theme, version/language/platform, layouts, style counts) and the
 * theme's named styles — custom styles with filter (all / used / unused) and
 * name search, built-in styles collapsed below. Header attributes and styles
 * need schema 1.46.0 (`meta.theme_styles.available`); older catalogs show the
 * properties of the base columns plus a re-import notice.
 */
export const ThemeDetail: React.FC<ThemeDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common']);
  const currentFile = useCurrentFile();
  const { data, meta: resMeta, loading, error, retry } = useObjectDetails(uuid, currentFile);
  const model = useMemo(() => buildThemeModel(data), [data]);
  const [filter, setFilter] = useState<StyleFilter>('all');
  const [query, setQuery] = useState('');
  const [builtinOpen, setBuiltinOpen] = useState(false);

  const visibleCustom = useMemo(() => filterStyles(model.custom, filter, query), [model.custom, filter, query]);
  const visibleBuiltin = useMemo(() => filterStyles(model.builtin, filter, query), [model.builtin, filter, query]);
  const counts = useMemo(() => styleCounts(model.custom, query), [model.custom, query]);
  const builtinCounts = useMemo(() => styleCounts(model.builtin, query), [model.builtin, query]);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  const meta = model.meta;
  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const avail = (resMeta?.theme_styles as { available?: boolean } | undefined)?.available;
  const stylesAvailable = avail !== false;
  const h = model.header;
  const file = meta.file_name;
  const name = meta.display_name || meta.internal_name || meta.theme_uuid;

  const kind = h
    ? (h.is_custom_theme
      ? (t('detail:themeDetail.kindCustom') as string)
      : (t('detail:themeDetail.kindBuiltin', { group: h.theme_group ?? '' }) as string))
    : null;
  const base = h?.base_name ? (
    <>
      {' · '}{t('detail:themeDetail.basePrefix')}{' '}
      {h.base_uuid ? (
        <Link className="fm-field-link" to={buildObjectPath(h.base_uuid, uuid, file)} title={h.base_name}>
          {h.base_display || h.base_name}
        </Link>
      ) : (
        <code>{h.base_name}</code>
      )}
      {h.base_version && ` (v${h.base_version})`}
    </>
  ) : null;
  const facts = h ? [
    h.theme_version ? t('detail:themeDetail.versionValue', { value: h.theme_version }) : null,
    h.theme_locale ? t('detail:themeDetail.localeValue', { value: h.theme_locale }) : null,
    h.theme_platform ? t('detail:themeDetail.platformValue', { value: h.theme_platform }) : null,
  ].filter(Boolean).join(' · ') : '';
  const customCount = h?.custom_count ?? model.custom.length;
  const customUsed = h?.custom_used ?? 0;
  const builtinCount = h?.builtin_count ?? model.builtin.length;
  const hasNamed = !!h?.has_named_styles;

  return (
    <div className="fm-customfunction fm-field fm-td" aria-label={t('detail:themeDetail.ariaLabel') as string}>
      <div className="fm-customfunction-header">
        <h2 className="type-detail-heading">{name}</h2>
        <span className="fm-customfunction-meta">{file}</span>
      </div>

      <div className="fm-field-sections">
        <section className="fm-field-section">
          <h3 className="fm-field-section-title">{t('detail:themeDetail.groupProperties')}</h3>
          <dl className="fm-field-props">
            <dt>{t('detail:themeDetail.name')}</dt>
            <dd>{name}</dd>
            {kind && (
              <>
                <dt>{t('detail:themeDetail.kind')}</dt>
                <dd>{kind}{base}</dd>
              </>
            )}
            {meta.internal_name && (
              <>
                <dt>{t('detail:themeDetail.internalName')}</dt>
                <dd><code className="fm-td-code">{meta.internal_name}</code></dd>
              </>
            )}
            {h?.is_default && (
              <>
                <dt>{t('detail:themeDetail.defaultTheme')}</dt>
                <dd>{t('detail:themeDetail.defaultThemeValue')}</dd>
              </>
            )}
            {facts && (
              <>
                <dt>{t('detail:themeDetail.versionLocalePlatform')}</dt>
                <dd title={t('detail:themeDetail.platformTitle') as string}>{facts}</dd>
              </>
            )}
            <dt>{t('detail:themeDetail.layouts')}</dt>
            <dd>
              <Link
                className="fm-field-link"
                to={buildObjectPath(meta.theme_uuid, null, file, { tab: 'references' })}
                title={t('detail:themeDetail.layoutsShowInReferences') as string}
              >
                {meta.layout_count ?? 0}
              </Link>
            </dd>
            {h && hasNamed && (
              <>
                <dt>{t('detail:themeDetail.styles')}</dt>
                <dd>
                  {t('detail:themeDetail.stylesValue', {
                    custom: customCount,
                    used: customUsed,
                    unused: customCount - customUsed,
                    builtin: builtinCount,
                  })}
                </dd>
              </>
            )}
          </dl>
        </section>

        {!stylesAvailable ? (
          <div className="fm-td-notice" role="note">{t('detail:themeDetail.catalogOutdated')}</div>
        ) : h && !hasNamed ? (
          <section className="fm-field-section">
            <h3 className="fm-field-section-title">{t('detail:themeDetail.groupStyles')}</h3>
            <div className="fm-td-notice" role="note">{t('detail:themeDetail.noNamedStyles')}</div>
          </section>
        ) : h ? (
          <section className="fm-field-section">
            <h3 className="fm-field-section-title">
              {t('detail:themeDetail.groupStylesCount', { n: customCount })}
            </h3>
            <div className="fm-td-toolbar">
              <div className="fm-bt-chips" role="group" aria-label={t('detail:themeDetail.filterLabel') as string}>
                {FILTERS.map(f => (
                  <button
                    key={f}
                    type="button"
                    className={`fm-bt-chip${filter === f ? ' fm-bt-chip--active' : ''}`}
                    aria-pressed={filter === f}
                    onClick={() => setFilter(f)}
                  >
                    {t(`detail:themeDetail.filter.${f}`)} <span className="fm-bt-chip-count">({counts[f]})</span>
                  </button>
                ))}
              </div>
              <input
                type="search"
                className="fm-bt-search fm-td-search"
                value={query}
                onChange={e => setQuery(e.target.value)}
                placeholder={t('detail:themeDetail.searchPlaceholder') as string}
                aria-label={t('detail:themeDetail.searchPlaceholder') as string}
              />
            </div>

            {customCount === 0 ? (
              <div className="fm-td-empty">{t('detail:themeDetail.noCustomStyles')}</div>
            ) : visibleCustom.length === 0 ? (
              <div className="fm-td-empty">{t('detail:themeDetail.noMatch')}</div>
            ) : (
              <StyleTable styles={visibleCustom} themeUuid={meta.theme_uuid} file={file} />
            )}

            {model.builtin.length > 0 && (
              <div className="fm-td-builtin">
                <button
                  type="button"
                  className="fm-td-builtin-toggle"
                  aria-expanded={builtinOpen}
                  onClick={() => setBuiltinOpen(o => !o)}
                >
                  <DisclosureChevron open={builtinOpen} />
                  {t('detail:themeDetail.builtinStyles', { count: builtinCounts[filter] })}
                </button>
                {builtinOpen && (
                  visibleBuiltin.length === 0
                    ? <div className="fm-td-empty">{t('detail:themeDetail.noMatch')}</div>
                    : <StyleTable styles={visibleBuiltin} themeUuid={meta.theme_uuid} file={file} />
                )}
              </div>
            )}
          </section>
        ) : null}
      </div>
    </div>
  );
};
