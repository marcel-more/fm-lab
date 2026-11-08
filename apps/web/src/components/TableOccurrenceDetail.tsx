import React from 'react';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useCurrentFile } from '../lib/currentFileContext';
import { TableOccurrenceViewer } from './TableOccurrenceViewer';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';

interface TableOccurrenceDetailProps {
  uuid: string;
}

/**
 * Wrapper of the TableOccurrence detail view. Loads the structured projection
 * via /api/get-details (template object_details_tableoccurrence, plus the
 * usage profile from object_details_tableoccurrence_usage when the catalog has
 * the analysis tables — `meta.to_usage.available`) and renders definition,
 * usage, relationships and sibling occurrences instead of the generic text block.
 */
export const TableOccurrenceDetail: React.FC<TableOccurrenceDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['common']);
  const currentFile = useCurrentFile();
  const { data, meta, loading, error, retry } = useObjectDetails(uuid, currentFile);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  if (!data || data.length === 0) return <div className="no-references">{t('common:noData')}</div>;

  const toUsage = meta?.to_usage as { available?: boolean } | undefined;
  const usageAvailable = typeof toUsage?.available === 'boolean' ? toUsage.available : null;

  // key: a different occurrence starts with fresh filters, sorting and open lists
  return <TableOccurrenceViewer key={`${uuid}::${currentFile ?? ''}`} data={data} usageAvailable={usageAvailable} />;
};
