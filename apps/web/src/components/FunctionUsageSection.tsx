import React from 'react';
import { useTranslation } from 'react-i18next';

/**
 * Eine Zeile der Verwendungs-Verdichtung: eine Kombination aus Link-Rolle und
 * Quell-Objekttyp, wie sie die `usage`-Sektion der Pseudo-Objekt-Projektionen
 * liefert (object_details_builtinfunction.sql / …_pluginfunction.sql).
 */
export interface FunctionUsageRow {
  link_role: string | null;
  used_by_type: string | null;
  object_count: number | null;
  file_count: number | null;
  occurrence_count: number | null;
}

interface FunctionUsageSectionProps {
  rows: FunctionUsageRow[];
  /** Deduplizierte Gesamtwerte aus der meta-Zeile — NICHT die Spaltensummen. */
  totalObjects: number;
  totalFiles: number;
  totalOccurrences: number;
}

/**
 * Verwendungs-Abschnitt der funktions-artigen Pseudo-Objekte (BuiltinFunction,
 * PluginFunction): verdichtete Where-used-Zahlen je Rolle und Objekttyp.
 *
 * Bewusst ohne Aufrufer-Liste — die lebt im Referenzen-Tab, wo jede Kante
 * navigierbar ist. Hier steht nur, WIE und WIE OFT verwendet wird.
 *
 * Die Gesamtzeile kommt aus der meta-Zeile der Projektion, nicht aus den
 * Zeilen darüber: ein Objekt kann dieselbe Funktion in zwei Rollen verwenden
 * und wäre in einer Spaltensumme doppelt gezählt.
 */
export const FunctionUsageSection: React.FC<FunctionUsageSectionProps> = ({
  rows, totalObjects, totalFiles, totalOccurrences,
}) => {
  const { t } = useTranslation(['detail', 'types']);
  // Datei-Spalte nur, wenn die Lösung überhaupt datei-übergreifend verwendet
  // (Einzeldatei-Lösungen bekämen eine Spalte voller Einsen).
  const showFiles = totalFiles > 1;

  return (
    <section className="fm-fn-section">
      <h3 className="fm-fn-section-head">
        {t('detail:pseudoFunction.usageHeading', { defaultValue: 'Usage' })}
        <span className="fm-fn-count"> ({totalOccurrences})</span>
      </h3>
      {rows.length === 0 ? (
        <div className="fm-fn-empty">
          {t('detail:pseudoFunction.usageEmpty', { defaultValue: 'Not used in this solution.' })}
        </div>
      ) : (
        <table className="fm-fn-table">
          <thead>
            <tr>
              <th>{t('detail:pseudoFunction.colRole', { defaultValue: 'Role' })}</th>
              <th>{t('detail:pseudoFunction.colType', { defaultValue: 'Object type' })}</th>
              <th className="fm-fn-col-num">{t('detail:pseudoFunction.colObjects', { defaultValue: 'Objects' })}</th>
              {showFiles && (
                <th className="fm-fn-col-num">{t('detail:pseudoFunction.colFiles', { defaultValue: 'Files' })}</th>
              )}
              <th className="fm-fn-col-num">{t('detail:pseudoFunction.colOccurrences', { defaultValue: 'Occurrences' })}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={`${row.link_role}::${row.used_by_type}`}>
                {/* Link-Rolle bleibt der technische Token — dieselbe Schreibweise
                    wie im Referenzen-Tab und in ObjectLinks. */}
                <td><code className="fm-fn-role">{row.link_role}</code></td>
                <td>{t(`types:objectTypes.${row.used_by_type}`, { defaultValue: row.used_by_type ?? '—' })}</td>
                <td className="fm-fn-col-num">{row.object_count}</td>
                {showFiles && <td className="fm-fn-col-num">{row.file_count}</td>}
                <td className="fm-fn-col-num">{row.occurrence_count}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <th scope="row" colSpan={2}>
                {t('detail:pseudoFunction.totalRow', { defaultValue: 'Total' })}
              </th>
              <td className="fm-fn-col-num">{totalObjects}</td>
              {showFiles && <td className="fm-fn-col-num">{totalFiles}</td>}
              <td className="fm-fn-col-num">{totalOccurrences}</td>
            </tr>
          </tfoot>
        </table>
      )}
    </section>
  );
};
