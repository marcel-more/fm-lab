import { useCallback, useMemo, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import type { LayoutNode, DashboardLayout, DashboardDataResponse, DatasetResult } from '../api/dashboardApi';
import { getPrimitive } from './primitives/registry';
import { SelectionProvider, useSelection } from './selectionContext';
import { PrimitiveErrorBoundary } from './PrimitiveErrorBoundary';
import { ActionAskHost } from './ActionAskHost';
import { initialChannels, isVisible, narrowDataset, selectedRow, usesSelection } from './_selectionBinding';

interface Props {
  layout: DashboardLayout;
  datasets: DashboardDataResponse;
}

type Row = Record<string, unknown>;
type RenderNodeFn = (node: LayoutNode, parentRow?: Row, parentDataset?: DatasetResult) => React.ReactNode;
type RenderPrimitiveFn = (node: LayoutNode, row: Row | undefined, dataset: DatasetResult | undefined) => React.ReactNode;

/**
 * Walkt rekursiv den Layout-Tree. Ein Primitive entscheidet selbst, wie es das
 * gebundene Dataset interpretiert (Single-Row für Container, Multi-Row für
 * Repeating-Primitives wie List/Table/TileGrid).
 *
 * Nodes that read a selection channel (`data.selection`, `visibleWhen.selection`)
 * render through SelectionNode, the only place that subscribes to the channel
 * state — a selection change re-renders those nodes, not the whole tree.
 *
 * Sicherheit: Layout ist deklarativ — kein freier Code möglich.
 */
export function DashboardRenderer({ layout, datasets }: Props) {
  const navigate = useNavigate();
  // renderChildren closes over the latest renderNode without a dependency cycle.
  const renderNodeRef = useRef<RenderNodeFn>(() => null);

  const renderPrimitive = useCallback<RenderPrimitiveFn>(
    (node, row, dataset) => {
      const Primitive = getPrimitive(node.type);
      const renderChildren = (children: LayoutNode[] | undefined, rowForChildren?: Row): React.ReactNode => {
        if (!children) return null;
        return children.map((child, i) => (
          <RenderNode
            key={i}
            node={child}
            renderNode={renderNodeRef.current}
            row={rowForChildren ?? row}
            parentDataset={dataset}
          />
        ));
      };
      // One failing element must not blank the whole dashboard.
      return (
        <PrimitiveErrorBoundary nodeLabel={`${node.type}${node.id ? `#${node.id}` : ''}`} resetKey={dataset}>
          <Primitive
            node={node}
            dataset={dataset}
            row={row}
            datasets={datasets}
            renderChildren={renderChildren}
            navigate={navigate}
          />
        </PrimitiveErrorBoundary>
      );
    },
    [datasets, navigate],
  );

  const renderNode = useCallback<RenderNodeFn>(
    (node, parentRow, parentDataset) => {
      const ownDatasetId = node.data?.dataset as string | undefined;
      // Eigene Bindung gewinnt; sonst erbt das Primitive das Dataset vom Parent.
      // Das ist nötig, damit z.B. Card[dataset=files_overview] > Table das
      // Dataset zur Multi-Row-Iteration bekommt, ohne die Bindung doppelt zu
      // pflegen.
      const dataset: DatasetResult | undefined = ownDatasetId ? datasets[ownDatasetId] : parentDataset;
      if (usesSelection(node)) {
        return (
          <SelectionNode
            node={node}
            row={parentRow}
            dataset={dataset}
            datasets={datasets}
            renderPrimitive={renderPrimitive}
          />
        );
      }
      if (!isVisible(node.visibleWhen, datasets, {})) return null;
      return renderPrimitive(node, parentRow, dataset);
    },
    [datasets, renderPrimitive],
  );
  renderNodeRef.current = renderNode;

  // Selection channels span the whole rendered dashboard (lens table ⇄ list
  // table, master ⇄ detail) and reset when the renderer unmounts. Channel
  // defaults from the layout are the initial values.
  const initial = useMemo(() => initialChannels(layout), [layout]);
  return (
    <SelectionProvider initial={initial}>
      {renderNode(layout.root)}
      <ActionAskHost />
    </SelectionProvider>
  );
}

/**
 * A node bound to a selection channel: hidden/shown by `visibleWhen.selection`;
 * with `data.selection` it gets the selected row as its row and its dataset
 * narrowed to that row (a Card hands it on to its children).
 */
function SelectionNode({
  node,
  row,
  dataset,
  datasets,
  renderPrimitive,
}: {
  node: LayoutNode;
  row?: Row;
  dataset?: DatasetResult;
  datasets: DashboardDataResponse;
  renderPrimitive: RenderPrimitiveFn;
}) {
  const { selection } = useSelection();
  if (!isVisible(node.visibleWhen, datasets, selection)) return null;
  const bind = node.data?.selection;
  if (!bind) return <>{renderPrimitive(node, row, dataset)}</>;
  const rows = (dataset?.data ?? []) as Row[];
  const picked = selectedRow(rows, bind.key, selection[bind.channel], node.data?.fallback ?? 'first');
  return <>{renderPrimitive(node, picked, narrowDataset(dataset, picked))}</>;
}

interface RenderNodeProps {
  node: LayoutNode;
  renderNode: RenderNodeFn;
  row?: Row;
  parentDataset?: DatasetResult;
}

function RenderNode({ node, renderNode, row, parentDataset }: RenderNodeProps) {
  return <>{renderNode(node, row, parentDataset)}</>;
}
