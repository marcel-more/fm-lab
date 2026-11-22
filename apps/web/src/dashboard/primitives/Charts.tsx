import { lazy, Suspense } from 'react';
import type { PrimitiveProps } from '../types';

/**
 * Chart primitives — thin wrappers that load the visx implementations on first
 * use, so dashboards without charts do not pay for the chart bundle (same idea
 * as the lazy Atlas treemap). The placeholder keeps the card's height while the
 * chunk loads.
 */

const CalendarHeatmapChart = lazy(() => import('./charts/CalendarHeatmapChart'));
const StackedTimeSeriesChart = lazy(() => import('./charts/StackedTimeSeriesChart'));
const SparklineChart = lazy(() => import('./charts/SparklineChart'));
// Mermaid diagrams: the renderer (pele) and each diagram type load on first use.
const MermaidChart = lazy(() => import('./mermaid/MermaidChart'));

const placeholder = (height: number) => (
  <div className="dash-chart dash-chart--loading" style={{ minHeight: height }} aria-busy="true" />
);

export function CalendarHeatmap(props: PrimitiveProps) {
  return (
    <Suspense fallback={placeholder(140)}>
      <CalendarHeatmapChart {...props} />
    </Suspense>
  );
}

export function StackedTimeSeries(props: PrimitiveProps) {
  const height = Number(props.node.props?.height) || 220;
  return (
    <Suspense fallback={placeholder(height + 32)}>
      <StackedTimeSeriesChart {...props} />
    </Suspense>
  );
}

export function Sparkline(props: PrimitiveProps) {
  return (
    <Suspense fallback={placeholder(Number(props.node.props?.height) || 40)}>
      <SparklineChart {...props} />
    </Suspense>
  );
}

export function Mermaid(props: PrimitiveProps) {
  return (
    <Suspense fallback={placeholder(120)}>
      <MermaidChart {...props} />
    </Suspense>
  );
}
