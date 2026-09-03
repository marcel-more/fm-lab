import { useMemo } from 'react';
import { useTheme } from '../hooks/useTheme';

type ColorMap = Record<string, string>;

const FILL_LIGHT: ColorMap = {
  'Edit Box': '#cce5ff',
  'Drop-down List': '#cce5ff',
  'Pop-up Menu': '#cce5ff',
  'Radio Button Set': '#cce5ff',
  'Checkbox Set': '#cce5ff',
  'Drop-down Calendar': '#cce5ff',
  'Concealed Edit Box': '#cce5ff',
  'Text': '#e2e3e5',
  'Graphic': '#e2e3e5',
  'Container': '#e2e3e5',
  'Web Viewer': '#e2e3e5',
  'Chart': '#e2e3e5',
  'Button': '#d4edda',
  'Grouped Button': '#d4edda',
  'Button Bar': '#d4edda',
  'Popover Button': '#d4edda',
  'Portal': '#fff3cd',
  'Group': '#fff3cd',
  'Tab Control': '#fff3cd',
  'Panel': '#fff3cd',
  'Slide Control': '#fff3cd',
  'PopoverPanel': '#fff3cd',
  'Rectangle': '#f8d7da',
  'Rounded Rectangle': '#f8d7da',
  'Line': '#f8d7da',
  'Oval': '#f8d7da',
};

const STROKE_LIGHT: ColorMap = {
  'Edit Box': '#004085',
  'Drop-down List': '#004085',
  'Pop-up Menu': '#004085',
  'Radio Button Set': '#004085',
  'Checkbox Set': '#004085',
  'Drop-down Calendar': '#004085',
  'Concealed Edit Box': '#004085',
  'Text': '#383d41',
  'Graphic': '#383d41',
  'Container': '#383d41',
  'Web Viewer': '#383d41',
  'Chart': '#383d41',
  'Button': '#155724',
  'Grouped Button': '#155724',
  'Button Bar': '#155724',
  'Popover Button': '#155724',
  'Portal': '#856404',
  'Group': '#856404',
  'Tab Control': '#856404',
  'Panel': '#856404',
  'Slide Control': '#856404',
  'PopoverPanel': '#856404',
  'Rectangle': '#721c24',
  'Rounded Rectangle': '#721c24',
  'Line': '#721c24',
  'Oval': '#721c24',
};

const FILL_DARK: ColorMap = {
  'Edit Box': '#1f3a5f',
  'Drop-down List': '#1f3a5f',
  'Pop-up Menu': '#1f3a5f',
  'Radio Button Set': '#1f3a5f',
  'Checkbox Set': '#1f3a5f',
  'Drop-down Calendar': '#1f3a5f',
  'Concealed Edit Box': '#1f3a5f',
  'Text': '#2a2e36',
  'Graphic': '#2a2e36',
  'Container': '#2a2e36',
  'Web Viewer': '#2a2e36',
  'Chart': '#2a2e36',
  'Button': '#1e3d27',
  'Grouped Button': '#1e3d27',
  'Button Bar': '#1e3d27',
  'Popover Button': '#1e3d27',
  'Portal': '#3d3416',
  'Group': '#3d3416',
  'Tab Control': '#3d3416',
  'Panel': '#3d3416',
  'Slide Control': '#3d3416',
  'PopoverPanel': '#3d3416',
  'Rectangle': '#3a1c1f',
  'Rounded Rectangle': '#3a1c1f',
  'Line': '#3a1c1f',
  'Oval': '#3a1c1f',
};

const STROKE_DARK: ColorMap = {
  'Edit Box': '#7eb6ff',
  'Drop-down List': '#7eb6ff',
  'Pop-up Menu': '#7eb6ff',
  'Radio Button Set': '#7eb6ff',
  'Checkbox Set': '#7eb6ff',
  'Drop-down Calendar': '#7eb6ff',
  'Concealed Edit Box': '#7eb6ff',
  'Text': '#a8adb8',
  'Graphic': '#a8adb8',
  'Container': '#a8adb8',
  'Web Viewer': '#a8adb8',
  'Chart': '#a8adb8',
  'Button': '#80d896',
  'Grouped Button': '#80d896',
  'Button Bar': '#80d896',
  'Popover Button': '#80d896',
  'Portal': '#e9c66a',
  'Group': '#e9c66a',
  'Tab Control': '#e9c66a',
  'Panel': '#e9c66a',
  'Slide Control': '#e9c66a',
  'PopoverPanel': '#e9c66a',
  'Rectangle': '#e67c84',
  'Rounded Rectangle': '#e67c84',
  'Line': '#e67c84',
  'Oval': '#e67c84',
};

export type LayoutObjectPalette = {
  fillFor: (type: string) => string;
  strokeFor: (type: string) => string;
  dimmedFill: string;
  dimmedStroke: string;
  dimmedText: string;
  normalText: string;
  highlightRing: string;
  selectionRing: string;
};

const PALETTES = {
  light: {
    fill: FILL_LIGHT,
    stroke: STROKE_LIGHT,
    fillFallback: '#f0f0f0',
    strokeFallback: '#666666',
    dimmedFill: '#f0f0f0',
    dimmedStroke: '#cccccc',
    dimmedText: '#999999',
    normalText: '#333333',
    highlightRing: '#fb923c',
    selectionRing: '#dc2626',
  },
  dark: {
    fill: FILL_DARK,
    stroke: STROKE_DARK,
    fillFallback: '#1a1d23',
    strokeFallback: '#7c8493',
    dimmedFill: '#1a1d23',
    dimmedStroke: '#3a3e47',
    dimmedText: '#5e636d',
    normalText: '#d8dce4',
    highlightRing: '#ffa552',
    selectionRing: '#ff5a5a',
  },
} as const;

export function useLayoutObjectPalette(): LayoutObjectPalette {
  const { theme } = useTheme();
  return useMemo(() => {
    const p = PALETTES[theme];
    return {
      fillFor: (type: string) => p.fill[type] ?? p.fillFallback,
      strokeFor: (type: string) => p.stroke[type] ?? p.strokeFallback,
      dimmedFill: p.dimmedFill,
      dimmedStroke: p.dimmedStroke,
      dimmedText: p.dimmedText,
      normalText: p.normalText,
      highlightRing: p.highlightRing,
      selectionRing: p.selectionRing,
    };
  }, [theme]);
}
