import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import { formatKpiValue } from './_format';
import { dispatchAction } from '../actions';
import { isActionActive } from '../actionState';
import { translateCellValue } from './_cellTranslate';
import { badgeToneClass } from './_badgeTone';
import type { ActionSpec } from '../actions';
import type { KpiItem } from './KPI';

export function KPIStrip({ node, row, dataset, navigate }: PrimitiveProps) {
  const { t, i18n } = useTranslation(['common', 'dashboard']);
  const items = (node.props?.items as KpiItem[]) ?? [];
  const [searchParams] = useSearchParams();

  // Trägt der Strip eine EIGENE Dataset-Bindung (node.data.dataset, z.B. die
  // Home-„Cluster"-Bubble mit `cluster_count`), nutzt er dessen erste Zeile als
  // Werte-Row. Ohne eigene Bindung ist `dataset` das vom Container vererbte
  // Dataset → identische Row wie `row` (kein Verhaltenswechsel der bestehenden
  // Strips). Dispatch/Active bleiben an der Container-`row`.
  const valueRow = (node.data?.dataset ? dataset?.data?.[0] : undefined) ?? row;

  return (
    <div className="dash-kpistrip">
      {items.map((item, i) => {
        const rawValue = valueRow?.[item.field];
        const isBadge = item.format === 'badge';
        // Badges often carry canonical categorical strings — translate them
        // the same way Table cells do so KPI strips stay consistent.
        const value = isBadge ? translateCellValue(rawValue, t) : rawValue;
        const formatted = formatKpiValue(value, item.format, i18n.language);
        const click: ActionSpec | undefined = item.onClick;
        const clickable = !!click;
        const active = clickable ? isActionActive(click, row, searchParams) : false;
        const badgeClass = isBadge ? ` dash-kpi__value--badge ${badgeToneClass(rawValue, item.badgeTone)}` : '';
        // Result-state colour for a plain value (see KpiItem.tone). With
        // `toneWhen: 'nonzero'` a zero stays neutral, so the colour appears
        // exactly when the KPI has something to report. Non-numeric values
        // count as present.
        const toneActive = item.tone
          && (item.toneWhen !== 'nonzero' || (rawValue != null && Number(rawValue) !== 0));
        const toneClass = toneActive ? ` dash-state-${item.tone}` : '';
        const cls = [
          'dash-kpi',
          clickable ? 'dash-kpi--clickable' : '',
          active ? 'dash-kpi--active' : '',
        ].filter(Boolean).join(' ');
        return (
          <button
            key={`${item.label}-${i}`}
            type="button"
            className={cls}
            onClick={clickable ? () => dispatchAction(click, row, { navigate }) : undefined}
            disabled={!clickable}
            aria-pressed={active}
          >
            <span className="dash-kpi__label">{item.label}</span>
            <span className={`dash-kpi__value${badgeClass}${toneClass}`}>{formatted}</span>
          </button>
        );
      })}
    </div>
  );
}
