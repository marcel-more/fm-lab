import type { CSSProperties } from 'react';

/**
 * Pulse glyph of the Healthchecks entry point (band in the folder view, sum
 * row in the list). `animated`: a glowing dot runs along the wave, then
 * pauses before the next pass — shown while rules are still waiting for
 * their first result. The dot is hidden under `prefers-reduced-motion`.
 *
 * The dot is an HTML element moved by a CSS keyframe animation of
 * `transform` and `opacity` only (`dash-pulse-run` in dashboard.css), which
 * browsers can run on the compositor instead of ticking an SVG animation on
 * the main thread. The box is laid out in the 24-unit space of the viewBox
 * and scaled to `size`, so the keyframes use viewBox units as px.
 */
export function PulseIcon({ size = 14, animated = false }: { size?: number; animated?: boolean }) {
  return (
    <span
      className={`dash-pulse${animated ? ' dash-pulse--animated' : ''}`}
      style={{ '--dash-pulse-size': `${size}px`, '--dash-pulse-scale': size / 24 } as CSSProperties}
      aria-hidden="true"
    >
      <span className="dash-pulse__box">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.25" strokeLinecap="round" strokeLinejoin="round">
          <polyline points="2 12 6 12 9 3 15 21 18 12 22 12" />
        </svg>
        {animated && <span className="dash-pulse__dot" />}
      </span>
    </span>
  );
}
