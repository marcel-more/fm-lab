/**
 * Line-break opportunities for long identifiers in Table cells (`breakAt`).
 *
 * FileMaker names often come without spaces (`PDF_Textbausteine_Preisschlüssel`,
 * `Excel-Import-Artikel`). Such a token is one unbreakable word: it sets the
 * column's minimum width, and a table of several of them overflows its card.
 *
 *   "separators"  break only after `_` and `-` — the word separators stay
 *                 at the end of the line, so the name stays readable
 *   "anywhere"    break between any two characters (CSS overflow-wrap)
 *
 * Both are opportunities, not forced breaks: in the automatic table layout a
 * column keeps its full one-line width while the window is wide enough, and
 * only wraps when the table would not fit otherwise. Widening the window
 * removes the break again.
 */

export type BreakAt = 'separators' | 'anywhere';

const SEPARATOR_RUN = /[_-]+/g;

/**
 * Splits a text after every run of separators (`_`, `-`). Joining the parts
 * gives the text back unchanged; a renderer puts a `<wbr>` between them.
 * A separator at the very end yields no empty trailing part.
 */
export function separatorSegments(text: string): string[] {
  const parts: string[] = [];
  let start = 0;
  for (const m of text.matchAll(SEPARATOR_RUN)) {
    const end = (m.index ?? 0) + m[0].length;
    // A leading separator (`_Positionsliste`) is no break point: a line
    // holding only "_" helps nobody.
    if (m.index === 0 || end >= text.length) continue;
    parts.push(text.slice(start, end));
    start = end;
  }
  parts.push(text.slice(start));
  return parts;
}

export function isBreakAt(value: unknown): value is BreakAt {
  return value === 'separators' || value === 'anywhere';
}

/**
 * When the break opportunities are on. Measured, not assumed: the automatic
 * table layout shares out the width in proportion to each column's content,
 * so a column that MAY break does break — even in a window wide enough for
 * the table without any break. Hence the opportunities stay off until the
 * table (rendered without them) overflows its container, and go off again
 * once the container is back at the width the table needed then.
 */
export interface BreakFit {
  active: boolean;
  /** Table width measured without breaks at the moment they went on. */
  needed: number | null;
}

export const BREAK_FIT_OFF: BreakFit = { active: false, needed: null };

export function nextBreakFit(
  state: BreakFit,
  measured: { tableWidth: number; available: number },
): BreakFit {
  if (!state.active) {
    // Sub-pixel rounding is no overflow.
    return measured.tableWidth > measured.available + 1
      ? { active: true, needed: measured.tableWidth }
      : state;
  }
  return state.needed != null && measured.available >= state.needed ? BREAK_FIT_OFF : state;
}
