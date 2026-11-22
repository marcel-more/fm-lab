import type { PrimitiveProps } from '../types';

const JUSTIFY: Record<string, string> = {
  start: 'flex-start', center: 'center', end: 'flex-end', 'space-between': 'space-between',
};

export function Row({ node, renderChildren }: PrimitiveProps) {
  const props = node.props ?? {};
  const gap = (props.gap as number) ?? 12;
  const span = props.span as number | undefined;
  const align = (props.align as string) ?? 'center';
  // `justify`: start (default) | center | end | space-between — e.g. a KPI strip
  // on the left and an action button on the right.
  const justify = JUSTIFY[(props.justify as string) ?? ''];
  const style: React.CSSProperties = {
    display: 'flex',
    flexDirection: 'row',
    gap: `${gap}px`,
    alignItems: align,
    ...(justify ? { justifyContent: justify } : {}),
    flexWrap: 'wrap',
    ...(span ? { gridColumn: `span ${span} / span ${span}` } : {}),
  };
  return <div className="dash-row" style={style}>{renderChildren(node.children)}</div>;
}
