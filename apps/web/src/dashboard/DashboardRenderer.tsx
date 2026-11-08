import { useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import type { LayoutNode, DashboardLayout, DashboardDataResponse, DatasetResult } from '../api/dashboardApi';
import { getPrimitive } from './primitives/registry';
import { SelectionProvider } from './selectionContext';
import { PrimitiveErrorBoundary } from './PrimitiveErrorBoundary';

interface Props {
  layout: DashboardLayout;
  datasets: DashboardDataResponse;
}

/**
 * Evaluate a node's optional `visibleWhen` guard against the loaded datasets.
 * Reads the first row of the referenced dataset; on any uncertainty (missing
 * dataset/row/field) it defaults to VISIBLE, so a node never disappears because
 * its guard dataset failed to load.
 */
function isNodeVisible(node: LayoutNode, datasets: DashboardDataResponse): boolean {
  const cond = node.visibleWhen;
  if (!cond) return true;
  const row = datasets?.[cond.dataset]?.data?.[0] as Record<string, unknown> | undefined;
  const val = row?.[cond.field];
  if ('equals' in cond) return val === cond.equals;
  if ('notEquals' in cond) return val !== cond.notEquals;
  if ('truthy' in cond) return cond.truthy ? !!val : !val;
  return true;
}

/**
 * Walkt rekursiv den Layout-Tree. Ein Primitive entscheidet selbst, wie es das
 * gebundene Dataset interpretiert (Single-Row für Container, Multi-Row für
 * Repeating-Primitives wie List/Table/TileGrid).
 *
 * Sicherheit: Layout ist deklarativ — kein freier Code möglich.
 */
export function DashboardRenderer({ layout, datasets }: Props) {
  const navigate = useNavigate();

  const renderNode = useCallback(
    (
      node: LayoutNode,
      parentRow?: Record<string, unknown>,
      parentDataset?: DatasetResult
    ): React.ReactNode => {
      if (!isNodeVisible(node, datasets)) return null;
      const Primitive = getPrimitive(node.type);
      const ownDatasetId = node.data?.dataset as string | undefined;
      // Eigene Bindung gewinnt; sonst erbt das Primitive das Dataset vom Parent.
      // Das ist nötig, damit z.B. Card[dataset=files_overview] > Table das
      // Dataset zur Multi-Row-Iteration bekommt, ohne die Bindung doppelt zu
      // pflegen.
      const dataset: DatasetResult | undefined = ownDatasetId
        ? datasets[ownDatasetId]
        : parentDataset;

      const renderChildren = (
        children: LayoutNode[] | undefined,
        rowForChildren?: Record<string, unknown>
      ): React.ReactNode => {
        if (!children) return null;
        return children.map((child, i) => (
          <RenderNode
            key={i}
            node={child}
            renderNode={renderNode}
            row={rowForChildren ?? parentRow}
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
            row={parentRow}
            datasets={datasets}
            renderChildren={renderChildren}
            navigate={navigate}
          />
        </PrimitiveErrorBoundary>
      );
    },
    [datasets, navigate]
  );

  // Selection channel spans the whole rendered dashboard (lens table ⇄ list
  // table) and resets when the renderer unmounts.
  return <SelectionProvider>{renderNode(layout.root)}</SelectionProvider>;
}

interface RenderNodeProps {
  node: LayoutNode;
  renderNode: (
    node: LayoutNode,
    parentRow?: Record<string, unknown>,
    parentDataset?: DatasetResult
  ) => React.ReactNode;
  row?: Record<string, unknown>;
  parentDataset?: DatasetResult;
}

function RenderNode({ node, renderNode, row, parentDataset }: RenderNodeProps) {
  return <>{renderNode(node, row, parentDataset)}</>;
}
