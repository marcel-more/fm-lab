import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { buildBreadcrumb } from '../lib/navigation';
import { PlatformTags } from '../components/PlatformTags';
import { useApiLang } from '../hooks/useApiLang';
import {
  fetchStepLangs,
  fetchStepGrammar,
  resolveHelpHref,
  buildDocsEntryPath,
  OS_LABELS,
  type StepAllLangs,
  type StepGrammar,
  type StepOption,
} from '../api/fmSpecApi';
import { buildHullTree, buildOptionLookup, groupBindings } from '../lib/fmSpecGrammar';
import type { HullNode, OptionLookup } from '../lib/fmSpecGrammar';
import './FmSpecView.css';

// Bug-registry kinds in step_constraints (fm_spec >= 1.14.4) — rendered with
// a badge: warning class, never a validity rule (the step is valid, the risk
// lies with FileMaker's own serialization).
const KNOWN_BUG_KINDS = new Set([
  'clipboard_loss', 'version_skew', 'save_corruption',
  'serialization_unstable', 'localized_build_defect',
]);
// Export-gap kind (fm_spec >= 2.7.0): a slot the SaXML export never carries —
// not a defect of the snippet (the clipboard form is complete), but a catalog
// built from the export cannot show it. Rows are scoped by coverage.
const EXPORT_GAP_KIND = 'saxml_omission';

/** Registry details are long prose — collapse behind the first sentence. */
function ConstraintDetail({ detail }: { detail: string | null }) {
  if (!detail) return null;
  const firstSentence = detail.split('. ')[0];
  if (detail.length <= 200 || firstSentence.length >= detail.length - 1) {
    return <span className="fmspec-constraint__detail">{detail}</span>;
  }
  return (
    <details className="fmspec-constraint__detail">
      <summary>{firstSentence}.</summary>
      {detail}
    </details>
  );
}

/**
 * Override badge of a shape row (fm_spec >= 2.0.0): a row whose `coverage`
 * is not '*' replaces the standard row of the same key for that coverage.
 */
/** Skeleton hulls as the tree they describe — nested lists in template order. */
function HullList({ nodes, lookup }: { nodes: HullNode[]; lookup: OptionLookup }) {
  const { t } = useTranslation(['fmSpec']);
  return (
    <ul className="fmspec-repeat-groups fmspec-hull-tree">
      {nodes.map(({ row: s, orphan, children }, i) => (
        <li key={`${s.parentTag}/${s.childTag}/${i}`}>
          <span className="fmspec-rg__label mono">
            {`<${s.childTag}>`} <CoverageBadge coverage={s.coverage} />
          </span>
          <span className="fmspec-rg__meta">
            {orphan && (
              <>{t('fmSpec:step.grammar.sk.in', { parent: `<${s.parentTag}>` })}{' · '}</>
            )}
            {t(`fmSpec:step.grammar.sk.${s.keepMode}`, { defaultValue: s.keepMode })}
            {s.conditionOption && (
              <> · {t('fmSpec:step.grammar.sk.condition', {
                cond: lookup.condition(s.conditionOption, [s.conditionValue]),
              })}</>
            )}
            {s.evidence && (
              <> · {s.evidence}{s.verifiedVersion ? ` · ${s.verifiedVersion}` : ''}</>
            )}
          </span>
          {children.length > 0 && <HullList nodes={children} lookup={lookup} />}
        </li>
      ))}
    </ul>
  );
}

function CoverageBadge({ coverage }: { coverage?: string | null }) {
  const { t } = useTranslation(['fmSpec']);
  if (!coverage || coverage === '*') return null;
  return (
    <span
      className="fmspec-tag fmspec-tag--coverage"
      title={t('fmSpec:step.grammar.overrideHint', { coverage }) as string}
    >
      {t('fmSpec:step.grammar.overrideBadge', { coverage })}
    </span>
  );
}

/**
 * fm-spec ScriptStep-Detail (`/fm-spec/step/:stepId`).
 *
 * Vier Abschnitte untereinander: (1) lokalisierte Step-Daten über alle Sprachen,
 * (2) strukturierte Parameter (Sprache umschaltbar), (3) XMLSnippet-Grammatik
 * (nur wenn erfasst, sonst Hinweis), (4) SaXML-Details. Read-only.
 */
export function FmSpecStepView() {
  const { stepId } = useParams();
  const { t } = useTranslation(['fmSpec', 'nav']);
  const uiLang = useApiLang();
  const dash = t('fmSpec:dash');

  const [data, setData] = useState<StepAllLangs | null>(null);
  const [grammar, setGrammar] = useState<StepGrammar | null>(null);
  const [grammarAvailable, setGrammarAvailable] = useState<boolean | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  // shape coverage the grammar is resolved for (fm_spec >= 2.0.0); null =
  // the reference's base coverage — the server reports the resolved value
  const [coverage, setCoverage] = useState<string | null>(null);

  useEffect(() => {
    if (!stepId) return;
    let cancelled = false;
    setData(null); setErr(null);
    fetchStepLangs(stepId)
      .then((d) => { if (!cancelled) setData(d); })
      .catch((e) => { if (!cancelled) setErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [stepId, uiLang]);

  useEffect(() => {
    if (!stepId) return;
    let cancelled = false;
    setGrammar(null); setGrammarAvailable(null);
    fetchStepGrammar(stepId, coverage)
      .then((g) => { if (!cancelled) { setGrammar(g); setGrammarAvailable(g != null); } })
      .catch(() => { if (!cancelled) setGrammarAvailable(false); });
    return () => { cancelled = true; };
  }, [stepId, coverage]);

  // reset the coverage choice when navigating to another step
  useEffect(() => { setCoverage(null); }, [stepId]);

  const coverages = grammar?.coverages ?? [];
  const activeCoverage = grammar?.coverage ?? null;
  const baseCoverage = coverages.find((c) => c.isBase)?.coverage ?? null;
  const hasOverridesForActive = activeCoverage != null
    && (grammar?.overrideCoverages ?? []).includes(activeCoverage);

  const stepName = data?.canonicalName ?? (stepId ? `Step ${stepId}` : '');
  const breadcrumbs = buildBreadcrumb({ kind: 'fmSpecStep', stepName }, t);

  // Parameter folgen der globalen UI-Sprache (kein eigener Selektor mehr);
  // fällt auf den ersten verfügbaren Eintrag zurück, falls die Sprache fehlt.
  // reader-friendly shape of the grammar rows (lib/fmSpecGrammar): option
  // labels + enum display texts, requires/excludes grouped into their value
  // sets, skeleton hulls as a tree in template order
  const lookup = useMemo(() => buildOptionLookup(grammar?.options), [grammar]);
  const bindingGroups = useMemo(() => groupBindings(grammar?.elementBindings), [grammar]);
  const hullTree = useMemo(
    () => buildHullTree(grammar?.skeletonElements, grammar?.xmlMap?.snippetTemplate),
    [grammar],
  );
  const paramEntry = useMemo(
    () => data?.langs.find((l) => l.language === uiLang) ?? data?.langs[0] ?? null,
    [data, uiLang],
  );

  const copyTemplate = () => {
    if (!grammar?.xmlMap?.snippetTemplate) return;
    navigator.clipboard?.writeText(grammar.xmlMap.snippetTemplate).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    }).catch(() => { /* clipboard unavailable — ignore */ });
  };

  return (
    <div className="app fmspec-view">
      <SubNav breadcrumbs={breadcrumbs} />
      <StatusBar />

      <div className="fmspec-page">
        <header className="fmspec-header">
          <h1 className="fmspec-title">
            {stepName}
            {data && <span className="fmspec-title__id">#{data.stepId}</span>}
            {/* Gegenrichtung zur Claris-Doku-Seite — nur wenn das Docset
                installiert ist und die Seite dort existiert (Server-Check). */}
            {data?.docsEntry && (
              <Link className="fmspec-title__doclink" to={buildDocsEntryPath(data.docsEntry, uiLang)!}>
                {t('fmSpec:clarisHelp')}
              </Link>
            )}
          </h1>
          {data && (
            <p className="fmspec-subtitle">
              {t('fmSpec:step.slug')}: <span className="mono">{data.urlSlug}</span>
              {' · '}{t('fmSpec:steps.col.categoryId')}: {data.categoryId}
              {' · '}{t('fmSpec:steps.col.originVersion')}: {data.originVersion ?? dash}
            </p>
          )}
          {/* Plattform-Kompatibilität (Claris-Tabelle step_compat, tri-state):
              gelistet werden Yes + Partial; Partial ist markiert und NIE als
              „undokumentiert" zu lesen. false-Plattformen werden weggelassen. */}
          {data?.compat && (
            <p className="fmspec-subtitle">
              <PlatformTags compat={data.compat} label={t('fmSpec:step.compat.label') as string} />
            </p>
          )}
          {/* OS-Bindung (Referenz ≥ 1.13.0, step_os_affinity): kuratierte
              OS-Aussagen aus der Claris-Prosa — exclusive / unsupported
              (quellentreu invers) / variant. OS-Namen sind Eigennamen. */}
          {data && (data.osAffinity?.length ?? 0) > 0 && (
            <p className="fmspec-subtitle fmspec-platform-line">
              {t('fmSpec:osAffinity.label')}:{' '}
              {data.osAffinity!.map((a) => (
                <span
                  key={`${a.affinity}-${a.os}`}
                  className={`fmspec-tag fmspec-tag--platform fmspec-tag--os-${a.affinity}`}
                  title={`${t(`fmSpec:osAffinity.hint_${a.affinity}`)}${a.note ? ` — ${a.note}` : ''}`}
                >
                  {a.os ? OS_LABELS[a.os] ?? a.os : ''}
                  {a.os ? ' · ' : ''}
                  {t(`fmSpec:osAffinity.word_${a.affinity}`)}
                </span>
              ))}
            </p>
          )}
        </header>

        {err && <div className="fmspec-error">{t('fmSpec:error')}: {err}</div>}
        {!data && !err && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}

        {data && (
          <>
            {/* ── Abschnitt: strukturierte Parameter (folgt globaler UI-Sprache) ── */}
            <section className="fmspec-section">
              <h2 className="fmspec-section__title">{t('fmSpec:step.section.parameters')}</h2>
              {paramEntry && paramEntry.parameters.length > 0 ? (
                <div className="fmspec-table-wrap">
                  <table className="fmspec-table">
                    <thead>
                      <tr>
                        <th className="num">{t('fmSpec:params.col.index')}</th>
                        <th>{t('fmSpec:params.col.name')}</th>
                        <th>{t('fmSpec:params.col.description')}</th>
                      </tr>
                    </thead>
                    <tbody>
                      {paramEntry.parameters.map((p) => (
                        <tr key={p.index}>
                          <td className="num">{p.index}</td>
                          <td>{p.name ?? dash}</td>
                          <td>{p.description ?? dash}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : (
                <div className="fmspec-muted">{t('fmSpec:step.params.none')}</div>
              )}
            </section>

            {/* ── Abschnitt 3: XMLSnippet-Grammatik ── */}
            <section className="fmspec-section">
              <h2 className="fmspec-section__title">{t('fmSpec:step.section.grammar')}</h2>
              {grammarAvailable === false && (
                <div className="fmspec-notice">{t('fmSpec:step.grammar.notAvailable')}</div>
              )}
              {grammar && coverages.length > 1 && (
                <div className="fmspec-coverage-switch" title={t('fmSpec:step.grammar.coverageHint') as string}>
                  <span className="fmspec-coverage-switch__label">{t('fmSpec:step.grammar.coverage')}:</span>
                  {coverages.map((c) => (
                    <button
                      key={c.coverage}
                      type="button"
                      className={`fmspec-coverage-switch__btn${activeCoverage === c.coverage ? ' is-active' : ''}`}
                      onClick={() => setCoverage(c.coverage === baseCoverage ? null : c.coverage)}
                      title={c.pairedVersion ? `paired ${c.pairedVersion}${c.saxmlVersion ? ` · SaXML ${c.saxmlVersion}` : ''}` : undefined}
                    >
                      FM {c.coverage}{c.isBase ? ` · ${t('fmSpec:step.grammar.coverageBase')}` : ''}
                    </button>
                  ))}
                  {activeCoverage != null && activeCoverage !== baseCoverage && !hasOverridesForActive && (
                    <span className="fmspec-muted"> · {t('fmSpec:step.grammar.noOverrides')}</span>
                  )}
                </div>
              )}
              {grammar?.xmlMap && (
                <div className="fmspec-grammar">
                  <div className="fmspec-codeblock">
                    <div className="fmspec-codeblock__head">
                      <span>{t('fmSpec:step.grammar.template')} <CoverageBadge coverage={grammar.xmlMap.coverage} /></span>
                      <button type="button" className="fmspec-copy" onClick={copyTemplate}>
                        {copied ? t('fmSpec:step.grammar.copied') : t('fmSpec:step.grammar.copy')}
                      </button>
                    </div>
                    <pre><code>{grammar.xmlMap.snippetTemplate}</code></pre>
                  </div>

                  <dl className="fmspec-facts">
                    <dt>{t('fmSpec:step.grammar.elementOrder')}</dt>
                    <dd className="mono">{grammar.xmlMap.elementOrder ?? dash}</dd>
                    {grammar.xmlMap.targetSlotKind && (
                      <>
                        <dt>{t('fmSpec:step.grammar.targetSlotKind')}</dt>
                        <dd>{t(`fmSpec:step.grammar.opt.slot_${grammar.xmlMap.targetSlotKind}`, { defaultValue: grammar.xmlMap.targetSlotKind })}</dd>
                      </>
                    )}
                    {grammar.xmlMap.variableTargetMarker === true && (
                      <>
                        <dt>{t('fmSpec:step.grammar.variableTargetMarker')}</dt>
                        <dd>{t('fmSpec:step.grammar.variableTargetMarkerHint')}</dd>
                      </>
                    )}
                    <dt>{t('fmSpec:step.grammar.evidence')}</dt>
                    <dd>{grammar.xmlMap.evidence ?? dash}{grammar.xmlMap.verifiedVersion ? ` · ${grammar.xmlMap.verifiedVersion}` : ''}</dd>
                  </dl>

                  {grammar.options.length > 0 && (
                    <>
                      <div className="fmspec-subhead">{t('fmSpec:step.grammar.options')}</div>
                      <div className="fmspec-table-wrap">
                        <table className="fmspec-table fmspec-table--compact">
                          <thead>
                            <tr>
                              <th>{t('fmSpec:step.grammar.opt.key')}</th>
                              <th>{t('fmSpec:step.grammar.opt.type')}</th>
                              <th>{t('fmSpec:step.grammar.opt.required')}</th>
                              <th>{t('fmSpec:step.grammar.opt.label')}</th>
                              <th>{t('fmSpec:step.grammar.opt.xmlPath')}</th>
                              <th>{t('fmSpec:step.grammar.opt.evidence')}</th>
                            </tr>
                          </thead>
                          <tbody>
                            {grammar.options.map((o) => (
                              <FragmentOption key={o.optionKey} o={o} dash={dash} valuesLabel={t('fmSpec:step.grammar.opt.values') as string} />
                            ))}
                          </tbody>
                        </table>
                      </div>
                    </>
                  )}

                  {grammar.constraints.length > 0 && (
                    <>
                      <div className="fmspec-subhead">{t('fmSpec:step.grammar.constraints')}</div>
                      <ul className="fmspec-constraints">
                        {grammar.constraints.map((c) => (
                          <li key={`${c.constraintKind}@${c.coverage ?? '*'}`}>
                            <span className="fmspec-constraint__kind mono">
                              {c.constraintKind}
                              {KNOWN_BUG_KINDS.has(c.constraintKind) && (
                                <span
                                  className="fmspec-constraint__badge"
                                  title={t('fmSpec:step.grammar.knownBugHint') as string}
                                >
                                  FM bug
                                </span>
                              )}
                              {c.constraintKind === EXPORT_GAP_KIND && (
                                <span
                                  className="fmspec-constraint__badge"
                                  title={t('fmSpec:step.grammar.saxmlGapHint') as string}
                                >
                                  SaXML gap
                                </span>
                              )}
                              {c.coverage && c.coverage !== '*' && (
                                <span
                                  className="fmspec-constraint__version"
                                  title={t('fmSpec:step.grammar.constraintCoverageHint', { coverage: c.coverage }) as string}
                                >
                                  FM {c.coverage}
                                </span>
                              )}
                              {c.verifiedVersion && (
                                <span className="fmspec-constraint__version">{c.verifiedVersion}</span>
                              )}
                            </span>
                            <ConstraintDetail detail={c.detail} />
                            {c.consumerNote && (
                              <div className="fmspec-muted">
                                {t('fmSpec:step.grammar.consumerNote')}: {c.consumerNote}
                              </div>
                            )}
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                  {(grammar.repeatGroups?.length ?? 0) > 0 && (
                    <>
                      <div className="fmspec-subhead">{t('fmSpec:step.grammar.repeatGroups')}</div>
                      <ul className="fmspec-repeat-groups">
                        {grammar.repeatGroups!.map((g) => (
                          <li key={g.groupKey}>
                            <span className="fmspec-rg__label mono">{g.groupLabel}</span>
                            <CoverageBadge coverage={g.coverage} />
                            <span className="fmspec-rg__meta">
                              {t('fmSpec:step.grammar.rg.container')}: <code>{g.containerPath}</code>
                              {' · '}{g.itemForm}
                              {g.maxItems != null && (
                                <> · {t('fmSpec:step.grammar.rg.fixedSlots', { n: g.maxItems })}
                                  {g.padMode ? ` (${g.padMode})` : ''}</>
                              )}
                              {g.parentGroup && (
                                <> · {t('fmSpec:step.grammar.rg.nestedIn', { parent: g.parentGroup })}</>
                              )}
                              {g.countAttr && (
                                <> · {t('fmSpec:step.grammar.rg.countAttr', { attr: `@${g.countAttr}` })}</>
                              )}
                              {g.evidence && (
                                <> · {g.evidence}{g.verifiedVersion ? ` · ${g.verifiedVersion}` : ''}</>
                              )}
                            </span>
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                  {hullTree.length > 0 && (
                    <>
                      <div className="fmspec-subhead" title={t('fmSpec:step.grammar.sk.help') as string}>
                        {t('fmSpec:step.grammar.skeletons')}
                      </div>
                      <HullList nodes={hullTree} lookup={lookup} />
                    </>
                  )}

                  {bindingGroups.length > 0 && (
                    <>
                      <div className="fmspec-subhead" title={t('fmSpec:step.grammar.bd.help') as string}>
                        {t('fmSpec:step.grammar.bindings')}
                      </div>
                      <ul className="fmspec-repeat-groups">
                        {bindingGroups.map((b, i) => (
                          <li key={`${b.elementPath}/${b.binding}/${b.optionKey ?? ''}/${i}`}>
                            <span className="fmspec-rg__label mono">{`<${b.elementPath.split('/').pop()}>`}</span>
                            <CoverageBadge coverage={b.coverage} />
                            <span className="fmspec-rg__meta">
                              {b.elementPath.includes('/') && (
                                <><code>{b.elementPath}</code>{' · '}</>
                              )}
                              {b.binding === 'requires' && t('fmSpec:step.grammar.bd.requires', {
                                cond: lookup.condition(b.optionKey, b.optionValues),
                              })}
                              {b.binding === 'excludes' && t('fmSpec:step.grammar.bd.excludes', {
                                cond: lookup.condition(b.optionKey, b.optionValues),
                              })}
                              {b.binding === 'requires_option' && t('fmSpec:step.grammar.bd.requiresOption', {
                                option: lookup.option(b.optionKey),
                              })}
                              {b.binding === 'excludes_option' && t('fmSpec:step.grammar.bd.excludesOption', {
                                option: lookup.option(b.optionKey),
                              })}
                              {b.binding === 'suppress_empty' && t('fmSpec:step.grammar.bd.suppressEmpty')}
                              {b.evidence && (
                                <> · {b.evidence}{b.verifiedVersion ? ` · ${b.verifiedVersion}` : ''}</>
                              )}
                            </span>
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                  {(grammar.mirrorElements?.length ?? 0) > 0 && (
                    <>
                      <div className="fmspec-subhead" title={t('fmSpec:step.grammar.mr.help') as string}>
                        {t('fmSpec:step.grammar.mirrors')}
                      </div>
                      <ul className="fmspec-repeat-groups">
                        {grammar.mirrorElements!.map((m, i) => (
                          <li key={`${m.sourceOption}/${m.targetPath}/${i}`}>
                            <span className="fmspec-rg__label mono">{`<${m.targetPath.split('/').pop()}>`}</span>
                            <CoverageBadge coverage={m.coverage} />
                            <span className="fmspec-rg__meta">
                              <code>{`Step/${m.targetPath}`}</code>{' · '}
                              {t(`fmSpec:step.grammar.mr.${m.trigger}`, {
                                option: lookup.option(m.sourceOption), defaultValue: m.trigger,
                              })}
                              {m.evidence && (
                                <> · {m.evidence}{m.verifiedVersion ? ` · ${m.verifiedVersion}` : ''}</>
                              )}
                            </span>
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                  {(grammar.optionImplications?.length ?? 0) > 0 && (
                    <>
                      <div className="fmspec-subhead" title={t('fmSpec:step.grammar.imp.help') as string}>
                        {t('fmSpec:step.grammar.implications')}
                      </div>
                      <ul className="fmspec-repeat-groups">
                        {grammar.optionImplications!.map((im, i) => (
                          <li key={`${im.triggerKind}/${im.trigger}/${i}`}>
                            <span className="fmspec-rg__label mono">{im.trigger}</span>
                            <span className="fmspec-rg__meta">
                              {t(`fmSpec:step.grammar.imp.${im.triggerKind}`, { defaultValue: im.triggerKind })}
                              {' → '}
                              <code>
                                {lookup.option(im.impliedOption)}
                                {im.impliedValue != null ? ` = ${lookup.value(im.impliedOption, im.impliedValue)}` : ''}
                              </code>
                              {im.isDefault && <> · {t('fmSpec:step.grammar.imp.default')}</>}
                              {im.evidence && (
                                <> · {im.evidence}{im.verifiedVersion ? ` · ${im.verifiedVersion}` : ''}</>
                              )}
                            </span>
                          </li>
                        ))}
                      </ul>
                    </>
                  )}

                </div>
              )}
            </section>

            {/* ── Abschnitt 4: SaXML-Details ── */}
            <section className="fmspec-section">
              <h2 className="fmspec-section__title">{t('fmSpec:step.section.saxml')}</h2>
              {grammar?.xmlMap ? (
                <>
                  <dl className="fmspec-facts">
                    <dt>{t('fmSpec:step.saxml.paramTypes')}</dt>
                    <dd className="mono">{grammar.xmlMap.saxmlParamTypes ?? dash}</dd>
                    <dt>{t('fmSpec:step.grammar.evidence')}</dt>
                    <dd>{grammar.xmlMap.evidence ?? dash}{grammar.xmlMap.verifiedVersion ? ` · ${grammar.xmlMap.verifiedVersion}` : ''}</dd>
                  </dl>
                  {grammar.xmlMap.saxmlExample && (
                    <div className="fmspec-codeblock">
                      <div className="fmspec-codeblock__head">
                        <span>{t('fmSpec:step.saxml.example')}</span>
                      </div>
                      <pre><code>{grammar.xmlMap.saxmlExample}</code></pre>
                    </div>
                  )}
                  <p className="fmspec-hint">{t('fmSpec:step.saxml.hint')}</p>
                  <p className="fmspec-footnote">{t('fmSpec:step.saxml.sourceNote')}</p>
                </>
              ) : (
                <div className="fmspec-muted">{t('fmSpec:step.saxml.none')}</div>
              )}
            </section>

            {/* ── Abschnitt: lokalisierte Step-Daten (ans Ende geschoben) ── */}
            <section className="fmspec-section">
              <h2 className="fmspec-section__title">{t('fmSpec:step.section.localized')}</h2>
              <div className="fmspec-table-wrap">
                <table className="fmspec-table">
                  <thead>
                    <tr>
                      <th>{t('fmSpec:step.localized.language')}</th>
                      <th>{t('fmSpec:step.localized.displayName')}</th>
                      <th>{t('fmSpec:step.localized.description')}</th>
                      <th>{t('fmSpec:step.localized.help')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.langs.map((l) => {
                      const href = resolveHelpHref(l.localHelpUrl, l.helpUrl);
                      return (
                        <tr key={l.language}>
                          <td className="mono">{l.language}</td>
                          <td>{l.displayName}</td>
                          <td>{l.description ?? dash}</td>
                          <td>
                            {href
                              ? <a href={href} target="_blank" rel="noreferrer">{t('fmSpec:help.open')}</a>
                              : dash}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>
          </>
        )}
      </div>
    </div>
  );
}

function FragmentOption({
  o,
  dash,
  valuesLabel,
}: {
  o: StepOption;
  dash: string;
  valuesLabel: string;
}) {
  const { t } = useTranslation(['fmSpec']);
  const [open, setOpen] = useState(false);
  const hasValues = o.values.length > 0;
  // any value whose evidence deviates from the option row is worth a badge;
  // pre-1.7.0 references deliver evidence=null → no badges, no toggle hint
  const hasDeviantEvidence = o.values.some((v) => v.evidence != null && v.evidence !== o.evidence);
  const isBool = o.optionType === 'boolean' && (o.trueText != null || o.falseText != null);
  // curated XML value domain of a boolean attribute (fm_spec >= 2.2.0)
  const hasXmlDomain = o.optionType === 'boolean' && o.xmlTrue != null && o.xmlFalse != null;
  return (
    <>
      <tr>
        <td className="mono">
          {o.optionKey} <CoverageBadge coverage={o.coverage} />
          {o.pasteDropped && (
            <span className="fmspec-badge fmspec-badge--dropped" title={t('fmSpec:step.grammar.opt.pasteDroppedHint') as string}>
              {t('fmSpec:step.grammar.opt.pasteDropped')}
            </span>
          )}
        </td>
        <td>
          {o.optionType}
          {hasValues && (
            <button type="button" className="fmspec-values-toggle" onClick={() => setOpen((v) => !v)}>
              {valuesLabel} ({o.values.length}){hasDeviantEvidence ? ' ⚑' : ''}
            </button>
          )}
        </td>
        <td>{o.required ? '✓' : dash}</td>
        <td>
          {o.displayLabelEn ?? dash}
          {isBool && (
            <div className="fmspec-bool-map">
              <span className="mono">{o.trueText ?? 'On'}</span>{' → True · '}
              <span className="mono">{o.falseText ?? 'Off'}</span>{' → False'}
              {o.invertedLabel && (
                <span className="fmspec-inverted" title={t('fmSpec:step.grammar.opt.invertedHint') as string}>
                  {' '}⇄
                </span>
              )}
            </div>
          )}
          {hasXmlDomain && (
            <div className="fmspec-bool-map">
              {t('fmSpec:step.grammar.opt.xmlDomain')}: <span className="mono">{o.xmlTrue}</span>{' / '}<span className="mono">{o.xmlFalse}</span>
            </div>
          )}
          {o.slotKind && (
            <div className="fmspec-bool-map">
              {t('fmSpec:step.grammar.opt.slotKind')}: {t(`fmSpec:step.grammar.opt.slot_${o.slotKind}`, { defaultValue: o.slotKind })}
            </div>
          )}
        </td>
        <td className="mono">{o.xmlPath ?? dash}</td>
        <td>{o.evidence ?? dash}</td>
      </tr>
      {open && hasValues && (
        <tr className="fmspec-detail-row">
          <td colSpan={6}>
            <table className="fmspec-subtable">
              <tbody>
                {o.values.map((v) => (
                  <tr key={v.xmlValue}>
                    <td className="mono">{v.xmlValue}</td>
                    <td>{v.displayTextEn ?? dash}</td>
                    <td>
                      {v.evidence != null && v.evidence !== o.evidence && (
                        <span
                          className={`fmspec-evidence-badge${v.evidence === 'claris-doc' ? ' fmspec-evidence-badge--doc' : ''}`}
                          title={v.evidence === 'claris-doc' ? (t('fmSpec:step.grammar.opt.docOnly') as string) : undefined}
                        >
                          {v.evidence}
                        </span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </td>
        </tr>
      )}
    </>
  );
}

export default FmSpecStepView;
