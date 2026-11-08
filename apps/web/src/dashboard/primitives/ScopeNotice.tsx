import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useLocation, useNavigate } from 'react-router-dom';
import { api } from '../../api/client';
import type { PrimitiveProps } from '../types';
import { deriveScope, withoutScope } from './_scopeNotice';
import type { ScopeOptions } from './_scopeNotice';

/**
 * ScopeNotice — visible scope hint of a dashboard page.
 *
 * When the URL narrows the page to a scope — `file` and/or `scope_uuids`, as an
 * Analysis Test passes them to its member dashboards — the KPIs and lists count
 * only that scope. The notice names it ("File: Adressen · Object: Markiert
 * (Table occurrence)", or the number of objects for a list or a cluster) and
 * offers to show the whole solution again.
 *
 * DashboardHost places it automatically above the layout of every content
 * dashboard — only for the params the dashboard applies (`analysis.scope` /
 * declared `file` param), so it never names a filter the counts ignore. A layout
 * can place it itself (`{ "type": "ScopeNotice" }`), then the host adds none.
 * Props of the primitive:
 *   hideFile   true = leave the file out (the layout shows it in its own control)
 */
export function ScopeNotice({ node }: PrimitiveProps) {
  return <ScopeNoticeBar options={{ fileShownByControl: node.props?.hideFile === true }} />;
}

interface ObjectLabel {
  name: string;
  type: string;
}

export function ScopeNoticeBar({ options = {} }: { options?: ScopeOptions }) {
  const { t } = useTranslation(['dashboard', 'types']);
  const location = useLocation();
  const navigate = useNavigate();
  const scope = deriveScope(new URLSearchParams(location.search), options);
  const single = scope && scope.uuids.length === 1 ? scope.uuids[0] : null;
  // The file of the URL qualifies the object (clones share UUIDs), also when the
  // notice does not show it.
  const lookupFile = new URLSearchParams(location.search).get('file') || undefined;
  const [label, setLabel] = useState<ObjectLabel | null>(null);

  useEffect(() => {
    setLabel(null);
    if (!single) return;
    let alive = true;
    api.get({ uuid: single, file: lookupFile })
      .then((res) => {
        const obj = res.data as { Object_Name?: string; Object_Type?: string } | undefined;
        if (alive && obj?.Object_Name) setLabel({ name: obj.Object_Name, type: obj.Object_Type ?? '' });
      })
      .catch(() => { /* the notice falls back to the count */ });
    return () => { alive = false; };
  }, [single, lookupFile]);

  if (!scope) return null;

  const parts: string[] = [];
  if (scope.file) parts.push(t('dashboard:scope.file', { file: scope.file }));
  if (label) {
    const type = label.type ? t(`types:objectTypes.${label.type}`, { defaultValue: label.type }) : '';
    parts.push(type
      ? t('dashboard:scope.objectTyped', { name: label.name, type })
      : t('dashboard:scope.object', { name: label.name }));
  } else if (scope.uuids.length > 0) {
    parts.push(t('dashboard:scope.objects', { count: scope.uuids.length }));
  }

  const clear = () => {
    const qs = withoutScope(location.search);
    navigate({ pathname: location.pathname, search: qs ? `?${qs}` : '' });
  };

  return (
    <div className="dash-scope-notice" role="note" title={t('dashboard:scope.hint')}>
      <span className="dash-scope-notice__label">{t('dashboard:scope.label')}</span>
      <span className="dash-scope-notice__parts">{parts.join(' · ')}</span>
      <button type="button" className="dash-scope-notice__clear" onClick={clear}
        title={t('dashboard:scope.clearTitle')}>
        {t('dashboard:scope.clear')}
      </button>
    </div>
  );
}
