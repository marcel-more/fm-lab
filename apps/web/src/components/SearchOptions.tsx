import React from 'react';
import { useTranslation } from 'react-i18next';
import type { SortOption, GroupOption, UsageDir, UsageOp } from '../types';

interface SearchOptionsProps {
  sortBy: SortOption;
  groupBy: GroupOption;
  onSortChange: (sort: SortOption) => void;
  onGroupChange: (group: GroupOption) => void;
  /** 'YYYY-MM-DD' or '' — filter on the object's own change stamp. */
  modifiedSince: string;
  onModifiedSinceChange: (since: string) => void;
  /** Usage filter: comparison and bound ('' = none). */
  usageOp: UsageOp;
  onUsageOpChange: (op: UsageOp) => void;
  usageValue: string;
  onUsageValueChange: (value: string) => void;
  /** Effective direction of the usage sort (asc = rarely used first). */
  usageDir: UsageDir;
  onUsageDirChange: (dir: UsageDir) => void;
  /** false = catalog without the usage view (re-import needed); null = unknown yet. */
  usageAvailable: boolean | null;
}

const SORT_VALUES: { value: SortOption; key: string }[] = [
  { value: 'standard', key: 'sortStandard' },
  { value: 'name',     key: 'sortName' },
  { value: 'type',     key: 'sortType' },
  { value: 'file',     key: 'sortFile' },
  { value: 'modified', key: 'sortModified' },
  { value: 'usage',    key: 'sortUsage' },
];

const GROUP_VALUES: { value: GroupOption; key: string }[] = [
  { value: 'none', key: 'groupNone' },
  { value: 'type', key: 'groupType' },
  { value: 'file', key: 'groupFile' },
];

export const SearchOptions: React.FC<SearchOptionsProps> = ({
  sortBy,
  groupBy,
  onSortChange,
  onGroupChange,
  modifiedSince,
  onModifiedSinceChange,
  usageOp,
  onUsageOpChange,
  usageValue,
  onUsageValueChange,
  usageDir,
  onUsageDirChange,
  usageAvailable,
}) => {
  const { t } = useTranslation(['detail']);
  const usageOff = usageAvailable === false;
  const usageHint = (usageOff ? t('detail:searchOptions.usageUnavailable') : t('detail:searchOptions.usageHint')) as string;
  return (
    <div className="search-options-panel" role="region" aria-label={t('detail:searchOptions.regionAria') as string}>
      <fieldset className="search-options-fieldset">
        <legend>{t('detail:searchOptions.sortLabel')}</legend>
        {SORT_VALUES.map(({ value, key }) => (
          <label
            key={value}
            className={`search-options-radio${value === 'usage' && usageOff ? ' is-disabled' : ''}`}
            title={value === 'usage' ? usageHint : undefined}
          >
            <input
              type="radio"
              name="sort"
              value={value}
              checked={sortBy === value}
              disabled={value === 'usage' && usageOff}
              onChange={() => onSortChange(value)}
            />
            {t(`detail:searchOptions.${key}`)}
          </label>
        ))}
        {sortBy === 'usage' && !usageOff && (
          <button
            type="button"
            className="search-options-dir"
            onClick={() => onUsageDirChange(usageDir === 'asc' ? 'desc' : 'asc')}
            title={t(usageDir === 'asc' ? 'detail:searchOptions.usageDirAsc' : 'detail:searchOptions.usageDirDesc') as string}
            aria-label={t(usageDir === 'asc' ? 'detail:searchOptions.usageDirAsc' : 'detail:searchOptions.usageDirDesc') as string}
          >
            {usageDir === 'asc' ? '↑' : '↓'}
          </button>
        )}
      </fieldset>
      <fieldset className="search-options-fieldset">
        <legend>{t('detail:searchOptions.groupLabel')}</legend>
        {GROUP_VALUES.map(({ value, key }) => (
          <label key={value} className="search-options-radio">
            <input
              type="radio"
              name="group"
              value={value}
              checked={groupBy === value}
              onChange={() => onGroupChange(value)}
            />
            {t(`detail:searchOptions.${key}`)}
          </label>
        ))}
      </fieldset>
      <fieldset className="search-options-fieldset">
        <legend>{t('detail:searchOptions.modifiedSinceLabel')}</legend>
        <label className="search-options-date" title={t('detail:searchOptions.modifiedSinceHint') as string}>
          <input
            type="date"
            value={modifiedSince}
            onChange={(e) => onModifiedSinceChange(e.target.value)}
            aria-label={t('detail:searchOptions.modifiedSinceLabel') as string}
          />
        </label>
        {modifiedSince && (
          <button
            type="button"
            className="search-options-clear"
            onClick={() => onModifiedSinceChange('')}
          >
            {t('detail:searchOptions.modifiedSinceClear')}
          </button>
        )}
      </fieldset>
      <fieldset className="search-options-fieldset" disabled={usageOff}>
        <legend>{t('detail:searchOptions.usageLabel')}</legend>
        <span className={`search-options-usage${usageOff ? ' is-disabled' : ''}`} title={usageHint}>
          <select
            value={usageOp}
            onChange={(e) => onUsageOpChange(e.target.value as UsageOp)}
            aria-label={t('detail:searchOptions.usageOpAria') as string}
          >
            <option value="le">≤</option>
            <option value="ge">≥</option>
          </select>
          <input
            type="number"
            min={0}
            step={1}
            inputMode="numeric"
            value={usageValue}
            onChange={(e) => onUsageValueChange(e.target.value.replace(/[^0-9]/g, ''))}
            aria-label={t('detail:searchOptions.usageLabel') as string}
          />
        </span>
        {usageValue !== '' && !usageOff && (
          <button
            type="button"
            className="search-options-clear"
            onClick={() => onUsageValueChange('')}
          >
            {t('detail:searchOptions.modifiedSinceClear')}
          </button>
        )}
      </fieldset>
    </div>
  );
};
