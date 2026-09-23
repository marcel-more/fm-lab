import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import { formatKpiValue } from './_format';
import { dispatchAction } from '../actions';
import type { ActionSpec } from '../actions';
import type { BadgeTone } from './_badgeTone';

export interface KpiItem {
  label: string;
  field: string;
  format?: string;
  // Semantic colour per badge value, overriding the value-derived class
  // (see _badgeTone.ts). Only meaningful with `format: 'badge'`.
  badgeTone?: BadgeTone;
  // Result-state colour for the VALUE itself (`dash-state-*`: error, warning,
  // neutral, ok, failed, pending). A KPI is a bare number otherwise, so a count
  // that reports a defect reads like any other statistic. `toneWhen: 'nonzero'`
  // applies the colour only while the number is non-zero, which is the normal
  // case for a finding count — a clean solution stays visually quiet.
  tone?: string;
  toneWhen?: 'always' | 'nonzero';
  onClick?: ActionSpec;
}

export function KPI({ node, row, navigate }: PrimitiveProps) {
  const { i18n } = useTranslation();
  const props = node.props ?? {};
  const label = props.label as string;
  const field = props.field as string;
  const format = props.format as string | undefined;
  const onClick = props.onClick as ActionSpec | undefined;

  const value = row?.[field];
  const formatted = formatKpiValue(value, format, i18n.language);
  const clickable = !!onClick;

  return (
    <button
      type="button"
      className={`dash-kpi${clickable ? ' dash-kpi--clickable' : ''}`}
      onClick={clickable ? () => dispatchAction(onClick, row, { navigate }) : undefined}
      disabled={!clickable}
    >
      <span className="dash-kpi__label">{label}</span>
      <span className="dash-kpi__value">{formatted}</span>
    </button>
  );
}
