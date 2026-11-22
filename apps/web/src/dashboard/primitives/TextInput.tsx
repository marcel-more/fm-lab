import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { PrimitiveProps } from '../types';

/**
 * Server-side free-text parameter (like Select, but typed): the value is written
 * into a URL param the dashboard forwards to the SQL as `getvariable('<param>')`.
 * It is committed on Enter or when the field loses focus — not on every
 * keystroke, so a typed word reloads the data once.
 *
 * Props:
 *   param        URL/getvariable name to drive (required)
 *   default      value when the param is absent from the URL; committing it drops
 *                the param (canonical URL). An empty field writes an empty param
 *                (`?p=`) — SQL sees '' and can treat it as "switched off".
 *   label        caption before the field (i18n-overridable)
 *   placeholder  hint inside the empty field (i18n-overridable)
 *   width        field width in characters (default 16)
 *   resetParams  URL params dropped together with every change
 */
export function TextInput({ node }: PrimitiveProps) {
  const props = node.props ?? {};
  const param = props.param as string | undefined;
  const fallback = (props.default as string) ?? '';
  const caption = props.label as string | undefined;
  const placeholder = props.placeholder as string | undefined;
  const width = Number(props.width) || 16;
  const resetParams = (props.resetParams as string[] | undefined) ?? [];
  const [searchParams, setSearchParams] = useSearchParams();
  const current = param ? (searchParams.get(param) ?? fallback) : '';
  const [draft, setDraft] = useState(current);

  // Follow outside changes (back/forward, reset by another control).
  useEffect(() => { setDraft(current); }, [current]);

  if (!param) return null;

  const commit = () => {
    if (draft === current) return;
    setSearchParams(prev => {
      const n = new URLSearchParams(prev);
      if (draft === fallback) n.delete(param);
      else n.set(param, draft);
      for (const key of resetParams) n.delete(key);
      return n;
    }, { replace: true });
  };

  return (
    <div className="dash-select">
      {caption && <label className="dash-select__label">{caption}</label>}
      <input
        type="text"
        className="dash-select__control dash-textinput"
        style={{ width: `${width + 2}ch` }}
        value={draft}
        placeholder={placeholder}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') commit();
          if (e.key === 'Escape') setDraft(current);
        }}
      />
    </div>
  );
}
