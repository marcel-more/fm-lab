import React, { useEffect, useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useLayoutData } from '../hooks/useLayoutData';
import { useCurrentFile } from '../lib/currentFileContext';
import { LayoutCanvas, type LayoutCanvasHandle } from './LayoutCanvas';
import { LayoutViewer } from './LayoutViewer';
import { usePersistentState } from '../hooks/usePersistentState';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import { ScriptDetail } from './ScriptDetail';
import { ScriptStepDetail } from './ScriptStepDetail';
import { CalculationDetail } from './CalculationDetail';
import { CustomFunctionDetail } from './CustomFunctionDetail';
import { GenericObjectDetail } from './GenericObjectDetail';
import { LayoutObjectDetail } from './LayoutObjectDetail';
import { ScriptTriggerDetail } from './ScriptTriggerDetail';
import './CustomFunctionViewer.css';
import './FieldViewer.css';
import { CustomMenuDetail } from './CustomMenuDetail';
import { FieldDetail } from './FieldDetail';
import { PrivilegeSetDetail } from './PrivilegeSetDetail';
import { RelationshipDetail } from './RelationshipDetail';
import { ValueListDetail } from './ValueListDetail';
import { BaseTableDetail } from './BaseTableDetail';
import { BuiltinFunctionDetail } from './BuiltinFunctionDetail';
import { PluginFunctionDetail } from './PluginFunctionDetail';
import { PluginComponentDetail } from './PluginComponentDetail';
import '../views/LayoutView.css';

interface ObjectDetailProps {
  uuid: string;
  objectType: string;
  /**
   * UUIDs zum Hervorheben (Cross-Reference Highlight).
   * Wird je nach Ziel-View interpretiert:
   *  - LayoutCanvas:        matchUuids
   *  - ScriptViewer:        highlightRefUuids (Token-Match)
   *  - CustomFunctionViewer: highlightRefUuids
   */
  highlightUuids?: Set<string>;
  /**
   * Origin-Name für Substring-Highlight in Content-Views (GenericObjectDetail).
   */
  highlightText?: string | null;
  /**
   * Wird bei explizitem User-Eingriff (Suche, Typ-Filter) im LayoutCanvas
   * gefeuert, um den ref-Param aus der URL zu entfernen.
   */
  onClearRef?: () => void;
  /**
   * Liefert die im jeweiligen Viewer tatsächlich hervorgehobenen Token-
   * Vorkommen — Grundlage für die RefOriginPill, wenn der server-seitige
   * Container-Self-Link-Count die echte Anzahl unterschätzt (Script /
   * CustomFunction / Field als Token-Container).
   */
  onLiveMatchCount?: (count: number) => void;
  /**
   * Handle des eingebetteten LayoutCanvas (nur für objectType='Layout' belegt) —
   * von der DetailView für die ESC-Stufenlogik (Suche/Filter räumen) verdrahtet.
   */
  layoutCanvasRef?: React.Ref<LayoutCanvasHandle>;
}

/**
 * Embedded layout viewer used inside DetailView. Loads layout data and renders
 * the interactive LayoutCanvas — same component as the /layout/:uuid fullscreen
 * route, just inside a fixed-height container with a fullscreen link.
 */
const EmbeddedLayoutView: React.FC<{
  uuid: string;
  highlightUuids?: Set<string>;
  onClearRef?: () => void;
  onLiveMatchCount?: (count: number) => void;
  layoutCanvasRef?: React.Ref<LayoutCanvasHandle>;
}> = ({ uuid, highlightUuids, onClearRef, onLiveMatchCount, layoutCanvasRef }) => {
  const { t } = useTranslation(['common', 'detail']);
  const currentFile = useCurrentFile();
  const { data, loading, error } = useLayoutData(uuid, currentFile);
  // Browser-lokaler, persistenter Aufklapp-Status des Eigenschaften-Panels.
  // Bleibt beim Navigieren zwischen Layouts erhalten (localStorage), Default: offen.
  const [propsOpen, setPropsOpen] = usePersistentState<'0' | '1'>(
    'fmlab.layout.propsOpen', '1', ['0', '1'] as const,
  );
  // Navigation kam per `?ref=trig_<id>_…` von einem Script hierher → das
  // Eigenschaften-Panel automatisch aufklappen, damit der hervorgehobene Trigger
  // in der Liste sichtbar ist (LayoutViewer scrollt ihn zusätzlich in den View).
  const hlSig = useMemo(
    () => (highlightUuids ? Array.from(highlightUuids).sort().join(',') : ''),
    [highlightUuids],
  );
  const hasTriggerRef = useMemo(
    () => !!highlightUuids && Array.from(highlightUuids).some(u => u.startsWith('trig_')),
    [highlightUuids],
  );
  // Einmal je Ref-Set aufklappen — danach bleibt manuelles Zuklappen erhalten.
  const autoOpenedFor = React.useRef<string | null>(null);
  useEffect(() => {
    if (hasTriggerRef && autoOpenedFor.current !== hlSig) {
      autoOpenedFor.current = hlSig;
      setPropsOpen('1');
    }
  }, [hasTriggerRef, hlSig, setPropsOpen]);
  if (loading) return <LoadingSpinner message={t('detail:layoutPreview.loading') as string} />;
  if (error) return <ErrorMessage message={error} />;
  if (!data) return <div className="no-references">{t('detail:layoutPreview.empty')}</div>;
  // Objektlose Layouts: kein Canvas-Inhalt → die Eigenschaften trotzdem (immer offen)
  // zeigen, plus eine Leer-Meldung im Canvas-Bereich. Der Toggle wird dann fixiert.
  const hasObjects = data.objects.length > 0;
  const isOpen = propsOpen === '1' || !hasObjects;
  return (
    <div className="object-detail" aria-label={t('detail:layoutPreview.heading') as string}>
      <div className="layout-detail-header">
        <button
          type="button"
          className="layout-props-toggle"
          aria-expanded={isOpen}
          onClick={() => setPropsOpen(isOpen ? '0' : '1')}
          disabled={!data.meta || !hasObjects}
        >
          <span className="layout-props-caret" aria-hidden="true">{isOpen ? '▾' : '▸'}</span>
          {t('detail:layoutViewer.propertiesHeading')}
        </button>
        <Link
          to={`/layout/${uuid}`}
          className="layout-detail-fullscreen"
          title={t('common:actions.openLayoutFullscreen') as string}
        >
          {t('common:actions.fullscreen')}
        </Link>
      </div>
      {isOpen && data.meta && (
        <LayoutViewer meta={data.meta} triggers={data.triggers} originUuid={uuid} highlightUuids={highlightUuids} />
      )}
      {hasObjects ? (
        <div className="layout-detail-canvas">
          <LayoutCanvas
            ref={layoutCanvasRef}
            data={data}
            externalMatchUuids={highlightUuids}
            onClearRef={onClearRef}
            onLiveMatchCount={onLiveMatchCount}
          />
        </div>
      ) : (
        <div className="layout-detail-empty">{t('detail:layoutPreview.empty')}</div>
      )}
    </div>
  );
};

/**
 * Unified Object Detail Component.
 * - Layouts: interactive LayoutCanvas (Hover, Suche, Filter, Cross-Nav)
 * - Other types: formatted text in a code block
 */
export const ObjectDetail: React.FC<ObjectDetailProps> = ({
  uuid,
  objectType,
  highlightUuids,
  highlightText,
  onClearRef,
  onLiveMatchCount,
  layoutCanvasRef,
}) => {
  if (objectType === 'Layout') {
    return (
      <EmbeddedLayoutView
        uuid={uuid}
        highlightUuids={highlightUuids}
        onClearRef={onClearRef}
        onLiveMatchCount={onLiveMatchCount}
        layoutCanvasRef={layoutCanvasRef}
      />
    );
  }
  if (objectType === 'Script') {
    return <ScriptDetail uuid={uuid} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'ScriptStep') {
    return <ScriptStepDetail uuid={uuid} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'CustomFunction') {
    return <CustomFunctionDetail uuid={uuid} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'CustomMenu' || objectType === 'CustomMenuItem') {
    return <CustomMenuDetail uuid={uuid} objectType={objectType} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'Field') {
    return <FieldDetail uuid={uuid} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'PrivilegeSet') {
    return <PrivilegeSetDetail uuid={uuid} highlightRefUuids={highlightUuids} />;
  }
  if (objectType === 'Relationship') {
    return <RelationshipDetail uuid={uuid} />;
  }
  if (objectType === 'ValueList') {
    return <ValueListDetail uuid={uuid} />;
  }
  if (objectType === 'BaseTable') {
    return <BaseTableDetail uuid={uuid} />;
  }
  if (objectType === 'LayoutObject') {
    return <LayoutObjectDetail uuid={uuid} objectType={objectType} />;
  }
  if (objectType === 'Calculation') {
    return <CalculationDetail uuid={uuid} highlightRefUuids={highlightUuids} onLiveMatchCount={onLiveMatchCount} />;
  }
  if (objectType === 'ScriptTrigger') {
    return <ScriptTriggerDetail uuid={uuid} />;
  }
  if (objectType === 'BuiltinFunction') {
    return <BuiltinFunctionDetail uuid={uuid} />;
  }
  if (objectType === 'PluginFunction') {
    return <PluginFunctionDetail uuid={uuid} />;
  }
  if (objectType === 'PluginComponent') {
    return <PluginComponentDetail uuid={uuid} />;
  }
  return (
    <GenericObjectDetail
      uuid={uuid}
      objectType={objectType}
      highlightText={highlightText}
    />
  );
};
