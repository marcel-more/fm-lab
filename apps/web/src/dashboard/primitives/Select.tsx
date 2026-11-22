import { useSearchParams } from 'react-router-dom';
import type { PrimitiveProps } from '../types';
import { MultiSelectPopover } from '../../components/MultiSelectPopover';
import { parseSelection } from '../../lib/multiSelect';

/**
 * Server-side filter dropdown. Like FilterChips, but a `<select>` — scales to
 * many options. Options come from the bound dataset (rows → value/label). The
 * choice is written into a URL param the dashboard forwards to the SQL as
 * `getvariable('<param>')`, so each selection re-queries the full data.
 *
 * Props:
 *   param            URL/getvariable name to drive (required, e.g. "api_set")
 *   default          value selected when the param is absent from the URL
 *   valueField       dataset field used as the option value (default "value")
 *   labelField       dataset field used as the option caption (default "label")
 *   label            optional caption shown before the control (i18n-overridable)
 *   emptyOptionLabel optional caption for a leading "no filter" option with the
 *                    empty value — as a layout prop it is i18n-overridable,
 *                    unlike option rows coming from the dataset
 *   multiple         true → multi-select: a dropdown of checkboxes that writes
 *                    the chosen values, joined by `separator`, into the param
 *                    (none chosen → param absent = no filter). `emptyOptionLabel`
 *                    then captions the "nothing chosen" state; an × next to the
 *                    control and the popover's first entry clear the choice. SQL side:
 *                    `list_contains(string_split(getvariable('<param>'), ','), col)`
 *   separator        value separator of the multi-select (default ","); values
 *                    containing it cannot be selected individually
 *   resetParams      URL params dropped together with every change (e.g. the page
 *                    param of a server-paged table, so a new filter starts on page 1)
 */
export function Select(props: PrimitiveProps) {
  return props.node.props?.multiple === true ? <MultiSelect {...props} /> : <SingleSelect {...props} />;
}

function SingleSelect({ node, dataset }: PrimitiveProps) {
  const props = node.props ?? {};
  const param = props.param as string | undefined;
  const fallback = (props.default as string) ?? '';
  const valueField = (props.valueField as string) ?? 'value';
  const labelField = (props.labelField as string) ?? 'label';
  const caption = props.label as string | undefined;
  const emptyOptionLabel = props.emptyOptionLabel as string | undefined;
  const resetParams = (props.resetParams as string[] | undefined) ?? [];
  const [searchParams, setSearchParams] = useSearchParams();

  if (!param) return null;

  const rows = (dataset?.data as Array<Record<string, unknown>>) ?? [];
  const current = searchParams.get(param) ?? fallback;

  const onChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const value = e.target.value;
    setSearchParams(prev => {
      const n = new URLSearchParams(prev);
      // Keep the URL canonical: drop the param at its default.
      if (value === fallback) n.delete(param);
      else n.set(param, value);
      for (const key of resetParams) n.delete(key);
      return n;
    }, { replace: true });
  };

  return (
    <div className="dash-select">
      {caption && <label className="dash-select__label">{caption}</label>}
      <select className="dash-select__control" value={current} onChange={onChange}>
        {emptyOptionLabel != null && <option value="">{emptyOptionLabel}</option>}
        {rows.map(r => (
          <option key={String(r[valueField])} value={String(r[valueField])}>
            {String(r[labelField])}
          </option>
        ))}
      </select>
    </div>
  );
}

function MultiSelect({ node, dataset }: PrimitiveProps) {
  const props = node.props ?? {};
  const param = props.param as string | undefined;
  const fallback = (props.default as string) ?? '';
  const valueField = (props.valueField as string) ?? 'value';
  const labelField = (props.labelField as string) ?? 'label';
  const caption = props.label as string | undefined;
  const emptyOptionLabel = props.emptyOptionLabel as string | undefined;
  const separator = (props.separator as string) || ',';
  const resetParams = (props.resetParams as string[] | undefined) ?? [];
  const [searchParams, setSearchParams] = useSearchParams();

  if (!param) return null;

  // Adapter: dataset rows → options, URL param ↔ selection. Popover, order of
  // the written values and Escape handling live in MultiSelectPopover.
  const rows = (dataset?.data as Array<Record<string, unknown>>) ?? [];
  const options = rows.map(r => ({ value: String(r[valueField]), label: String(r[labelField]) }));
  const selected = parseSelection(searchParams.get(param) ?? fallback, separator);

  const onChange = (values: string[]) => {
    const value = values.join(separator);
    setSearchParams(prev => {
      const n = new URLSearchParams(prev);
      // Keep the URL canonical: drop the param when empty or at its default.
      if (value === '' || value === fallback) n.delete(param);
      else n.set(param, value);
      for (const key of resetParams) n.delete(key);
      return n;
    }, { replace: true });
  };

  return (
    <MultiSelectPopover
      options={options}
      selected={selected}
      onChange={onChange}
      caption={caption}
      emptyLabel={emptyOptionLabel}
    />
  );
}
