import type { PrimitiveComponent } from '../types';
import { Grid } from './Grid';
import { Card } from './Card';
import { Stack } from './Stack';
import { Row } from './Row';
import { KPI } from './KPI';
import { KPIStrip } from './KPIStrip';
import { DefinitionList } from './DefinitionList';
import { List } from './List';
import { TileGrid } from './TileGrid';
import { Table } from './Table';
import { AutoTable } from './AutoTable';
import { Slider } from './Slider';
import { FilterChips } from './FilterChips';
import { ToggleChips } from './ToggleChips';
import { Select } from './Select';
import { MarkdownBlock } from './MarkdownBlock';
import { HtmlContent } from './HtmlContent';
import { NavButton } from './NavButton';
import { Empty } from './Empty';
import { Spacer } from './Spacer';
import { UnknownPrimitive } from './UnknownPrimitive';
import { DocsInstallErrorBezel } from './DocsInstallErrorBezel';
import { DocsetInstallControl } from './DocsetInstallControl';
import { XmlConvertControl } from './XmlConvertControl';
import { ResultsRunControl } from './ResultsRunControl';
import { XmlConvertLog } from './XmlConvertLog';
import { XmlEmptyStateCard } from './XmlEmptyStateCard';
import { SemanticNamesStatus } from './SemanticNamesStatus';
import { XmlImportIntegrity } from './XmlImportIntegrity';
import { CalendarHeatmap, StackedTimeSeries, Sparkline } from './Charts';
import { ScopeNotice } from './ScopeNotice';
import { registerInlineControl } from './inlineControls';

const registry = new Map<string, PrimitiveComponent>();

export function registerPrimitive(name: string, component: PrimitiveComponent): void {
  registry.set(name, component);
}

export function getPrimitive(name: string): PrimitiveComponent {
  return registry.get(name) ?? UnknownPrimitive;
}

// Default-Registrierung
registerPrimitive('Grid', Grid);
registerPrimitive('Card', Card);
registerPrimitive('Stack', Stack);
registerPrimitive('Row', Row);
registerPrimitive('KPI', KPI);
registerPrimitive('KPIStrip', KPIStrip);
registerPrimitive('DefinitionList', DefinitionList);
registerPrimitive('List', List);
registerPrimitive('TileGrid', TileGrid);
registerPrimitive('Table', Table);
registerPrimitive('AutoTable', AutoTable);
registerPrimitive('Slider', Slider);
registerPrimitive('FilterChips', FilterChips);
registerPrimitive('ToggleChips', ToggleChips);
registerPrimitive('Select', Select);
registerPrimitive('Markdown', MarkdownBlock);
registerPrimitive('HtmlContent', HtmlContent);
registerPrimitive('NavButton', NavButton);
registerPrimitive('Empty', Empty);
registerPrimitive('Spacer', Spacer);
registerPrimitive('DocsInstallErrorBezel', DocsInstallErrorBezel);
registerPrimitive('XmlConvertControl', XmlConvertControl);
registerPrimitive('ResultsRunControl', ResultsRunControl);
registerPrimitive('XmlConvertLog', XmlConvertLog);
registerPrimitive('XmlEmptyStateCard', XmlEmptyStateCard);
registerPrimitive('SemanticNamesStatus', SemanticNamesStatus);
registerPrimitive('XmlImportIntegrity', XmlImportIntegrity);
registerPrimitive('CalendarHeatmap', CalendarHeatmap);
registerPrimitive('StackedTimeSeries', StackedTimeSeries);
registerPrimitive('Sparkline', Sparkline);
registerPrimitive('ScopeNotice', ScopeNotice);

// Inline-Controls (rendered inside List rows when rowTemplate.inlineControl is set)
registerInlineControl('docsInstall', DocsetInstallControl);
