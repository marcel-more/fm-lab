/**
 * Tokens Formatter
 *
 * Builds the structured `format=tokens` payload for Scripts, Custom Functions
 * and Calculations. Operates on three different shapes of input rows:
 *   - Script:         rows from object_details_script_tokens.sql
 *   - CustomFunction: rows from object_details_customfunction_tokens.sql
 *   - Calculation:    rows from object_details_calculation_tokens.sql
 *
 * The caller decides which shape via options.kind.
 */

const crypto = require('crypto');
const { isContainerPlugin } = require('../services/plugin-token-registry');

// Deterministischer md5-Hash zur Erzeugung synthetischer ObjectCatalog-UUIDs.
// Hex-output, kleinbuchstaben —
// identisch zur DuckDB-md5() Konvention im create_universal_catalogs.sql.
function md5(s) {
  return crypto.createHash('md5').update(s).digest('hex');
}

const CHUNK_TYPE_MAP = {
  NoRef: 'text',
  FunctionRef: 'function',
  CustomFunctionRef: 'customFunction',
  PluginFunctionRef: 'pluginFunction',
  VariableReference: 'variable',
  FieldRef: 'field',
  Comment: 'comment',
};

const CHUNK_RE = /^<Chunk[^>]*>([\s\S]*)<\/Chunk>$/;

// MBS-Style Container-Plugin: erstes Argument ist ein quoted String mit dem
// fachlichen Funktionsnamen. Pattern matcht den ersten doppelt-quoted String
// nach optionalem Whitespace und der öffnenden Klammer im Folge-NoRef-Chunk.
// Bsp:  '( "List.AddPrefix" ; '  →  'List.AddPrefix'
const FIRST_QUOTED_ARG_RE = /\(\s*"([^"]+)"/;

// Ergebnistyp-Präfix einer typisierten Layoutformel (<<ƒ:%N:…>>) — Kennung der
// fehlklassifizierten VariableReference-Chunks im DisplayCalculations-Kontext.
const DISPLAY_PREFIX_RE = /^%[A-Z]+:/;

// FieldRef chunks contain nested XML with FieldReference + TableOccurrenceReference.
const FIELD_REF_RE = /<FieldReference[^>]*\bname="([^"]*)"[^>]*\bUUID="([^"]*)"/;
const TO_REF_RE = /<TableOccurrenceReference[^>]*\bname="([^"]*)"/;

// FindRequestSet im Step_XML (Perform Find / Enter Find Mode / Constrain / Extend):
// <FindRequest action="find|omit"> mit je 1..n <find criteria="…"> um eine
// FieldReference. Toleranter als FIELD_REF_RE: kein UUID-Attribut vorausgesetzt.
const FIND_REQUEST_RE = /<FindRequest\b[^>]*\baction="([^"]*)"[^>]*>([\s\S]*?)<\/FindRequest>/g;
const FIND_CRITERIA_RE = /<find\b([^>]*)>([\s\S]*?)<\/find>/g;
const CRITERIA_ATTR_RE = /\bcriteria="([^"]*)"/;
const FIND_FIELD_NAME_RE = /<FieldReference\b[^>]*\bname="([^"]*)"/;

// SortList im Step_XML (Sort Records): <Sort type="Ascending|Descending|Custom">
// um PrimaryField/FieldReference; Custom trägt zusätzlich eine ValueListReference.
// \b nach "Sort" verhindert einen Match auf das umgebende <SortSpecification>.
const SORT_ENTRY_RE = /<Sort\b[^>]*\btype="([^"]*)"[^>]*>([\s\S]*?)<\/Sort>/g;
const VALUELIST_NAME_RE = /<ValueListReference\b[^>]*\bname="([^"]*)"/;

/**
 * Strip the outer <Chunk type="…">…</Chunk> wrapper.
 */
function stripChunkWrap(s) {
  if (!s) return '';
  const m = CHUNK_RE.exec(s);
  return m ? m[1] : s;
}

/**
 * Decode the small set of XML numeric character references that appear in the
 * DDR data. The raw chunks come from the FileMaker XML export, so &#xB6; etc.
 * pass through as-is.
 */
function decodeXmlEntities(s) {
  if (!s || s.indexOf('&') === -1) return s;
  return s
    .replace(/&#x([0-9A-Fa-f]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)))
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/**
 * Build a token from a raw DDR_Calculations chunk row.
 *
 * For most chunk types the token's `content` is just the inner text of the
 * Chunk wrapper. FieldRef is special: its inner XML carries field name, table
 * occurrence name and field UUID — we surface a "TO::Field" content string
 * plus the resolved UUID.
 *
 * Optionale Parameter `idx` und `allChunks` werden für die `subFunction`-
 * Auflösung von MBS-Style Container-Plugins genutzt.
 * Werden sie weggelassen (z.B. von Test-Aufrufern), bleibt das Verhalten für
 * pluginFunction-Tokens identisch zur v1 — kein `subFunction`-Feld.
 */
function tokenFromChunk(chunk, idx, allChunks) {
  const dbType = chunk.chunk_type;
  const apiType = CHUNK_TYPE_MAP[dbType] || 'text';
  const inner = stripChunkWrap(chunk.chunk_content);

  if (apiType === 'field') {
    const fieldMatch = FIELD_REF_RE.exec(inner);
    const toMatch = TO_REF_RE.exec(inner);
    if (fieldMatch) {
      // Field- und TO-Namen stammen aus dem FieldReference-Markup und tragen
      // die XML-Entities des Roh-Chunks (z.B. `g&#xFC;ltig`) — wie jeder andere
      // Token-Content müssen sie dekodiert werden (der generische `content`-Pfad
      // unten ruft decodeXmlEntities, dieser Zweig kehrt vorher zurück).
      const fieldName = decodeXmlEntities(fieldMatch[1]);
      const fieldUuid = fieldMatch[2];
      const toName = toMatch ? decodeXmlEntities(toMatch[1]) : null;
      const content = toName ? `${toName}::${fieldName}` : fieldName;
      const tok = { type: 'field', content };
      if (fieldUuid) tok.uuid = fieldUuid;
      return tok;
    }
    // Defensive fallback: malformed FieldRef — pass through as text.
    return { type: 'text', content: decodeXmlEntities(inner) };
  }

  const content = decodeXmlEntities(inner);

  // FileMaker DDR defect (display calculations, schema 1.27.0): a TYPED layout
  // calculation whose formula is a single field reference is chunked as
  // <Chunk type="VariableReference">%X:<field></Chunk> — result-type prefix plus
  // field name, no FieldRef. The calculation token template pairs such chunks
  // with the rescued field reference (P2 A.5.1b, resolved against the
  // ChunkList's context TO) — render a regular field token (canonical
  // TO::Field, clickable; the ref-highlight works again). Without a rescue
  // (external TO, renamed field, hash-alias path) fall back to plain text with
  // the prefix stripped — never a phantom variable token. Gated on the
  // template's is_display_slot flag so genuine variables in other calc roles
  // (and script/CF token shapes, which lack the column) stay untouched.
  if (
    apiType === 'variable'
    && (chunk.is_display_slot === true || chunk.is_display_slot === 'true')
    && DISPLAY_PREFIX_RE.test(content)
  ) {
    const fieldName = chunk.rescued_field_name != null ? String(chunk.rescued_field_name) : null;
    if (fieldName) {
      const toName = chunk.rescued_to_name != null ? String(chunk.rescued_to_name) : null;
      const fieldTok = { type: 'field', content: toName ? `${toName}::${fieldName}` : fieldName };
      if (chunk.rescued_field_uuid != null) fieldTok.uuid = String(chunk.rescued_field_uuid);
      return fieldTok;
    }
    const stripped = content.replace(DISPLAY_PREFIX_RE, '');
    // Präfix + '$' = echte Variable hinter dem Ergebnistyp (<<ƒ:%N:$$var>>) —
    // als Variablen-Token rendern (Scope wie der generische Variable-Pfad).
    if (stripped.startsWith('$')) {
      return { type: 'variable', content: stripped, scope: stripped.startsWith('$$') ? 'global' : 'local' };
    }
    return { type: 'text', content: stripped };
  }

  const tok = { type: apiType, content };

  if (apiType === 'variable') {
    tok.scope = content.startsWith('$$') ? 'global' : 'local';
  }

  // Container-Plugin (MBS): fachlichen Funktionsnamen auflösen.
  // Primärquelle ist `chunk.sub_function` — die Token-Templates liefern ihn
  // positionsgenau aus MBS_SubnameMap (Calc_UUID + Chunk_Index), inklusive der
  // P3.5-Klartext-Recovery; damit sind auch die DDR-Verlust-Fälle abgedeckt
  // (Kommentar am Aufruf, verschachtelte Aufrufe), bei denen der Argument-Chunk
  // in der ChunkList fehlt. Fallback bleibt die Nachbar-Chunk-Heuristik
  // (idx+1, dann idx-1) für Aufrufer, die kein sub_function mitliefern —
  // bei Multi-MBS-Calcs ist die Heuristik nicht 100% robust.
  if (apiType === 'pluginFunction' && isContainerPlugin(content)) {
    if (chunk.sub_function) {
      tok.subFunction = chunk.sub_function;
    } else if (Array.isArray(allChunks)) {
      const sub = extractSubFunctionFromNeighbors(idx, allChunks);
      if (sub) tok.subFunction = sub;
    }
  }

  // Synthetische ObjectCatalog-UUIDs für Cross-Navigation.
  // BuiltinFunction: BEWUSST NICHT hier. Der Formatter hat keine DB, konnte die
  // UUID also nur aus dem Token-Namen RECHNEN (md5('BuiltinFunction::' + name))
  // — eine dritte Kopie der Identitätsregel des Imports, die bei lokalisierten
  // Autorensprachen zwangsläufig daneben lag (`Länge` ergab eine UUID, die es
  // nicht gibt; nur die nachgelagerte Tot-Link-Bereinigung verhinderte den 404).
  // Seit Katalog-Schema 1.32.0 ist die Identität eines Built-ins der kanonische
  // englische Name der Referenz und im Katalog NACHSCHLAGBAR
  // (BuiltinFunctionIdentity): der Controller löst die Token-Namen gegen den
  // Katalog auf (object.controller.resolveBuiltinLinks) und setzt `uuid` danach —
  // der Formatter bleibt DB-frei und trägt keine Identitätsregel mehr.
  if (apiType === 'pluginFunction' && (tok.subFunction || !isContainerPlugin(content))) {
    // Der Katalog-UUID basiert auf dem vollen Plugin_Function_Name. Bei
    // Container-Plugins (MBS) ist das `<Plugin>:<SubName>` (EINFACHER Doppelpunkt),
    // NICHT nur der bloße Container-Name `MBS` — vgl. convert_xml_04_catalog.sql:
    // md5('PluginFunction::' || Plugin_Function_Name || '::' || SubName).
    // `content` trägt hier nur den Container-Namen; der SubName wird oben aus den
    // Nachbar-Chunks aufgelöst. Guard: Container-Aufrufe OHNE aufgelösten SubName
    // (dynamisches 1. Argument, `MBS($var; …)`) haben konstruktionsbedingt keinen
    // Katalog-Eintrag (P4-Block 26 filtert bare 'MBS') — die UUID wäre ein
    // garantiert toter Link („not found") und bleibt deshalb weg (Token rendert
    // unverlinkt). Non-Container-Plugins tragen den vollen Namen in `content`
    // und brauchen keinen SubName.
    const pfName = tok.subFunction ? `${content}:${tok.subFunction}` : content;
    tok.uuid = md5(`PluginFunction::${pfName}::${tok.subFunction || ''}`);
  }
  // CustomFunctionRef-Chunks tragen — anders als FieldRef — keine UUID im
  // CDATA, nur den Namen. Die Field-/CustomFunction-Token-Templates lösen ihn
  // file-lokal über ObjectHomes auf und liefern sie als `ref_uuid` mit; ohne
  // sie bliebe das Token uuidlos (kein Link, kein Cross-Reference-Highlight).
  if (apiType === 'customFunction' && chunk.ref_uuid) {
    tok.uuid = chunk.ref_uuid;
  }

  return tok;
}

/**
 * Versöhnt eine Token-Liste mit dem Plain-Text-Counterpart. FileMaker lässt im
 * DDR-XML-Export gelegentlich NoRef-Chunks weg (insbesondere zwischen einer
 * VariableReference und einem nachfolgenden PluginFunctionRef, z.B. `c = MBS(…)`),
 * sodass die Tokens beim reinen Konkatenieren Operator/Whitespace verlieren.
 *
 * Strategie: sequenzielles Vorwärts-Matching. Jedes Token wird ab der letzten
 * End-Position im Plain-Text gesucht; liegt es weiter rechts als erwartet, füllt
 * ein synthetisches `text`-Token die Lücke. Wird ein Token nicht gefunden
 * (mehrdeutiger Match, FieldRef ohne TO-Präfix im CDATA o.ä.), wird die
 * ursprüngliche Liste unverändert zurückgegeben — kein Regressionsrisiko.
 *
 * Normalisierung: CRLF/CR → LF auf beiden Seiten, weil DDR-Chunks per
 * `decodeXmlEntities` CR enthalten, das CDATA-Plain-Text aber LF.
 */
function reconcileTokensWithPlainText(tokens, plainText) {
  if (!plainText || !Array.isArray(tokens) || tokens.length === 0) return tokens;

  const norm = (s) => (typeof s === 'string' ? s.replace(/\r\n?/g, '\n') : '');
  const normPlain = norm(plainText);

  const positioned = [];
  let cursor = 0;

  for (const tok of tokens) {
    const needle = norm(tok.content);
    if (!needle) {
      positioned.push({ tok, start: cursor, end: cursor });
      continue;
    }
    const pos = normPlain.indexOf(needle, cursor);
    if (pos === -1) {
      // Token nicht im Plain-Text auffindbar — Reconcile abbrechen.
      return tokens;
    }
    positioned.push({ tok, start: pos, end: pos + needle.length });
    cursor = pos + needle.length;
  }

  const out = [];
  let prevEnd = 0;
  for (const { tok, start, end } of positioned) {
    if (start > prevEnd) {
      out.push({ type: 'text', content: normPlain.slice(prevEnd, start) });
    }
    out.push(tok);
    prevEnd = end;
  }
  if (prevEnd < normPlain.length) {
    out.push({ type: 'text', content: normPlain.slice(prevEnd) });
  }
  return out;
}

/**
 * Sucht den fachlichen MBS-Funktionsnamen in den Nachbar-NoRef-Chunks. Die
 * Calc-Engine schreibt den Aufruf-Token (`MBS`) und den ersten Argument-NoRef
 * `( "Foo.Bar"; ` direkt nebeneinander, allerdings nicht immer in derselben
 * Richtung. Wir versuchen idx+1 zuerst (häufigster Fall: prefix), dann idx-1
 * (postfix-ähnliche Notation).
 */
function extractSubFunctionFromNeighbors(idx, allChunks) {
  if (typeof idx !== 'number' || !allChunks) return null;
  for (const offset of [1, -1]) {
    const cand = allChunks[idx + offset];
    if (!cand || cand.chunk_type !== 'NoRef') continue;
    const inner = stripChunkWrap(cand.chunk_content);
    const m = FIRST_QUOTED_ARG_RE.exec(inner);
    if (m) return m[1];
  }
  return null;
}

// Anzeige-Obergrenze für den eingefügten Literaltext (z.B. lange Spaltenlisten in
// "Insert Text [ $Header ]"). Längere Werte werden mit "…" gekürzt.
const INSERTED_TEXT_MAX = 200;

// Anzeige-Obergrenze für Formeln in der Fallback-Komposition (Steps ohne DDR-Text).
// Zeilenumbrüche bleiben erhalten (DDR-Texte tragen sie ebenfalls), nur die Länge
// wird gedeckelt, damit Monster-Calcs die Step-Zeile nicht sprengen.
const FALLBACK_CALC_MAX = 400;

/**
 * Klartext-Näherung für Script-Steps OHNE DDR-Text (Dateien ohne DDR-Info).
 * Komponiert aus den in P1/P2 bereits materialisierten Step-Bestandteilen:
 *   <Step-Name> [ $Variable ; Step-XML-Refs (Script/Layout/Feld/TO/…) ; Flag ; Formel ]
 * Bewusst eine HEURISTIK (Phase 2a): step-typ-spezifische Optionen/Flags, die nur im
 * Step_XML stehen (Sortierkriterien, Import-Mappings, Dialog-Buttons …), fehlen —
 * deren FM-getreue Rekonstruktion ist Phase 2b (P3-vorberechnete Spalte).
 * Bei vorhandenem DDR wird diese Funktion
 * nie aufgerufen (d.Step_Text gewinnt im SQL/Aufrufer).
 */
function composeFallbackStepText(row, stepRefs, { skipFields = false } = {}) {
  const parts = [];

  // 1. Variable (Set Variable LHS) — Ref-Duplikat wird unten ausgefiltert.
  if (row.variable_name) parts.push(row.variable_name);

  // 2. Step-XML-Referenzen (aufgelöste Namen aus P2): Script-/Layout-/Menüset-
  //    Namen in typografischen Quotes (wie im deutschen DDR-Text), Felder als
  //    TO::Feld, TOs/Wertelisten nackt.
  //    skipFields: bei Find-/Sort-Steps mit geparsten Kriterien entfällt die
  //    nackte Feld-/Wertelisten-Liste — Felder und Wertelisten erscheinen
  //    stattdessen im Kriterien-Segment (TO::Feld: „Kriterium“ bzw.
  //    TO::Feld: Werteliste „X“), sonst doppelte Nennung.
  for (const r of stepRefs || []) {
    if (!r.name) continue;
    if (r.type === 'variable') continue; // deckt variable_name bereits ab
    if (skipFields && (r.type === 'field' || r.type === 'valueList')) continue;
    if (r.type === 'script' || r.type === 'layout' || r.type === 'menuset') {
      parts.push(`„${r.name}“`);
    } else if (r.table) {
      parts.push(`${r.table}::${r.name}`);
    } else {
      parts.push(r.name);
    }
  }

  // 3. Erstes Boolean-Flag (z.B. "With dialog"): Label kommt englisch aus dem
  //    Step-XML-Attribut, Wert FM-üblich als Ein/Aus.
  if (row.boolean_type) {
    parts.push(`${row.boolean_type}: ${String(row.boolean_value) === 'True' ? 'Ein' : 'Aus'}`);
  }

  // 4. Formel-Klartext (erste Calculation des Steps; If/Set Variable/Set Field/
  //    Exit/Custom Dialog …). Länge gedeckelt, Zeilenumbrüche bleiben.
  if (row.calculation_text) {
    let calc = String(row.calculation_text).trim();
    if (calc.length > FALLBACK_CALC_MAX) calc = calc.slice(0, FALLBACK_CALC_MAX) + '…';
    if (calc) parts.push(calc);
  }

  if (parts.length === 0) return null; // parameterloser Step → Step-Name allein ist korrekt
  return `${row.step_name} [ ${parts.join(' ; ')} ]`;
}

/**
 * Parst die FindRequestSet-Struktur aus dem Step_XML eines Find-Steps
 * (Ergebnismenge suchen / Enter Find Mode / Constrain / Extend Found Set).
 * Liefert je Request die Aktion (find/omit) und die Kriterien als
 * {table, field, criteria} — Namen und Kriterium entity-dekodiert.
 */
function parseFindRequests(stepXml) {
  if (!stepXml || stepXml.indexOf('<FindRequestSet') === -1) return [];
  const requests = [];
  for (const reqMatch of String(stepXml).matchAll(FIND_REQUEST_RE)) {
    const action = reqMatch[1];
    const criteria = [];
    for (const critMatch of reqMatch[2].matchAll(FIND_CRITERIA_RE)) {
      const attrMatch = CRITERIA_ATTR_RE.exec(critMatch[1]);
      const fieldMatch = FIND_FIELD_NAME_RE.exec(critMatch[2]);
      const toMatch = TO_REF_RE.exec(critMatch[2]);
      criteria.push({
        criteria: attrMatch ? decodeXmlEntities(attrMatch[1]) : '',
        field: fieldMatch ? decodeXmlEntities(fieldMatch[1]) : null,
        table: toMatch ? decodeXmlEntities(toMatch[1]) : null,
      });
    }
    if (criteria.length > 0) requests.push({ action, criteria });
  }
  return requests;
}

/**
 * Klammer-Segmente für die Find-Requests eines Steps: pro Request ein Segment
 * `[ Suchen: TO::Feld: „Kriterium“ ; … ]` bzw. `[ Ausschließen: … ]`.
 * Requests untereinander sind OR-verknüpft (eigene Segmente), Kriterien
 * innerhalb eines Requests AND-verknüpft (mit ` ; ` gereiht). Die Segmente
 * werden mit \r gereiht — das Frontend kollabiert `\r[` inline (analog zur
 * Inserted-Text-Klammer). Feldnamen in TO::Feld-Notation matchen die
 * Step-Refs, der Client-Tokenizer verlinkt sie automatisch.
 */
function composeFindRequestsText(stepXml) {
  const requests = parseFindRequests(stepXml);
  if (requests.length === 0) return null;
  const segments = requests.map(req => {
    const crits = req.criteria.map(c => {
      // Leerer Feldname kommt vor (kaputte FieldReference in der Quell-Lösung,
      // name="") — als "TO::?" kenntlich machen statt still zu verschlucken.
      const target = c.table ? `${c.table}::${c.field || '?'}` : (c.field || '?');
      return `${target}: „${c.criteria}“`;
    });
    const label = req.action === 'omit' ? 'Ausschließen' : 'Suchen';
    return `[ ${label}: ${crits.join(' ; ')} ]`;
  });
  return segments.join('\r');
}

/**
 * Parst die SortList aus dem Step_XML eines Sortieren-Steps (Sort Records).
 * Liefert je Sortierkriterium Feld/TO, Richtung (Ascending/Descending/Custom)
 * und bei Custom den Namen der Werteliste — in Sortier-Prioritätsreihenfolge
 * (XML-Reihenfolge), Namen entity-dekodiert.
 */
function parseSortList(stepXml) {
  if (!stepXml || stepXml.indexOf('<SortList') === -1) return [];
  const entries = [];
  for (const m of String(stepXml).matchAll(SORT_ENTRY_RE)) {
    const fieldMatch = FIND_FIELD_NAME_RE.exec(m[2]);
    const toMatch = TO_REF_RE.exec(m[2]);
    const vlMatch = VALUELIST_NAME_RE.exec(m[2]);
    entries.push({
      order: m[1],
      field: fieldMatch ? decodeXmlEntities(fieldMatch[1]) : null,
      table: toMatch ? decodeXmlEntities(toMatch[1]) : null,
      valueList: vlMatch ? decodeXmlEntities(vlMatch[1]) : null,
    });
  }
  return entries;
}

/**
 * Klammer-Segment für die Sortierkriterien eines Sort-Records-Steps:
 * `[ TO::Feld: aufsteigend ; TO::Feld: Werteliste „X“ ; … ]` in
 * Prioritätsreihenfolge. Analog composeFindRequestsText nur für den
 * Fallback-Pfad gedacht — der DDR-Step_Text trägt die Sortierung selbst
 * ("Specified Sort Order: …; ascending").
 */
function composeSortListText(stepXml) {
  const entries = parseSortList(stepXml);
  if (entries.length === 0) return null;
  const parts = entries.map(e => {
    // Leerer Feldname analog Find-Kriterien als "TO::?" kenntlich machen.
    const target = e.table ? `${e.table}::${e.field || '?'}` : (e.field || '?');
    let order;
    if (e.order === 'Descending') order = 'absteigend';
    else if (e.order === 'Custom') order = e.valueList ? `Werteliste „${e.valueList}“` : 'benutzerdefiniert';
    else order = 'aufsteigend';
    return `${target}: ${order}`;
  });
  return `[ ${parts.join(' ; ')} ]`;
}

/**
 * Bereitet den Insert-Text-Payload (StepsForScripts.Inserted_Text) für die Anzeige
 * auf: der Wert ist bereits in P2 (xml_extract_text) entity-DEKODIERT, hier wird er
 * nur noch fürs Single-Line-Rendering normalisiert — interne Zeilenumbrüche/Tabs auf
 * sichtbare Trenner (sonst bläht der Wert die Step-Zeile vertikal auf) und gekürzt.
 * Leerer/None-Payload → null (nichts anhängen).
 */
function formatInsertedText(raw) {
  if (raw === null || raw === undefined || raw === '') return null;
  let v = String(raw)
    .replace(/\r\n|\r|\n/g, ' ¶ ')
    .replace(/\t/g, ' ⇥ ')
    .trim();
  if (v === '') return null;
  if (v.length > INSERTED_TEXT_MAX) v = v.slice(0, INSERTED_TEXT_MAX) + '…';
  return v;
}

function formatScript(rows, { object, refs }) {
  // Dedup pro Zeile:
  //   - Variables:       (type, name, scope, usage) — Set/Read sind unterschiedliche Refs
  //   - Fields:          (type, name, table) — gleiches Feld via unterschiedlicher TO = unterschiedliche Refs
  //   - PluginFunctions: (type, name, subFunction) — zwei MBS-Aufrufe mit unter-
  //                      schiedlicher subFunction in derselben Step-Calc bleiben
  //                      eigenständige Refs.
  //   - Andere:          (type, name)
  // Step-Refs (source_priority=0) kommen vor Calc-Refs durch ORDER BY im Template
  // — first-wins-Semantik sorgt dafür, dass Step-XML-Refs gewinnen.
  const refsByLine = {};
  const seenByLine = {};
  // Step-XML-Refs (source_priority=0) separat je Zeile sammeln — Rohstoff für die
  // Fallback-Komposition bei Steps ohne DDR-Text. Calc-Refs (priority=1) bleiben
  // außen vor (sie stammen aus der Formel, die als calculation_text ohnehin
  // vollständig angehängt wird — sonst doppelte Nennung).
  const stepRefsByLine = {};
  if (Array.isArray(refs)) {
    for (const r of refs) {
      if (Number(r.source_priority) === 0) {
        (stepRefsByLine[r.line_index] ??= []).push({
          type: r.type,
          name: r.name,
          table: r.to_name || null,
        });
      }
    }
  }
  if (Array.isArray(refs)) {
    for (const r of refs) {
      const slot = (refsByLine[r.line_index] ??= []);
      const seen = (seenByLine[r.line_index] ??= new Set());

      let dedupKey;
      if (r.type === 'variable') {
        dedupKey = `${r.type}|${r.name}|${r.variable_scope ?? ''}|${r.variable_usage ?? ''}`;
      } else if (r.type === 'pluginFunction') {
        dedupKey = `${r.type}|${r.name}|${r.sub_function ?? ''}`;
      } else if (r.to_name) {
        dedupKey = `${r.type}|${r.name}|${r.to_name}`;
      } else {
        dedupKey = `${r.type}|${r.name}`;
      }
      if (seen.has(dedupKey)) continue;
      seen.add(dedupKey);

      const entry = { type: r.type, name: r.name };
      if (r.uuid)            entry.uuid      = r.uuid;
      if (r.field_file)      entry.file      = r.field_file;
      if (r.to_name)         entry.table     = r.to_name;
      if (r.field_basetable) entry.baseTable = r.field_basetable;
      // crossFile/dataSource für Field-, Script- und tableOccurrence-Refs.
      // tableOccurrence kommt aus GTRR:
      // ein Sprung zu einer TO mit Cross-File-DataSource ist semantisch ein
      // dateiübergreifender Navigations-Sprung. Variables/PluginFunctions haben
      // kein Cross-File-Konzept.
      if ((r.type === 'field' || r.type === 'script' || r.type === 'tableOccurrence') && r.cross_file) {
        entry.crossFile = true;
        if (r.data_source) entry.dataSource = r.data_source;
      }
      if (r.variable_scope) entry.scope = r.variable_scope;
      if (r.variable_usage) entry.usage = r.variable_usage;
      // subFunction:
      // fachlicher Funktionsname für Container-Plugins (heute: MBS).
      if (r.type === 'pluginFunction' && r.sub_function) {
        entry.subFunction = r.sub_function;
      }
      slot.push(entry);
    }
  }

  const lines = rows.map(row => {
    const base = {
      line: row.line_index + 1,
      indent: row.indent,
      kind: row.kind,
      enabled: row.enabled !== false,
    };

    if (row.kind === 'empty') {
      return base;
    }

    if (row.kind === 'comment') {
      const stepText = row.step_text || '';
      // Strip the leading '#' (and any whitespace after it) — the kind already
      // marks this as a comment, the text should be the comment content alone.
      const text = stepText.replace(/^#\s?/, '');
      return { ...base, text };
    }

    const lineRefs = refsByLine[row.line_index];
    // Insert-Text-Payload sichtbar machen: das DDR-Step_Text zeigt nur Ziel +
    // [ Select ], nie den eingefügten Literaltext. Als eigenes Bracket-Segment
    // anhängen (analog der mehrzeiligen DDR-Bracket-Notation). Der Tokenizer
    // rendert Strings/Zahlen darin korrekt; der angehängte Literal matcht keine
    // Ref (außer er enthält zufällig exakt einen Ref-Namen — harmlos).
    // Ohne DDR-Text (Datei ohne DDR-Info): Klartext-Näherung aus den
    // materialisierten Step-Bestandteilen komponieren (Phase 2a); erst wenn auch
    // das nichts hergibt (parameterloser Step), bleibt der Step-Name allein.
    // Verbindlichkeits-Kette für den Zeilentext (pro Step, nicht pro Datei —
    // auch in DDR-Dateien kann eine einzelne DDR-Zeile fehlen):
    //   1. DDR_ScriptSteps.Step_Text — FM-generiert, maßgeblich. Trägt Such-/
    //      Sortierkriterien gespeicherter Abfragen bereits selbst ("Specified
    //      Find Requests: …; Criteria: …" / "Specified Sort Order: …"), darum
    //      wird ihm NICHTS hinzukomponiert (Dublettengefahr).
    //   2. Komponierte Näherung aus den P1/P2-Step-Bestandteilen plus — für
    //      Find-/Sort-Steps — die aus dem Step_XML geparsten Kriterien-Segmente
    //      (composeFindRequestsText/composeSortListText; die Segmente ersetzen
    //      dabei die nackte Feld-/Wertelisten-Liste, skipFields). Gekennzeichnet
    //      als textSource: 'fallback'. Ein Step trägt nie Find UND Sort.
    //   3. Nackter Step-Name (parameterloser Step).
    const criteriaSegments = row.step_text
      ? null
      : (composeFindRequestsText(row.step_xml) || composeSortListText(row.step_xml));
    const fallback = row.step_text
      ? null
      : composeFallbackStepText(row, stepRefsByLine[row.line_index], { skipFields: !!criteriaSegments });
    const baseText = row.step_text || fallback || row.step_name;
    const inserted = formatInsertedText(row.inserted_text);
    let text = inserted ? `${baseText}\r[ ${inserted} ]` : baseText;
    if (criteriaSegments) text += `\r${criteriaSegments}`;
    // Komponiert = Stufe 2 der Kette: auch eine Zeile, die nur aus Step-Name +
    // Kriterien-Segmenten besteht (fallback null, z.B. Perform Find ohne
    // weitere Parameter), ist eine Näherung und muss als solche markiert sein.
    const isComposed = Boolean(fallback || criteriaSegments);
    return {
      ...base,
      stepId: row.step_id,
      stepName: row.step_name,
      stepUuid: row.step_uuid,
      stepTypeUuid: row.step_type_uuid,
      text,
      // Kennzeichnung für Konsumenten/Styling: Text ist eine komponierte
      // Näherung, kein FM-generierter DDR-Text.
      ...(isComposed ? { textSource: 'fallback' } : {}),
      ...(lineRefs && lineRefs.length ? { refs: lineRefs } : {}),
    };
  });

  const plainText = lines.map(line => {
    if (line.kind === 'empty') return '';
    const pad = '  '.repeat(line.indent || 0);
    if (line.kind === 'comment') return `${pad}# ${line.text}`;
    return pad + (line.text || '');
  }).join('\n');

  return {
    kind: 'script',
    object,
    lines,
    plainText,
  };
}

function formatCustomFunction(rows, { object }) {
  if (!rows || rows.length === 0) {
    return {
      kind: 'customfunction',
      object,
      parameters: [],
      tokens: [],
      plainText: '',
    };
  }

  const head = rows[0];
  const enrichedObject = {
    ...object,
    uuid: head.object_uuid || object.uuid,
    name: head.object_name || object.name,
    file: head.object_file || object.file,
  };

  const chunkRows = rows
    .filter(r => r.chunk_index !== null && r.chunk_index !== undefined)
    .map(r => ({ chunk_type: r.chunk_type, chunk_content: r.chunk_content, ref_uuid: r.chunk_ref_uuid, sub_function: r.sub_function }));
  const rawTokens = chunkRows.map((c, i, arr) => tokenFromChunk(c, i, arr));

  const tokens = head.plain_text != null
    ? reconcileTokensWithPlainText(rawTokens, head.plain_text)
    : rawTokens;

  const plainText = head.plain_text != null
    ? head.plain_text
    : tokens.map(t => t.content).join('');

  return {
    kind: 'customfunction',
    object: enrichedObject,
    parameters: head.parameters || [],
    tokens,
    plainText,
  };
}

function formatField(rows, { object }) {
  if (!rows || rows.length === 0) {
    return {
      kind: 'field',
      object,
      field: null,
      tokens: [],
      plainText: '',
    };
  }

  const head = rows[0];
  const enrichedObject = {
    ...object,
    uuid: head.object_uuid || object.uuid,
    name: head.object_name || object.name,
    file: head.object_file || object.file,
  };

  // DuckDB liefert Booleans teils als true/false, teils als 'True'/'False'-String.
  const toBool = (v) => v === true || v === 'True' || v === 'true' || v === 1;
  const nn = (v) => (v == null || v === '' ? null : v); // null-if-empty

  const aeType = head.auto_enter_type ?? null;

  // Serial (nur wenn AutoEnter_Type='SerialNumber')
  const serial = aeType === 'SerialNumber'
    ? {
        generate:  nn(head.serial_generate),
        nextValue: nn(head.serial_next_value),
        increment: nn(head.serial_increment),
      }
    : null;

  // Lookup / Referenzwert (nur wenn AutoEnter_Type='Looked_up')
  const lookup = aeType === 'Looked_up' && nn(head.lookup_field_name)
    ? {
        field:          nn(head.lookup_field_name),
        // UUID + aufgelöste Zieldatei für den klickbaren Objekt-Link; nur gesetzt,
        // wenn das Quellfeld im Katalog auflösbar ist (sonst reiner Text im Frontend).
        fieldUuid:      nn(head.lookup_field_uuid),
        fieldFile:      nn(head.lookup_field_file),
        // Herkunfts-BaseTable des Quellfelds — disambiguiert gleichnamige Felder.
        fieldTable:     nn(head.lookup_field_table),
        to:             nn(head.lookup_to_name),
        dontCopyIfEmpty: toBool(head.lookup_dont_copy_if_empty),
        noMatch:        nn(head.lookup_no_match_option),
        // FileMaker 26 exports disabled lookups with enable="False" (null = active).
        enabled:        head.lookup_enabled == null ? true : toBool(head.lookup_enabled),
      }
    : null;

  // AutoEnter-Calc-Flags (nur wenn AutoEnter_Type='Calculated')
  const autoEnterCalc = aeType === 'Calculated'
    ? {
        overwriteExisting: toBool(head.ae_calc_overwrite_existing),
        alwaysEvaluate:    toBool(head.ae_calc_always_evaluate),
        // FileMaker 26 exports disabled auto-enter calculations (enable="False"; null = active).
        enabled:           head.ae_calc_enabled == null ? true : toBool(head.ae_calc_enabled),
      }
    : null;

  // Überprüfung — nur zeigen, wenn eine echte Regel gesetzt ist (nicht der Default).
  const vNotEmpty = toBool(head.validation_not_empty);
  const vUnique   = toBool(head.validation_unique);
  const vExisting = toBool(head.validation_existing);
  const vType     = nn(head.validation_type);
  const vlName    = nn(head.validation_vl_name);
  // Validierungs-Optionen aus Schema 1.10.0
  const vStrict    = nn(head.validation_strict_type);
  const vMaxChars  = head.validation_max_chars != null ? Number(head.validation_max_chars) : null;
  const vRangeFrom = nn(head.validation_range_from);
  const vRangeTo   = nn(head.validation_range_to);
  const vCalcText  = nn(head.validation_calc_text);
  const vMessage   = nn(head.validation_message);
  // Calculation-Instanz-UUIDs der Validierungs-Slots (Schema 1.22.0) —
  // Token-Rendering via get-calc?uuid; null = DDR-los → Klartext-Fallback.
  const vCalcUuid    = nn(head.validation_calc_uuid);
  const vMsgCalcUuid = nn(head.validation_message_calc_uuid);
  const vMsgCalcText = nn(head.validation_message_calc_text);
  const hasValidation = vNotEmpty || vUnique || vExisting || !!vlName || vType === 'Always'
    || !!vStrict || vMaxChars != null || !!vRangeFrom || !!vRangeTo || !!vCalcText || !!vMessage
    || !!vMsgCalcUuid || !!vMsgCalcText;
  const validation = hasValidation
    ? {
        mode:          vType,                              // Always | OnlyDuringDataEntry
        allowOverride: toBool(head.validation_allow_override),
        notEmpty:      vNotEmpty,
        unique:        vUnique,
        existing:      vExisting,
        valueList:     vlName ? { name: vlName, uuid: nn(head.validation_vl_uuid) } : null,
        strictType:    vStrict,                            // Numeric | FourDigitYear | TimeOfDay
        maxChars:      vMaxChars,
        rangeFrom:     vRangeFrom,
        rangeTo:       vRangeTo,
        calcText:      vCalcText,                          // „Überprüfung durch Berechnung" (Klartext)
        calcUuid:      vCalcUuid,                          // Instanz-UUID für Token-Rendering
        // FileMaker 26: disabled validation calculation (enable="False"; null = active)
        calcEnabled:   head.validation_calc_enabled == null ? true : toBool(head.validation_calc_enabled),
        message:       vMessage,                           // eigene Fehlermeldung (statisch)
        messageCalc:   (vMsgCalcUuid || vMsgCalcText)
          ? { uuid: vMsgCalcUuid, text: vMsgCalcText,      // Fehlermeldungs-FORMEL (validation_message)
              enabled: head.validation_message_calc_enabled == null ? true : toBool(head.validation_message_calc_enabled) }
          : null,
      }
    : null;

  // FileMaker 26 — extended field options: annotation (DDL comment) and the
  // display-names formula with its parsed JSON elements (P3 FieldDisplayNames).
  const annotation = nn(head.field_annotation);
  const dnEnabledRaw = head.display_names_enabled;
  const dnCalcText = nn(head.display_names_calc_text);
  const dnCalcUuid = nn(head.display_names_calc_uuid);
  let dnElements = [];
  if (head.display_name_elements != null) {
    try {
      const parsed = typeof head.display_name_elements === 'string'
        ? JSON.parse(head.display_name_elements)
        : head.display_name_elements;
      if (Array.isArray(parsed)) {
        dnElements = parsed.map(e => ({
          seq:      e.seq != null ? Number(e.seq) : 0,
          key:      e.key ?? '',
          value:    e.value ?? null,
          kind:     e.kind === 'formula' ? 'formula' : 'literal',
          jsonType: e.jsonType ?? null,
        }));
      }
    } catch { dnElements = []; }
  }
  const displayNames = (dnEnabledRaw != null || dnCalcText || dnCalcUuid)
    ? {
        enabled:  dnEnabledRaw == null ? false : toBool(dnEnabledRaw),
        calcText: dnCalcText,
        calcUuid: dnCalcUuid,
        elements: dnElements,
      }
    : null;

  // Speicher / Indizierung — nur zeigen, wenn Indexinfo oder Calc-nicht-gespeichert.
  const storeCalc = head.storage_store_calc_results;
  const indexMode = nn(head.storage_index);
  // Berechnungsfeld-Option „Nicht berechnen, wenn verwendete Felder leer sind".
  // Kontrolliert verifiziert (listenlayout/Felder): Checkbox AN ⇔ alwaysEvaluate=false;
  // die GUI-Option ist also die INVERSE von alwaysEvaluate. AN ist der FileMaker-Default
  // (~71% des Korpus) → wir zeigen nur den auffälligen Nicht-Default: alwaysEvaluate=true =
  // „berechnet auch bei leeren Feldern". Nur echte Calc-Felder (bei Normal+AE-Calc heißt
  // alwaysEvaluate „bei jeder Änderung neu" → eigener autoEnterCalc-Zweig).
  const isCalcField = nn(head.field_type) === 'Calculated';
  const aeAlways    = head.ae_calc_always_evaluate;   // true|false|'True'|'False'|null
  const evaluatesWhenEmpty = (isCalcField && aeAlways != null) ? toBool(aeAlways) : false;
  const hasStorage = indexMode != null || storeCalc === false || storeCalc === 'False' || evaluatesWhenEmpty;
  const storage = hasStorage
    ? {
        index:            indexMode,                       // None | Minimal | All
        autoIndex:        toBool(head.storage_auto_index),
        storeCalcResults: !(storeCalc === false || storeCalc === 'False'),
        // Indexsprache nur, wenn das Feld tatsächlich indiziert ist (sonst irrelevant).
        indexLanguage:    (indexMode && indexMode !== 'None') ? nn(head.storage_index_language) : null,
        evaluatesWhenEmpty,                                // Nicht-Default: Calc rechnet auch bei leeren Ref-Feldern
      }
    : null;

  // Statistik (nur Field_Type='Summary')
  const summaryRepMode = nn(head.summary_repetition_mode);
  const summary = nn(head.summary_operation)
    ? {
        operation: nn(head.summary_operation),
        field:     nn(head.summary_field_name)
          ? { name: nn(head.summary_field_name), uuid: nn(head.summary_field_uuid) }
          : null,
        restartEachGroup: toBool(head.summary_restart_each_group),
        // Wiederholungsmodus nur bei Nicht-Default ('Together' = Default → weglassen).
        repetitionMode:   (summaryRepMode && summaryRepMode !== 'Together') ? summaryRepMode : null,
      }
    : null;

  const fieldMeta = {
    table:           head.table_name ?? null,
    fieldType:       head.field_type ?? null,
    dataType:        head.data_type ?? null,
    isGlobal:        toBool(head.is_global),
    maxRepetitions:  head.max_repetitions != null ? Number(head.max_repetitions) : 1,
    comment:         head.field_comment ?? null,
    autoEnterType:   aeType,
    constantData:    head.ae_constant_data ?? null,
    prohibitModification: toBool(head.auto_enter_prohibit_mod),
    serial,
    lookup,
    autoEnterCalc,
    validation,
    storage,
    summary,
    annotation,
    displayNames,
  };

  const chunkRows = rows
    .filter(r => r.chunk_index !== null && r.chunk_index !== undefined)
    .map(r => ({ chunk_type: r.chunk_type, chunk_content: r.chunk_content, ref_uuid: r.chunk_ref_uuid, sub_function: r.sub_function }));
  const rawTokens = chunkRows.map((c, i, arr) => tokenFromChunk(c, i, arr));

  const tokens = head.plain_text != null
    ? reconcileTokensWithPlainText(rawTokens, head.plain_text)
    : rawTokens;

  const plainText = head.plain_text != null
    ? head.plain_text
    : tokens.map(t => t.content).join('');

  return {
    kind: 'field',
    object: enrichedObject,
    field: fieldMeta,
    tokens,
    plainText,
  };
}

/**
 * Custom Menu: mehrere Berechnungen (Menü-eigene + pro-Item) als je ein Token-Block.
 * Zeilen kommen block-sortiert (block_id, chunk_index) aus object_details_custommenu_tokens.sql;
 * pro block_id wird — analog CustomFunction — aus den Chunk-Reihen eine Token-Folge gebaut und
 * gegen den Klartext (plain_text) abgeglichen. Statische Blöcke (calc_is_static) ohne Chunks
 * fallen auf ein reines Text-Token zurück.
 */
function formatCustomMenu(rows, { object }) {
  if (!rows || rows.length === 0) {
    return { kind: 'custommenu', object, calcs: [] };
  }

  const head = rows[0];
  const enrichedObject = {
    ...object,
    uuid: head.object_uuid || object.uuid,
    name: head.object_name || object.name,
    file: head.object_file || object.file,
  };

  // Zeilen nach Block gruppieren (Reihenfolge aus dem ORDER BY beibehalten).
  const byBlock = new Map();
  for (const r of rows) {
    if (!byBlock.has(r.block_id)) {
      byBlock.set(r.block_id, {
        blockId: r.block_id,
        prefix: r.block_prefix,
        label: r.calc_label,
        isStatic: r.calc_is_static === true || r.calc_is_static === 'true',
        plainText: r.plain_text != null ? String(r.plain_text) : '',
        chunkRows: [],
      });
    }
    if (r.chunk_index !== null && r.chunk_index !== undefined) {
      byBlock.get(r.block_id).chunkRows.push({
        chunk_type: r.chunk_type,
        chunk_content: r.chunk_content,
        ref_uuid: r.chunk_ref_uuid,
        sub_function: r.sub_function,
      });
    }
  }

  const calcs = Array.from(byBlock.values()).map(b => {
    const rawTokens = b.chunkRows.map((c, i, arr) => tokenFromChunk(c, i, arr));
    let tokens;
    if (b.chunkRows.length > 0) {
      tokens = b.plainText ? reconcileTokensWithPlainText(rawTokens, b.plainText) : rawTokens;
    } else {
      // Rein statischer Block ohne Chunks → Klartext als einzelnes Text-Token.
      tokens = b.plainText ? [{ type: 'text', content: b.plainText }] : [];
    }
    return {
      label: b.prefix ? `${b.prefix} · ${b.label}` : b.label,
      isStatic: b.isStatic,
      tokens,
      plainText: b.plainText || tokens.map(t => t.content).join(''),
    };
  });

  return { kind: 'custommenu', object: enrichedObject, calcs };
}

// Identifier-Nachbarklasse der synthetischen Tokenisierung — identisch zur
// Wortgrenzen-Klasse der Converter-Rettung (P2 A.5.1c).
const RECOVER_IDENT_RE = /[0-9A-Za-zÄÖÜäöüß_]/;

/**
 * Doppelt-gequotete String-Literal-Spannen der Formel ("…", \" escaped) —
 * Referenz-Treffer INNERHALB von Literalen werden verworfen (Parität zur
 * Literal-Strippung der Converter-Variablen-Rettung, P3 A.6c).
 */
function literalRanges(text) {
  const ranges = [];
  let start = -1;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '\\') { i++; continue; }
    if (ch === '"') {
      if (start === -1) start = i;
      else { ranges.push([start, i + 1]); start = -1; }
    }
  }
  if (start !== -1) ranges.push([start, text.length]);
  return ranges;
}

/**
 * Synthetische Tokenisierung einer GERETTETEN Display-Calculation (leere
 * DDR-ChunkList, FileMaker-Defekt bei %X:-typisierten Layoutformeln mit
 * Ausdruck): lokalisiert die instanz-genau geborgenen Referenzen (Felder mit
 * UUID, CustomFunctions, Variablen — slot-skopierte XMLCalcReferences des
 * Converters) im geretteten Formeltext und emittiert reguläre typisierte
 * Tokens; alles andere bleibt Text. Builtin-Funktionen bleiben bewusst Text
 * (lokalisierte Namen — Auflösungsgrenze der Rettung).
 *
 * Match-Regeln spiegeln die Converter-Heuristik (P2 A.5.1b/c):
 *   - Feld: `${Name}`-gequotete Spanne (inkl. Quoting, bei Feld↔CF-Kollision
 *     die einzige Feld-Form) ODER nackter Name mit Identifier-Wortgrenzen
 *     (Vorgänger zusätzlich nie '$'/'{').
 *   - CustomFunction/Variable: nackte Spanne mit Wortgrenzen; Vorgänger nie
 *     '$'/'{' (CF) bzw. nie '$' (Variable — verhindert $var-in-$$var).
 *   - Treffer in String-Literalen werden verworfen; Überlappungen löst die
 *     früheste, bei Gleichstand die längste Spanne.
 *
 * Token-Content ist die ORIGINAL-Spanne (lokalisierte Layout-Wahrheit, inkl.
 * ${…}); die kanonische Form bleibt den aufgelösten Zielen überlassen.
 * Rückgabe: Token-Array oder null, wenn KEINE Referenz gematcht hat (der
 * Aufrufer bleibt dann beim Klartext-Fallback samt ehrlichem Hinweis).
 */
function synthesizeRecoveredCalcTokens(formulaText, refs) {
  if (!formulaText || !Array.isArray(refs) || refs.length === 0) return null;
  const literals = literalRanges(formulaText);
  const inLiteral = (pos) => literals.some(([s, e]) => pos >= s && pos < e);
  const prevOk = (pos, extra) => {
    if (pos === 0) return true;
    const ch = formulaText[pos - 1];
    return !RECOVER_IDENT_RE.test(ch) && !(extra && extra.includes(ch));
  };
  const nextOk = (end) => end >= formulaText.length || !RECOVER_IDENT_RE.test(formulaText[end]);

  const findAll = (needle) => {
    const hits = [];
    let from = 0;
    for (;;) {
      const i = formulaText.indexOf(needle, from);
      if (i === -1) break;
      hits.push(i);
      from = i + 1;
    }
    return hits;
  };

  const matches = [];
  for (const ref of refs) {
    if (!ref || !ref.name) continue;
    if (ref.type === 'field') {
      const quoted = '${' + ref.name + '}';
      for (const i of findAll(quoted)) {
        if (!inLiteral(i)) matches.push({ start: i, end: i + quoted.length, ref });
      }
      for (const i of findAll(ref.name)) {
        if (!inLiteral(i) && prevOk(i, '${') && nextOk(i + ref.name.length)) {
          matches.push({ start: i, end: i + ref.name.length, ref });
        }
      }
    } else if (ref.type === 'customFunction') {
      for (const i of findAll(ref.name)) {
        if (!inLiteral(i) && prevOk(i, '${') && nextOk(i + ref.name.length)) {
          matches.push({ start: i, end: i + ref.name.length, ref });
        }
      }
    } else if (ref.type === 'variable') {
      for (const i of findAll(ref.name)) {
        if (!inLiteral(i) && prevOk(i, '$') && nextOk(i + ref.name.length)) {
          matches.push({ start: i, end: i + ref.name.length, ref });
        }
      }
    }
  }
  if (matches.length === 0) return null;

  matches.sort((a, b) => a.start - b.start || b.end - a.end);
  const chosen = [];
  let cursor = -1;
  for (const m of matches) {
    if (m.start > cursor) { chosen.push(m); cursor = m.end - 1; }
  }

  const tokens = [];
  let pos = 0;
  for (const m of chosen) {
    if (m.start > pos) tokens.push({ type: 'text', content: formulaText.slice(pos, m.start) });
    const span = formulaText.slice(m.start, m.end);
    if (m.ref.type === 'field') {
      const tok = { type: 'field', content: span };
      if (m.ref.uuid) tok.uuid = String(m.ref.uuid);
      tokens.push(tok);
    } else if (m.ref.type === 'customFunction') {
      tokens.push({ type: 'customFunction', content: span });
    } else {
      tokens.push({ type: 'variable', content: span, scope: span.startsWith('$$') ? 'global' : 'local' });
    }
    pos = m.end;
  }
  if (pos < formulaText.length) tokens.push({ type: 'text', content: formulaText.slice(pos) });
  return tokens;
}

// Anker-Grammatik des Merge-Text-Scans, Alternations-Reihenfolge ist
// Prioritätsreihenfolge: ƒ-Layoutformel vor Variable vor Feld vor Symbol.
// ƒ-Formeln non-greedy bis zum ersten '>>' — identisch zur Converter-Regex
// (ein '>>' INNERHALB eines Formel-Literals bricht dort wie hier den Anker).
const MERGE_ANCHOR_RE = /<<ƒ:([\s\S]*?)>>|<<(\$[^>]*?)>>|<<([^>]+?)>>|\{\{([^}]+?)\}\}/g;

/**
 * Aufgelöste Merge-Text-Zeile eines Text-LayoutObjects: scannt Text_Content
 * nach Merge-Ankern und ersetzt jedes VORKOMMEN durch typisierte Tokens —
 * Merge Fields über die displays_field-Kanten, Merge Variables über
 * displays_variable, valide Symbole als Get-Token-Gruppe in DDR-Chunk-Gestalt
 * ('Get' · '( ' · Parameter · ' )', beide Namen enrich-fähig). ƒ-Anker bleiben
 * verbatim Text (ihre Formeln zeigt die display_calculation-Slot-Sektion);
 * unauflösbare Anker bleiben byte-identisch literal — das spiegelt das
 * Laufzeitverhalten (ungültige Anker rendern literal).
 *
 * ctx (alles vom Aufrufer beschafft, die Funktion bleibt DB-frei):
 *   - fields:      [{ name, baseTable, uuid }]  displays_field-Ziele
 *   - variables:   [{ name, uuid }]             displays_variable-Ziele
 *   - symbols:     [{ text, norm, valid }]      LayoutObjectSymbols + Kanon-Check
 *   - toBaseTable: { lower(TO-Name) → BaseTable-Name } (File-skopiert)
 *   - layoutTOName: Kontext-TO des Layouts (qualifiziert unqualifizierte Anker)
 *
 * Feld-Match: qualifizierter Anker `TO::Feld` über TO→BaseTable, sonst über
 * das Kontext-TO des Layouts; Fallback genau EINE namensgleiche Kante.
 * Repetitions-Suffix `[n]` zählt nur fürs Matching nicht mit, das Token-
 * Content behält die Original-Schreibweise. Alle Vergleiche case-insensitiv.
 *
 * Rückgabe: { tokens, anchorsTotal, anchorsResolved } — ƒ-Anker zählen nicht
 * mit; NULL, wenn kein Nicht-ƒ-Anker aufgelöst wurde (Emissionsbedingung des
 * Aufrufers: dann gibt es nichts über die Slot-Sektion hinaus zu zeigen).
 */
function synthesizeMergeTextTokens(textContent, ctx) {
  if (!textContent || typeof textContent !== 'string') return null;
  const fields = (ctx && Array.isArray(ctx.fields)) ? ctx.fields : [];
  const variables = (ctx && Array.isArray(ctx.variables)) ? ctx.variables : [];
  const symbols = (ctx && Array.isArray(ctx.symbols)) ? ctx.symbols : [];
  const toBaseTable = (ctx && ctx.toBaseTable) || {};
  const layoutTOName = (ctx && ctx.layoutTOName) || null;
  const lower = (s) => String(s).toLowerCase();

  const tokens = [];
  let anchorsTotal = 0;
  let anchorsResolved = 0;
  const pushText = (s) => {
    if (!s) return;
    const last = tokens[tokens.length - 1];
    if (last && last.type === 'text') last.content += s;
    else tokens.push({ type: 'text', content: s });
  };

  const matchField = (inner) => {
    // `[n]`-Repetition nur fürs Matching strippen.
    const rep = inner.match(/^(.*?)\s*\[\s*\d+\s*\]$/);
    const bare = rep ? rep[1].trim() : inner;
    const sep = bare.indexOf('::');
    const toPart = sep >= 0 ? bare.slice(0, sep).trim() : null;
    const fieldPart = sep >= 0 ? bare.slice(sep + 2).trim() : bare;
    if (!fieldPart) return null;
    const byTable = (btName) =>
      fields.find(f => f && f.name != null && lower(f.name) === lower(fieldPart)
        && f.baseTable != null && lower(f.baseTable) === lower(btName)) || null;
    if (toPart) {
      const bt = toBaseTable[lower(toPart)];
      return bt ? byTable(bt) : null;
    }
    const ctxBt = layoutTOName ? toBaseTable[lower(layoutTOName)] : null;
    if (ctxBt) {
      const hit = byTable(ctxBt);
      if (hit) return hit;
    }
    const nameHits = fields.filter(f => f && f.name != null && lower(f.name) === lower(fieldPart));
    return nameHits.length === 1 ? nameHits[0] : null;
  };

  const re = new RegExp(MERGE_ANCHOR_RE.source, 'g');
  let m;
  let pos = 0;
  while ((m = re.exec(textContent)) !== null) {
    pushText(textContent.slice(pos, m.index));
    pos = m.index + m[0].length;

    if (m[1] !== undefined) {
      // ƒ-Layoutformel: Pass-through, Auflösung leistet der Slot darunter.
      pushText(m[0]);
      continue;
    }
    if (m[2] !== undefined) {
      anchorsTotal += 1;
      const name = m[2].trim();
      const hit = variables.find(v => v && v.name != null && lower(v.name) === lower(name));
      if (hit) {
        anchorsResolved += 1;
        const tok = { type: 'variable', content: name, scope: name.startsWith('$$') ? 'global' : 'local' };
        if (hit.uuid) tok.uuid = String(hit.uuid);
        tokens.push(tok);
      } else {
        pushText(m[0]);
      }
      continue;
    }
    if (m[3] !== undefined) {
      anchorsTotal += 1;
      const inner = m[3].trim();
      const hit = matchField(inner);
      if (hit) {
        anchorsResolved += 1;
        const qualified = inner.indexOf('::') >= 0;
        const qualifier = layoutTOName || hit.baseTable || '';
        const tok = { type: 'field', content: qualified || !qualifier ? inner : `${qualifier}::${inner}` };
        if (hit.uuid) tok.uuid = String(hit.uuid);
        tokens.push(tok);
      } else {
        pushText(m[0]);
      }
      continue;
    }
    // {{Symbol}}
    anchorsTotal += 1;
    const symName = m[4].trim();
    const sym = symbols.find(s => s && s.norm != null && lower(s.norm) === lower(symName));
    if (sym && sym.valid) {
      anchorsResolved += 1;
      tokens.push({ type: 'function', content: 'Get' });
      tokens.push({ type: 'text', content: ' ( ' });
      tokens.push({ type: 'function', content: sym.text || symName });
      tokens.push({ type: 'text', content: ' )' });
    } else {
      pushText(m[0]);
    }
  }
  pushText(textContent.slice(pos));

  if (anchorsResolved === 0) return null;
  return { tokens, anchorsTotal, anchorsResolved };
}

function formatCalculation(rows, { object }) {
  const chunkRows = (rows || []).map(r => ({
    chunk_type: r.chunk_type,
    chunk_content: r.chunk_content,
    sub_function: r.sub_function,
    // Display-Calculation-Rettung (Template v1.4): Flag + geretteter Feld-Ref
    // der fehlklassifizierten %X:-Chunks — tokenFromChunk rendert daraus ein
    // Feld-Token statt einer Phantom-Variablen.
    is_display_slot: r.is_display_slot,
    rescued_field_uuid: r.rescued_field_uuid,
    rescued_field_name: r.rescued_field_name,
    rescued_to_name: r.rescued_to_name,
  }));
  const tokens = chunkRows.map((c, i, arr) => tokenFromChunk(c, i, arr));

  return {
    kind: 'calculation',
    object,
    tokens,
    plainText: tokens.map(t => t.content).join(''),
  };
}

/**
 * Public entry point.
 *
 * @param {Array} data - Rows from the appropriate SQL template
 * @param {Object} options - { kind, object, refs? }
 *   - kind:   'script' | 'customfunction' | 'calculation'
 *   - object: { uuid, name, file } or { hash } for calculations
 *   - refs:   optional array of script reference rows (only for kind=script)
 * @returns {Object} Token-format payload
 */
function format(data, options = {}) {
  const { kind, object = {}, refs } = options;

  switch (kind) {
    case 'script':
      return formatScript(data || [], { object, refs });
    case 'customfunction':
      return formatCustomFunction(data || [], { object });
    case 'field':
      return formatField(data || [], { object });
    case 'custommenu':
      return formatCustomMenu(data || [], { object });
    case 'calculation':
      return formatCalculation(data || [], { object });
    default:
      throw new Error(`tokens formatter: unknown kind '${kind}'`);
  }
}

module.exports = {
  format,
  synthesizeRecoveredCalcTokens,
  synthesizeMergeTextTokens,
  // Exported for testing
  tokenFromChunk,
  stripChunkWrap,
  decodeXmlEntities,
  reconcileTokensWithPlainText,
  parseFindRequests,
  composeFindRequestsText,
  parseSortList,
  composeSortListText,
  CHUNK_TYPE_MAP,
};
