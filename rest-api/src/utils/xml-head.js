/**
 * XML head probe — reads the leading bytes of a FileMaker SaXML export and
 * answers what the root element declares, without touching the body (an
 * export inbox reaches gigabytes; the verdict sits in the first few hundred
 * bytes of every known export).
 *
 * Encoding: FileMaker 22 writes UTF-16LE with BOM (FF FE), FileMaker 26 UTF-8.
 * The BOM decides; a UTF-16BE BOM (FE FF) is handled for completeness. Without
 * a BOM the head is decoded as UTF-8. A byte-level regex would silently miss
 * every UTF-16 export — the attribute name is interleaved with NUL bytes there.
 *
 * DDR info: `<FMSaveAsXML … Has_DDR_INFO="True|False">` — written only when the
 * export used "Include details for analysis tools". Without it the catalog has
 * no formula references at all (fields, functions, plug-in calls), although the
 * import looks complete. Result: true / false, or null when the head carries no
 * verdict — v2.0 exports (`<FMDynamicTemplate>`), truncated or foreign files,
 * read errors. null means "unknown", never "missing".
 */
'use strict';

const fsp = require('fs').promises;

// The root element of a SaXML export is < 600 bytes even in UTF-16; 4 KiB
// leaves room for longer file names/paths without a second read.
const HEAD_BYTES = 4096;
const RE_DDR_INFO = /<FMSaveAsXML\b[^>]*\bHas_DDR_INFO="(True|False)"/i;

/**
 * Decodes the head bytes according to their BOM (UTF-16LE / UTF-16BE) or as
 * UTF-8. An odd trailing byte of a UTF-16 cut is dropped.
 * @param {Buffer} buf
 * @returns {string}
 */
function decodeXmlHead(buf) {
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    const even = (buf.length - 2) & ~1;
    return buf.subarray(2, 2 + even).toString('utf16le');
  }
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const even = (buf.length - 2) & ~1;
    const le = Buffer.from(buf.subarray(2, 2 + even));
    le.swap16();
    return le.toString('utf16le');
  }
  return buf.toString('utf8');
}

/**
 * @param {string} text - decoded head
 * @returns {boolean|null} true/false from the root attribute, null = no verdict
 */
function parseDdrInfoHead(text) {
  const m = RE_DDR_INFO.exec(text);
  if (!m) return null;
  return m[1].toLowerCase() === 'true';
}

/** Buffer → verdict (decode + parse). */
function probeDdrInfoHead(buf) {
  return parseDdrInfoHead(decodeXmlHead(buf));
}

/**
 * Reads the first `bytes` of the file and probes them. Never throws — a
 * missing or unreadable file is "unknown" (null), the listing must not fail
 * because one inbox file is odd.
 * @param {string} filePath
 * @param {number} [bytes]
 * @returns {Promise<boolean|null>}
 */
async function readDdrInfoHead(filePath, bytes = HEAD_BYTES) {
  let fh = null;
  try {
    fh = await fsp.open(filePath, 'r');
    const buf = Buffer.alloc(bytes);
    const { bytesRead } = await fh.read(buf, 0, bytes, 0);
    return probeDdrInfoHead(buf.subarray(0, bytesRead));
  } catch {
    return null;
  } finally {
    if (fh) await fh.close().catch(() => { /* already closed */ });
  }
}

module.exports = {
  HEAD_BYTES,
  decodeXmlHead,
  parseDdrInfoHead,
  probeDdrInfoHead,
  readDdrInfoHead,
};
