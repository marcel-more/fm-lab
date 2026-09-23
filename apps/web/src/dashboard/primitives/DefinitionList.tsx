import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import { formatKpiValue } from './_format';
import { translateCellValue } from './_cellTranslate';
import { badgeToneClass } from './_badgeTone';
import type { KpiItem } from './KPI';

/**
 * Compact "Label | Value" list — a definition list rendered from a single data
 * row. Same item shape as KPIStrip ({ label, field, format }), but rendered as
 * rows instead of tiles, for settings-style detail panels (e.g. the file view's
 * "Dateiinfo" options). Labels come from the layout (translated via the bundle
 * locale path keys); badge-formatted values are translated the same way as Table
 * / KPIStrip cells (dashboard:cellValues), so booleans stay multilingual.
 *
 * Like KPIStrip: with an own `node.data.dataset` binding it uses that dataset's
 * first row, otherwise the container-inherited `row`.
 */
export function DefinitionList({ node, row, dataset }: PrimitiveProps) {
  const { t, i18n } = useTranslation(['common', 'dashboard']);
  const items = (node.props?.items as KpiItem[]) ?? [];
  const valueRow = (node.data?.dataset ? dataset?.data?.[0] : undefined) ?? row;

  return (
    <dl className="dash-deflist">
      {items.map((item, i) => {
        const rawValue = valueRow?.[item.field];
        const isBadge = item.format === 'badge';
        const value = isBadge ? translateCellValue(rawValue, t) : rawValue;
        const formatted = formatKpiValue(value, item.format, i18n.language);
        const badgeClass = isBadge
          ? ` dash-badge ${badgeToneClass(rawValue, item.badgeTone)}`
          : '';
        return (
          <div className="dash-deflist__row" key={`${item.label}-${i}`}>
            <dt className="dash-deflist__label">{item.label}</dt>
            <dd className={`dash-deflist__value${badgeClass}`}>{formatted}</dd>
          </div>
        );
      })}
    </dl>
  );
}
