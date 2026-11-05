import { useEffect, useState } from 'react';
import type { XmlConvertEventDetail, XmlConvertStatusDetail } from './XmlConvertControl';

/**
 * useXmlConvertFileStates — verfolgt den per-Datei-Lebenszyklus eines laufenden
 * XML-Konvertierungslaufs. Im Turbo-Pfad emittiert das Backend pro Datei explizite
 * Lebenszyklus-Events (Sub-Phasen S/D/C), die die alte „aktuelle Datei"-Heuristik
 * (Phasen-basiert) ersetzen:
 *
 *   file_plan        → planned   🟡  (im Manifest, wartet auf Verarbeitung)
 *   file_skip        → skipped   ⏭️  (unverändert übersprungen)
 *   chunk_start      → chunking  🔥  (Split-Worker läuft, Phase S)
 *   chunk_done       → chunked   🟢  (Split fertig, wartet auf Import)
 *   import_start     → importing ✴️ + {done:0,total}  (erster Chunk dispatcht, Phase D)
 *   import_progress  → importing ✴️ + {done,total}    („k von N")
 *   import_done      → imported  ✅  (alle Chunks der Datei fertig)
 *   file (ok=false)  → failed    ⚠️
 *   file (status=skipped) → unsupported ⛔ (Root-Check: Format nicht unterstützt)
 *
 * Fallback für den klassischen (non-Turbo) Pfad ohne Chunking:
 *   file_start       → importing
 *   file             → imported / skipped / failed (je nach ok & status)
 *
 * Lebenszyklus:
 *   - Lauf-Start (Status `running` bzw. `start`-Event): Map wird geleert →
 *     alle (ggf. veralteten) Marker der Status-Tabelle werden zurückgesetzt.
 *   - Lauf-Ende (done/error/aborted bzw. Status ≠ running): Map wird geleert →
 *     der Live-Hintergrund verschwindet, die Tabelle zeigt wieder die frisch
 *     nachgeladenen DB-Werte.
 *
 * Über `enabled` deaktivierbar, damit nicht jede generische Table im Frontend
 * unnötig auf die Convert-Events hört.
 */

const PROGRESS_EVENT = 'fmlab:xml-convert-event';
const STATUS_EVENT = 'fmlab:xml-convert-status';

export type XmlConvertFileState =
  | 'planned'
  | 'skipped'
  | 'chunking'
  | 'chunked'
  | 'importing'
  | 'imported'
  | 'unsupported'
  | 'failed';

export interface XmlConvertFileEntry {
  state: XmlConvertFileState;
  /** Chunk-Zähler während des Imports (Phase D). Nur bei state === 'importing'. */
  done?: number;
  total?: number;
}

export interface XmlConvertFileStates {
  /** Läuft gerade eine Konvertierung? Solange true, übernimmt der Live-Status
   *  die Anzeige (Icons/Hintergründe) statt der statischen DB-Spalte. */
  active: boolean;
  /** filename → Live-Status. Nur befüllt, solange `active`. */
  states: Map<string, XmlConvertFileEntry>;
}

const EMPTY: XmlConvertFileStates = { active: false, states: new Map() };

export function useXmlConvertFileStates(enabled: boolean): XmlConvertFileStates {
  const [value, setValue] = useState<XmlConvertFileStates>(EMPTY);

  useEffect(() => {
    if (!enabled) {
      setValue(EMPTY);
      return;
    }

    const reset = () => setValue({ active: true, states: new Map() });
    const finish = () => setValue(EMPTY);

    const fileOf = (evt: Record<string, unknown>): string =>
      evt.filename != null ? String(evt.filename) : '';

    // Setzt den Status einer Datei (neuer Eintrag ersetzt den alten).
    const setFile = (fn: string, entry: XmlConvertFileEntry) => {
      if (!fn) return;
      setValue(prev => {
        const states = new Map(prev.states);
        states.set(fn, entry);
        return { active: true, states };
      });
    };

    const onEvt = (e: Event) => {
      const evt = (e as CustomEvent<XmlConvertEventDetail>).detail?.evt;
      if (!evt) return;

      switch (evt.event) {
        case 'start':
          reset();
          break;
        case 'file_plan':
          setFile(fileOf(evt), { state: 'planned' });
          break;
        case 'file_skip':
          setFile(fileOf(evt), { state: 'skipped' });
          break;
        case 'chunk_start':
          setFile(fileOf(evt), { state: 'chunking' });
          break;
        case 'chunk_done':
          setFile(fileOf(evt), { state: 'chunked' });
          break;
        case 'import_start':
        case 'import_progress': {
          // import_start trägt done=0/total bereits mit, import_progress die laufenden
          // Zähler — beide treiben denselben determinierten Datei-Fortschrittsbalken
          // (done/total), darum identisch behandelt.
          const fn = fileOf(evt);
          if (!fn) break;
          const done = Number(evt.done);
          const total = Number(evt.total);
          setFile(fn, {
            state: 'importing',
            done: Number.isFinite(done) ? done : undefined,
            total: Number.isFinite(total) ? total : undefined,
          });
          break;
        }
        case 'import_done':
          setFile(fileOf(evt), { state: 'imported' });
          break;
        case 'file_start': {
          // Fallback für den klassischen (non-Turbo) Pfad ohne Chunking: dort ist
          // file_start das einzige „in Arbeit"-Signal. Im Turbo-Pfad spielt der
          // Report-Loop file_start NACH den echten S/D/C-Events nochmals nach —
          // dann existiert bereits ein (reicherer) Eintrag → no-op, statt ihn auf
          // „importing" zurückzustufen.
          const fn = fileOf(evt);
          if (!fn) break;
          setValue(prev => {
            if (prev.states.has(fn)) return prev;
            const states = new Map(prev.states);
            states.set(fn, { state: 'importing' });
            return { active: true, states };
          });
          break;
        }
        case 'file': {
          // Terminales Datei-Ergebnis (klassischer Pfad bzw. Turbo-End-Replay).
          const fn = fileOf(evt);
          if (!fn) break;
          let state: XmlConvertFileState;
          const st = typeof evt.status === 'string' ? evt.status : '';
          if (st === 'skipped') {
            // Root-Check-Skip (ok=false, z. B. FileMaker-18-Export): kein Fehler.
            state = 'unsupported';
          } else if (evt.ok === false) {
            state = 'failed';
          } else {
            state = st === 'unchanged' ? 'skipped' : 'imported';
          }
          setFile(fn, { state });
          break;
        }
        case 'done':
        case 'error':
        case 'aborted':
          finish();
          break;
      }
    };

    const onStatus = (e: Event) => {
      const detail = (e as CustomEvent<XmlConvertStatusDetail>).detail;
      if (!detail) return;
      if (detail.status === 'running') reset();
      else finish();
    };

    window.addEventListener(PROGRESS_EVENT, onEvt);
    window.addEventListener(STATUS_EVENT, onStatus);
    return () => {
      window.removeEventListener(PROGRESS_EVENT, onEvt);
      window.removeEventListener(STATUS_EVENT, onStatus);
    };
  }, [enabled]);

  return enabled ? value : EMPTY;
}
