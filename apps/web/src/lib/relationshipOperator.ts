/**
 * Join operators of a relationship predicate.
 *
 * The catalog stores the SaXML spelling (`Equal`, `NotEqual`, `Less`,
 * `LessOrEqual`, `Greater`, `GreaterOrEqual`, `CartesianProduct`). Older
 * aliases (`LessThan`, `Cartesian`, …) are mapped as well — otherwise the long
 * word would fall through to the default and overflow the narrow operator
 * column.
 */
export function operatorSymbol(op: string | null | undefined): string {
  switch (op) {
    case 'Equal': return '=';
    case 'NotEqual': return '≠';
    case 'Less':
    case 'LessThan': return '<';
    case 'LessOrEqual':
    case 'LessThanEqual': return '≤';
    case 'Greater':
    case 'GreaterThan': return '>';
    case 'GreaterOrEqual':
    case 'GreaterThanEqual': return '≥';
    case 'CartesianProduct':
    case 'Cartesian': return '✕';
    default: return op ?? '=';
  }
}

const MIRRORED: Record<string, string> = {
  Less: 'Greater',
  LessThan: 'GreaterThan',
  LessOrEqual: 'GreaterOrEqual',
  LessThanEqual: 'GreaterThanEqual',
  Greater: 'Less',
  GreaterThan: 'LessThan',
  GreaterOrEqual: 'LessOrEqual',
  GreaterThanEqual: 'LessThanEqual',
};

/**
 * Operator with swapped sides: `a < b` reads `b > a`. Symmetric operators
 * (`=`, `≠`, `✕`) stay unchanged. Used when a view puts the relationship's
 * right table occurrence on the left.
 */
export function mirrorOperator(op: string | null | undefined): string | null {
  if (op == null) return null;
  return MIRRORED[op] ?? op;
}
