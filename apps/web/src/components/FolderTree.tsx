import React, { useMemo, useRef, useState, useCallback, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useVirtualizer } from '@tanstack/react-virtual';
import { useTranslation } from 'react-i18next';
import { useTemplateQuery } from '../hooks/useTemplateQuery';
import { BulkToggleButton, BulkToggleGroup, CollapseAllIcon, ExpandAllIcon } from './BulkToggle';
import { DisclosureChevron } from './DisclosureChevron';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import { NoDataYet } from './NoDataYet';
import { buildObjectPath } from '../lib/navigation';
import { isNoImportError } from '../lib/errors';
import './FolderTree.css';

const ROW_HEIGHT = 36;
const SEPARATOR_HEIGHT = 14;
const INDENT_PX = 18;

export type FolderTreeSubtype = 'ScriptCatalog' | 'Layouts' | 'CustomFunctionsCatalog';

interface TreeRow {
  uuid: string;
  name: string;
  type: string;       // Folder | Script | Layout | CustomFunction | Separator
  subtype: string;    // Folder | Item | Separator
  nesting_level: number;
  file: string;
  sequence: number;
}

interface FolderTreeProps {
  subtype: FolderTreeSubtype;
  file?: string;
  filter?: string;
}

function loadExpandedFromStorage(subtype: FolderTreeSubtype): Set<string> {
  try {
    const raw = localStorage.getItem(`folderTree:expanded:${subtype}`);
    if (!raw) return new Set();
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? new Set(arr) : new Set();
  } catch {
    return new Set();
  }
}

function saveExpandedToStorage(subtype: FolderTreeSubtype, expanded: Set<string>): void {
  try {
    localStorage.setItem(`folderTree:expanded:${subtype}`, JSON.stringify([...expanded]));
  } catch {
    // ignore quota errors
  }
}

/** Aufklappbare Container: echte Folder UND die optionalen Datei-Gruppenknoten. */
function isContainerRow(subtype: string): boolean {
  return subtype === 'Folder' || subtype === 'File';
}

function computeUnfilteredVisibleRows(rows: TreeRow[], expanded: Set<string>): TreeRow[] {
  const out: TreeRow[] = [];
  let hideUntilLevel = -1;
  for (const row of rows) {
    if (hideUntilLevel >= 0 && row.nesting_level > hideUntilLevel) {
      continue;
    }
    hideUntilLevel = -1;
    out.push(row);
    if (isContainerRow(row.subtype) && !expanded.has(row.uuid)) {
      hideUntilLevel = row.nesting_level;
    }
  }
  return out;
}

function computeFilteredVisibleRows(rows: TreeRow[], filterLower: string): TreeRow[] {
  // Pass 1: Sammele Match-UUIDs (Items + Folder die selbst matchen) + alle ihre Eltern-Folder
  const visibleSet = new Set<string>();
  const folderStack: { level: number; uuid: string }[] = [];
  for (const row of rows) {
    while (folderStack.length > 0 && folderStack[folderStack.length - 1].level >= row.nesting_level) {
      folderStack.pop();
    }
    if (isContainerRow(row.subtype)) {
      folderStack.push({ level: row.nesting_level, uuid: row.uuid });
      // Datei-Knoten matchen nie selbst — reine Container, nur über einen
      // Kind-Treffer sichtbar. Folder dürfen per Namen selbst matchen.
      if (row.subtype === 'Folder' && row.name.toLowerCase().includes(filterLower)) {
        visibleSet.add(row.uuid);
        for (const f of folderStack) visibleSet.add(f.uuid);
      }
    } else if (row.subtype === 'Item') {
      if (row.name.toLowerCase().includes(filterLower)) {
        visibleSet.add(row.uuid);
        for (const f of folderStack) visibleSet.add(f.uuid);
      }
    }
    // Separators matchen nie selbst (Name = '-')
  }

  // Pass 2: Output unter Berücksichtigung der Sichtbarkeit
  const out: TreeRow[] = [];
  const currentStack: { level: number; uuid: string; visible: boolean }[] = [];
  for (const row of rows) {
    while (currentStack.length > 0 && currentStack[currentStack.length - 1].level >= row.nesting_level) {
      currentStack.pop();
    }
    if (isContainerRow(row.subtype)) {
      const isVis = visibleSet.has(row.uuid);
      currentStack.push({ level: row.nesting_level, uuid: row.uuid, visible: isVis });
      if (isVis) out.push(row);
    } else if (row.subtype === 'Item') {
      if (visibleSet.has(row.uuid)) out.push(row);
    } else if (row.subtype === 'Separator') {
      const parent = currentStack.length > 0 ? currentStack[currentStack.length - 1] : null;
      if (parent?.visible) out.push(row);
    }
  }
  return out;
}

export const FolderTree: React.FC<FolderTreeProps> = ({ subtype, file, filter }) => {
  const { t } = useTranslation(['nav']);
  const navigate = useNavigate();
  const params = useMemo(() => {
    const p: Record<string, string> = { subtype };
    if (file) p.file = file;
    return p;
  }, [subtype, file]);

  const { data, loading, error, retry } = useTemplateQuery('list_with_folders', params, true);

  const [expanded, setExpanded] = useState<Set<string>>(() => loadExpandedFromStorage(subtype));

  useEffect(() => {
    setExpanded(loadExpandedFromStorage(subtype));
  }, [subtype]);

  useEffect(() => {
    saveExpandedToStorage(subtype, expanded);
  }, [subtype, expanded]);

  const rows: TreeRow[] = useMemo(() => {
    if (!data) return [];
    return data.map(r => ({
      uuid: String(r.uuid ?? ''),
      name: String(r.name ?? ''),
      type: String(r.type ?? 'Item'),
      subtype: String(r.subtype ?? 'Item'),
      nesting_level: Number(r.nesting_level ?? 0),
      file: String(r.file ?? ''),
      sequence: Number(r.sequence ?? 0),
    }));
  }, [data]);

  const filterTrimmed = (filter ?? '').trim();
  const filterActive = filterTrimmed.length > 0;

  // Anzahl verschiedener Dateien im geladenen Datenbestand.
  const fileCount = useMemo(() => {
    const seen = new Set<string>();
    for (const r of rows) seen.add(r.file);
    return seen.size;
  }, [rows]);

  // Datei-Ebene optional als Top-Level-Knoten einziehen — aber nur, wenn
  //   (a) keine Datei vorausgewählt ist (file-Prop leer) und
  //   (b) die Lösung mehr als eine Datei umfasst.
  // So vermeiden wir Unübersichtlichkeit beim Einstieg in Mehrdatei-Lösungen:
  // jede Datei wird ein eigener aufklappbarer Container, die realen Zeilen rücken
  // eine Ebene tiefer. Bei vorausgewählter Datei bleibt der Baum unverändert flach.
  const groupByFile = !file && fileCount > 1;

  const displayRows: TreeRow[] = useMemo(() => {
    if (!groupByFile) return rows;
    // rows sind bereits nach (File_Name, seq) sortiert → Dateien liegen
    // zusammenhängend, ein Header pro Datei genügt.
    const out: TreeRow[] = [];
    let lastFile: string | null = null;
    for (const r of rows) {
      if (r.file !== lastFile) {
        lastFile = r.file;
        out.push({
          uuid: `__file__:${r.file}`,
          name: r.file,
          type: 'File',
          subtype: 'File',
          nesting_level: 0,
          file: r.file,
          sequence: -1,
        });
      }
      out.push({ ...r, nesting_level: r.nesting_level + 1 });
    }
    return out;
  }, [rows, groupByFile]);

  const visibleRows: TreeRow[] = useMemo(() => {
    if (filterActive) {
      return computeFilteredVisibleRows(displayRows, filterTrimmed.toLowerCase());
    }
    return computeUnfilteredVisibleRows(displayRows, expanded);
  }, [displayRows, expanded, filterActive, filterTrimmed]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: visibleRows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: (index) =>
      visibleRows[index]?.subtype === 'Separator' ? SEPARATOR_HEIGHT : ROW_HEIGHT,
    overscan: 12,
  });

  // Wenn der Filter sich ändert, muss der Virtualizer die Höhen neu berechnen
  useEffect(() => {
    virtualizer.measure();
  }, [filterActive, filterTrimmed, virtualizer]);

  const toggleFolder = useCallback((uuid: string) => {
    setExpanded(prev => {
      const next = new Set(prev);
      if (next.has(uuid)) next.delete(uuid);
      else next.add(uuid);
      return next;
    });
  }, []);

  const expandAll = useCallback(() => {
    setExpanded(new Set(displayRows.filter(r => isContainerRow(r.subtype)).map(r => r.uuid)));
  }, [displayRows]);

  const collapseAll = useCallback(() => {
    setExpanded(new Set());
  }, []);

  const handleItemClick = useCallback((row: TreeRow) => {
    if (row.subtype === 'Separator') return;
    // Klon-Disambiguierung: `row.file` ist die Zieldatei (Graceful Downgrade).
    navigate(buildObjectPath(row.uuid, null, row.file || null));
  }, [navigate]);

  if (loading) {
    return <LoadingSpinner message={t('nav:folderTree.loading') as string} />;
  }
  if (error) {
    // Kein Import vorhanden → die FolderHierarchy-View existiert noch nicht.
    // Statt des rohen Katalog-Fehlers eine neutrale "noch keine Daten"-Info.
    if (isNoImportError(error)) {
      return <NoDataYet />;
    }
    return <ErrorMessage message={error} onRetry={retry} />;
  }
  if (!rows.length) {
    return <div className="folder-tree-empty">{t('nav:folderTree.empty')}</div>;
  }

  const folderCount = rows.filter(r => r.subtype === 'Folder').length;
  const itemCount = rows.filter(r => r.subtype === 'Item').length;
  const visibleItemCount = visibleRows.filter(r => r.subtype === 'Item').length;
  const visibleFolderCount = visibleRows.filter(r => r.subtype === 'Folder').length;

  return (
    <div className="folder-tree">
      <div className="folder-tree-toolbar">
        <span className="folder-tree-stats">
          {filterActive ? (
            t('nav:folderTree.statsFiltered', {
              visibleEntries: visibleItemCount,
              totalEntries: itemCount,
              visibleFolders: visibleFolderCount,
              totalFolders: folderCount,
            })
          ) : (
            t('nav:folderTree.stats', {
              entries: itemCount,
              folders: folderCount,
              files: fileCount,
            })
          )}
        </span>
        <BulkToggleGroup>
          <BulkToggleButton
            icon={<ExpandAllIcon />}
            label={t('nav:folderTree.expandAll') as string}
            onClick={expandAll}
            disabled={filterActive}
            title={filterActive ? (t('nav:folderTree.disabledDuringFilter') as string) : undefined}
          />
          <BulkToggleButton
            icon={<CollapseAllIcon />}
            label={t('nav:folderTree.collapseAll') as string}
            onClick={collapseAll}
            disabled={filterActive}
            title={filterActive ? (t('nav:folderTree.disabledDuringFilter') as string) : undefined}
          />
        </BulkToggleGroup>
      </div>

      <div ref={parentRef} className="folder-tree-scroll">
        <div
          style={{
            height: `${virtualizer.getTotalSize()}px`,
            width: '100%',
            position: 'relative',
          }}
        >
          {virtualizer.getVirtualItems().map(vi => {
            const row = visibleRows[vi.index];
            const isFolder = row.subtype === 'Folder';
            const isFile = row.subtype === 'File';
            const isContainer = isFolder || isFile;
            const isSeparator = row.subtype === 'Separator';
            const isExpanded = isContainer && (filterActive || expanded.has(row.uuid));
            const indent = row.nesting_level * INDENT_PX;

            return (
              <div
                // Render-Key MUSS global eindeutig sein: `sequence` (= fh.seq) ist
                // datei-lokal (jede Datei startet bei 0), und `uuid` ist bei geklonten/
                // gemergten Dateibeständen nicht global eindeutig. Ohne `file` kollidieren
                // im "All files"-Modus zwei Zeilen auf demselben Key → React malt einen
                // DOM-Knoten für beide → übereinanderliegende Zeilen (Badge/Name verschmiert).
                // (File_Name, seq) ist im Datenmodell garantiert eindeutig.
                key={`${row.file}-${row.uuid}-${row.sequence}`}
                className={`folder-tree-row folder-tree-row-${row.subtype.toLowerCase()}`}
                style={{
                  position: 'absolute',
                  top: 0,
                  left: 0,
                  width: '100%',
                  height: `${vi.size}px`,
                  transform: `translateY(${vi.start}px)`,
                }}
              >
                {isSeparator ? (
                  <div className="folder-tree-separator" style={{ paddingLeft: indent + 8 }}>
                    <hr />
                  </div>
                ) : (
                  <div
                    className="folder-tree-item"
                    style={{ paddingLeft: indent + 8 }}
                    role="button"
                    tabIndex={0}
                    aria-expanded={isContainer ? isExpanded : undefined}
                    onClick={() => {
                      // Container (Folder/Datei) klappen auf; Datei-Knoten haben
                      // keine Detail-Seite, navigieren also nie.
                      if (isContainer && !filterActive) toggleFolder(row.uuid);
                      else if (!isFile) handleItemClick(row);
                    }}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        if (isContainer && !filterActive) toggleFolder(row.uuid);
                        else if (!isFile) handleItemClick(row);
                      }
                    }}
                  >
                    <DisclosureChevron open={isContainer ? isExpanded : null} />
                    <span className={`folder-tree-badge folder-tree-badge-${row.type.toLowerCase()}`}>
                      {badgeForType(row.type)}
                    </span>
                    <span className="folder-tree-name">{row.name || (t('nav:folderTree.noName') as string)}</span>
                    {/* Datei-Header: rechte Datei-Spalte wäre redundant zum Namen */}
                    {!isFile && <span className="folder-tree-file">{row.file}</span>}
                    {isFolder && (
                      <button
                        type="button"
                        className="folder-tree-detail-link"
                        title={t('nav:folderTree.folderDetailsTitle') as string}
                        onClick={(e) => {
                          e.stopPropagation();
                          handleItemClick(row);
                        }}
                      >
                        Details
                      </button>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
};

function badgeForType(type: string): string {
  switch (type) {
    case 'File':           return 'FILE';
    case 'Folder':         return 'DIR';
    case 'Script':         return 'SCR';
    case 'Layout':         return 'LAY';
    case 'CustomFunction': return 'CF';
    default:               return '';
  }
}
