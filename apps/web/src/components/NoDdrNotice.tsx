import { useTranslation } from 'react-i18next';

/**
 * Warning for traces that touch files exported without DDR info ("Include
 * details for analysis tools"): formula references are missing there, so
 * fields read in formulas, script parameters and results do not appear and
 * ways can end early. Renders nothing for an empty list.
 */
export function NoDdrNotice({ files }: { files: string[] | null | undefined }) {
  const { t } = useTranslation(['explorer']);
  if (!files || files.length === 0) return null;
  return (
    <div className="explorer-filter-section">
      <span className="explorer-filter-label">{t('trace.noDdr.title')}</span>
      <p className="explorer-data-hint is-warning" title={t('trace.noDdr.hint') as string}>
        {t('trace.noDdr.notice', { count: files.length, files: files.join(', ') })}
      </p>
    </div>
  );
}
