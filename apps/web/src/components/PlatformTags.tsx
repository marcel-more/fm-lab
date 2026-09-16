import { useTranslation } from 'react-i18next';
import { PLATFORM_LABELS, STEP_COMPAT_PLATFORMS, type StepCompat } from '../api/fmSpecApi';
import '../views/FmSpecView.css';

/**
 * Platform tag row for a tri-state compatibility record (step_compat /
 * trigger_compat): lists Yes and PARTIAL platforms, marks Partial, omits
 * explicit No. NULL is Partial — conditionally supported, read the Claris
 * page — and is NEVER rendered as "undocumented" or dropped as "unsupported".
 * Shared by the fm-spec detail views and the catalog's script-trigger detail.
 */
export function PlatformTags({ compat, label }: { compat: StepCompat; label?: string }) {
  const { t } = useTranslation(['fmSpec']);
  const shown = STEP_COMPAT_PLATFORMS.filter((p) => compat[p] !== false);
  return (
    <span className="fmspec-platform-line">
      {label ? <>{label}:{' '}</> : null}
      {shown.length === 0 && <span className="fmspec-tag fmspec-tag--platform fmspec-tag--partial">{t('fmSpec:step.compat.none')}</span>}
      {shown.map((p) => (
        <span
          key={p}
          className={`fmspec-tag fmspec-tag--platform${compat[p] === null ? ' fmspec-tag--partial' : ''}`}
          title={compat[p] === null ? (t('fmSpec:step.compat.partialHint') as string) : undefined}
        >
          {PLATFORM_LABELS[p]}
          {compat[p] === null && <> · {t('fmSpec:step.compat.partial')}</>}
        </span>
      ))}
    </span>
  );
}

export default PlatformTags;
