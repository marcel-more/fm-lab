import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../../types';
import { dispatchAction } from '../../actions';
import type { ActionSpec } from '../../actions';
import { substituteString } from '../../tokens';
import { mountMermaid } from '../../../lib/mermaid/renderMermaid';
import type { MermaidError, MermaidHandle } from '../../../lib/mermaid/renderMermaid';
import { mermaidNodeMap, mermaidText } from './_mermaidSource';

type Row = Record<string, unknown>;

/**
 * Mermaid — draws a diagram from Mermaid text in the data (loaded lazily, see
 * ../Charts.tsx `Mermaid`). Colors and fonts follow the app theme through the
 * `--pele-*` variables in dashboard.css; a theme switch needs no re-render.
 *
 * Props:
 *   field        column with the diagram text (default `mermaid`)
 *   source       diagram text in the layout instead, with {{token}}s
 *   nodesField   column with a JSON array [{ id, uuid, type, file, … }] that maps
 *                Mermaid node ids to catalog objects
 *   onNodeClick  ActionSpec run on a click on a mapped node; tokens come from
 *                the node object ({{uuid}}, {{type}}, {{file}}, {{id}}, …)
 *   title, ariaLabel, maxHeight (px), zoom (`auto` | true | false),
 *   emptyText    shown when there is no diagram text
 */
export default function MermaidChart({ node, dataset, row, navigate }: PrimitiveProps) {
  const { t } = useTranslation(['dashboard']);
  const props = node.props ?? {};
  const field = (props.field as string) || 'mermaid';
  const nodesField = props.nodesField as string | undefined;
  const onNodeClick = props.onNodeClick as ActionSpec | undefined;
  const title = props.title as string | undefined;
  const ariaLabel = (props.ariaLabel as string | undefined) ?? title;
  const maxHeight = Number(props.maxHeight) || undefined;
  const zoom = (props.zoom as boolean | 'auto' | undefined) ?? 'auto';
  const emptyText = props.emptyText as string | undefined;

  const ownBinding = !!node.data?.dataset;
  const rows = (dataset?.data ?? []) as Row[];
  const boundRows = ownBinding ? rows : row ? [row] : rows.slice(0, 1);

  const source = typeof props.source === 'string' ? substituteString(props.source, row ?? rows[0]) : undefined;
  const text = mermaidText({ source, field, ownBinding, row, rows });
  const nodes = useMemo(
    () => (nodesField ? mermaidNodeMap(boundRows.map((r) => r[nodesField])) : new Map<string, Row>()),
    // boundRows derives from these three
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [nodesField, dataset, row, ownBinding],
  );

  const boxRef = useRef<HTMLDivElement>(null);
  const handleRef = useRef<MermaidHandle | null>(null);
  const [error, setError] = useState<MermaidError | null>(null);

  // Clickable nodes: pointer, keyboard focus, role — refreshed after every render.
  const markNodes = useCallback(
    (el: HTMLElement) => {
      if (!onNodeClick || nodes.size === 0) return;
      el.querySelectorAll<SVGGElement>('.pele-node[data-id]').forEach((g) => {
        if (!nodes.has(g.getAttribute('data-id') || '')) return;
        g.classList.add('dash-mermaid__node--link');
        g.setAttribute('tabindex', '0');
        g.setAttribute('role', 'link');
      });
    },
    [nodes, onNodeClick],
  );
  const markRef = useRef(markNodes);
  markRef.current = markNodes;

  useEffect(() => {
    const el = boxRef.current;
    if (!el || !text) return undefined;
    let cancelled = false;
    if (handleRef.current) {
      void handleRef.current.update(text);
      return undefined;
    }
    mountMermaid(el, text, {
      zoom,
      onError: (e) => { if (!cancelled) setError(e); },
      onRender: (target) => markRef.current(target),
    }).then((handle) => {
      if (cancelled) handle.destroy();
      else handleRef.current = handle;
    }).catch((e: unknown) => {
      if (!cancelled) setError({ code: 'unknown', message: String((e as Error)?.message ?? e), line: 0, column: 0, snippet: '' });
    });
    return () => { cancelled = true; };
  }, [text, zoom]);

  useEffect(() => () => {
    handleRef.current?.destroy();
    handleRef.current = null;
  }, []);

  useEffect(() => {
    if (boxRef.current) markNodes(boxRef.current);
  }, [markNodes]);

  const activate = useCallback(
    (target: EventTarget | null) => {
      if (!onNodeClick) return false;
      const g = (target as Element | null)?.closest?.('.pele-node[data-id]');
      const ref = g ? nodes.get(g.getAttribute('data-id') || '') : undefined;
      if (!ref) return false;
      dispatchAction(onNodeClick, ref, { navigate });
      return true;
    },
    [nodes, onNodeClick, navigate],
  );

  if (!text) {
    return emptyText ? <div className="dash-empty">{emptyText}</div> : null;
  }

  return (
    <figure className="dash-mermaid" aria-label={ariaLabel}>
      {title && <figcaption className="dash-mermaid__title">{title}</figcaption>}
      {error && (
        <div className="dash-mermaid__error" role="alert">
          <strong>{error.code === 'limit' ? t('mermaid.tooLarge') : t('mermaid.error')}</strong>
          {error.line > 0 && (
            <span className="dash-mermaid__error-pos">
              {' '}{t('mermaid.position', { line: error.line, column: error.column })}
            </span>
          )}
          <pre className="dash-mermaid__error-text">{error.snippet || error.message}</pre>
        </div>
      )}
      <div
        ref={boxRef}
        className="dash-mermaid__box"
        style={maxHeight ? { maxHeight, overflow: 'auto' } : undefined}
        onClick={(e) => { activate(e.target); }}
        onKeyDown={(e) => {
          if ((e.key === 'Enter' || e.key === ' ') && activate(e.target)) e.preventDefault();
        }}
      />
    </figure>
  );
}
