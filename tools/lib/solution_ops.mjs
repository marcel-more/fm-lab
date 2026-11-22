#!/usr/bin/env node
/**
 * solution_ops.mjs — JSON and archive helpers for tools/solution.sh.
 *
 *   node solution_ops.mjs uuid
 *   node solution_ops.mjs rename-manifest <solution.json> <old-id> <new-id>
 *   node solution_ops.mjs write-context <file> <solution> <owner> <note>
 *   node solution_ops.mjs export <bundle-dir> <out.zip> <include-xml: true|false>
 *
 * Node standard library only (Node >= 22) — no Python, no zip binary. The zip
 * writer streams every file through zlib (bundles reach several GB) and switches
 * to Zip64 records at the same thresholds as Python's zipfile (2 GiB - 1), so
 * archives open in every common unzip tool.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import zlib from 'node:zlib';

function die(msg) {
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

const utcStamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

// -------------------- JSON commands --------------------

function renameManifest(file, oldId, newId) {
  let m = {};
  try {
    m = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!m || typeof m !== 'object' || Array.isArray(m)) m = {};
  } catch {
    m = {};
  }
  m.id = newId;
  if (m.display_name === oldId) m.display_name = newId;
  writeJson(file, m);
}

function writeContext(file, solution, owner, note) {
  writeJson(file, {
    context_version: 1,
    solution,
    owner,
    created_at: utcStamp(),
    note,
  });
}

// -------------------- Zip writer --------------------

const ZIP64_LIMIT = 2 ** 31 - 1; // same threshold as Python's zipfile
const U32_MAX = 0xffffffff;

function dosDateTime(mtime) {
  const d = mtime.getFullYear() < 1980 ? new Date(1980, 0, 1) : mtime;
  return {
    time: (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1),
    date: ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(),
  };
}

class ZipWriter {
  constructor(file) {
    this.fd = fs.openSync(file, 'w');
    this.pos = 0;
    this.entries = [];
  }

  /** Append at the current end of the archive. */
  write(buf) {
    this.writeAt(buf, this.pos);
    this.pos += buf.length;
  }

  /** Overwrite already written bytes (header patching). */
  writeAt(buf, at) {
    let off = 0;
    while (off < buf.length) off += fs.writeSync(this.fd, buf, off, buf.length - off, at + off);
  }

  async addFile(fullPath, arcName) {
    const st = fs.statSync(fullPath);
    const name = Buffer.from(arcName.split(path.sep).join('/'), 'utf8');
    const utf8Flag = /^[\x00-\x7f]*$/.test(arcName) ? 0 : 0x0800;
    const zip64 = st.size * 1.05 > ZIP64_LIMIT;
    const { time, date } = dosDateTime(st.mtime);
    const offset = this.pos;

    // Local header; CRC and sizes are patched in after the data is written.
    const extra = zip64 ? Buffer.alloc(20) : Buffer.alloc(0);
    if (zip64) {
      extra.writeUInt16LE(0x0001, 0);
      extra.writeUInt16LE(16, 2);
    }
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0);
    lh.writeUInt16LE(zip64 ? 45 : 20, 4);
    lh.writeUInt16LE(utf8Flag, 6);
    lh.writeUInt16LE(8, 8); // deflate
    lh.writeUInt16LE(time, 10);
    lh.writeUInt16LE(date, 12);
    lh.writeUInt16LE(name.length, 26);
    lh.writeUInt16LE(extra.length, 28);
    this.write(Buffer.concat([lh, name, extra]));

    let crc = 0;
    let usize = 0;
    let csize = 0;
    const tap = new Transform({
      transform(chunk, _enc, cb) {
        crc = zlib.crc32(chunk, crc);
        usize += chunk.length;
        cb(null, chunk);
      },
    });
    await pipeline(fs.createReadStream(fullPath), tap, zlib.createDeflateRaw(), async (source) => {
      for await (const chunk of source) {
        this.write(chunk);
        csize += chunk.length;
      }
    });

    if (!zip64 && (usize > ZIP64_LIMIT || csize > ZIP64_LIMIT)) {
      throw new Error(`${arcName} grew past the 2 GiB limit while it was being archived`);
    }
    const patch = Buffer.alloc(12);
    patch.writeUInt32LE(crc >>> 0, 0);
    patch.writeUInt32LE(zip64 ? U32_MAX : csize, 4);
    patch.writeUInt32LE(zip64 ? U32_MAX : usize, 8);
    this.writeAt(patch, offset + 14);
    if (zip64) {
      const sizes = Buffer.alloc(16);
      sizes.writeBigUInt64LE(BigInt(usize), 0);
      sizes.writeBigUInt64LE(BigInt(csize), 8);
      this.writeAt(sizes, offset + 30 + name.length + 4);
    }

    this.entries.push({
      name, utf8Flag, time, date, crc: crc >>> 0, usize, csize, offset,
      mode: st.mode & 0xffff,
    });
  }

  close() {
    const cdOffset = this.pos;
    for (const e of this.entries) {
      const ext = [];
      let usize = e.usize;
      let csize = e.csize;
      let offset = e.offset;
      if (usize > ZIP64_LIMIT || csize > ZIP64_LIMIT) {
        ext.push(usize, csize);
        usize = U32_MAX;
        csize = U32_MAX;
      }
      if (offset > ZIP64_LIMIT) {
        ext.push(offset);
        offset = U32_MAX;
      }
      let extra = Buffer.alloc(0);
      if (ext.length) {
        extra = Buffer.alloc(4 + 8 * ext.length);
        extra.writeUInt16LE(0x0001, 0);
        extra.writeUInt16LE(8 * ext.length, 2);
        ext.forEach((v, i) => extra.writeBigUInt64LE(BigInt(v), 4 + 8 * i));
      }
      const version = ext.length ? 45 : 20;
      const ch = Buffer.alloc(46);
      ch.writeUInt32LE(0x02014b50, 0);
      ch.writeUInt16LE((3 << 8) | version, 4); // made by: Unix
      ch.writeUInt16LE(version, 6);
      ch.writeUInt16LE(e.utf8Flag, 8);
      ch.writeUInt16LE(8, 10);
      ch.writeUInt16LE(e.time, 12);
      ch.writeUInt16LE(e.date, 14);
      ch.writeUInt32LE(e.crc, 16);
      ch.writeUInt32LE(csize, 20);
      ch.writeUInt32LE(usize, 24);
      ch.writeUInt16LE(e.name.length, 28);
      ch.writeUInt16LE(extra.length, 30);
      ch.writeUInt32LE((e.mode << 16) >>> 0, 38);
      ch.writeUInt32LE(offset, 42);
      this.write(Buffer.concat([ch, e.name, extra]));
    }
    const cdSize = this.pos - cdOffset;
    const count = this.entries.length;

    if (count > 0xffff || cdOffset > ZIP64_LIMIT || cdSize > ZIP64_LIMIT) {
      const z64Offset = this.pos;
      const rec = Buffer.alloc(56);
      rec.writeUInt32LE(0x06064b50, 0);
      rec.writeBigUInt64LE(44n, 4);
      rec.writeUInt16LE(45, 12);
      rec.writeUInt16LE(45, 14);
      rec.writeBigUInt64LE(BigInt(count), 24);
      rec.writeBigUInt64LE(BigInt(count), 32);
      rec.writeBigUInt64LE(BigInt(cdSize), 40);
      rec.writeBigUInt64LE(BigInt(cdOffset), 48);
      const loc = Buffer.alloc(20);
      loc.writeUInt32LE(0x07064b50, 0);
      loc.writeBigUInt64LE(BigInt(z64Offset), 8);
      loc.writeUInt32LE(1, 16);
      this.write(Buffer.concat([rec, loc]));
    }

    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(Math.min(count, 0xffff), 8);
    eocd.writeUInt16LE(Math.min(count, 0xffff), 10);
    eocd.writeUInt32LE(Math.min(cdSize, U32_MAX), 12);
    eocd.writeUInt32LE(Math.min(cdOffset, U32_MAX), 16);
    this.write(eocd);
    fs.closeSync(this.fd);
  }
}

// -------------------- export --------------------

const SKIP_SUFFIXES = ['.tmp', '.lock', '.wal'];

// Files of state/ that belong to the solution, not to a run: they travel with
// the package (the rest of state/ — locks, run records, logs — stays behind).
const PORTABLE_STATE = new Set(['dataflow_profile.json']);

/**
 * Package = manifest + catalog DB + annotations DB + the portable state files
 * (PORTABLE_STATE, e.g. the data trace profile). Excludes the rest of the
 * volatile state/ and (unless includeXml) the xml/ sources at the bundle top
 * level, plus temp/lock/WAL files anywhere. Symlinked directories are not followed.
 */
function collectFiles(solDir, includeXml) {
  const files = [];
  const walk = (dir, rel) => {
    const top = rel.length ? rel[0] : null;
    if (top === 'xml' && !includeXml) return;
    if (top === 'state') {
      // only the portable files directly in state/, never its subfolders
      if (rel.length > 1) return;
      for (const name of [...PORTABLE_STATE].sort()) {
        const full = path.join(dir, name);
        try {
          if (fs.lstatSync(full).isFile()) files.push({ full, arc: path.join(path.basename(solDir), 'state', name) });
        } catch { /* not present */ }
      }
      return;
    }
    const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1));
    const subdirs = [];
    for (const ent of entries) {
      const full = path.join(dir, ent.name);
      let isDir = ent.isDirectory();
      let isFile = ent.isFile();
      if (ent.isSymbolicLink()) {
        let target = null;
        try { target = fs.statSync(full); } catch { /* dangling */ }
        if (!target) {
          process.stderr.write(`WARNING: skipping dangling symlink ${full}\n`);
          continue;
        }
        isDir = false; // like os.walk(followlinks=False): never descend
        isFile = target.isFile();
      }
      if (isDir) { subdirs.push(ent.name); continue; }
      if (!isFile) continue;
      if (SKIP_SUFFIXES.some((s) => ent.name.endsWith(s))) {
        // A non-empty annotations WAL means the sidecar holds un-checkpointed
        // writes (API keeps it RW) — the packaged fm_annotations.duckdb may be
        // stale. Warn, don't fail.
        if (ent.name === 'fm_annotations.duckdb.wal') {
          const size = fs.statSync(full).size;
          if (size > 0) {
            process.stderr.write(`WARNING: skipping non-empty ${ent.name} (${size} bytes) — `
              + 'annotations in the package may be stale. Stop the API '
              + '(checkpoints the sidecar) and re-export for a current state.\n');
          }
        }
        continue;
      }
      files.push({ full, arc: path.join(path.basename(solDir), ...rel, ent.name) });
    }
    for (const name of subdirs) walk(path.join(dir, name), [...rel, name]);
  };
  walk(solDir, []);
  return files;
}

async function exportBundle(solDir, out, includeXml) {
  const files = collectFiles(solDir, includeXml);
  // Written under a *.tmp name (excluded by the walker) and renamed when complete,
  // so an aborted export never leaves a truncated zip behind.
  const tmp = `${out}.${process.pid}.tmp`;
  const zip = new ZipWriter(tmp);
  try {
    for (const f of files) await zip.addFile(f.full, f.arc);
    zip.close();
    fs.renameSync(tmp, out);
  } catch (err) {
    try { fs.closeSync(zip.fd); } catch { /* already closed */ }
    fs.rmSync(tmp, { force: true });
    throw err;
  }
  console.log(`Exported: ${out} (${(fs.statSync(out).size / 1024 / 1024).toFixed(1)} MB)`);
}

// -------------------- main --------------------

const [cmd, ...args] = process.argv.slice(2);
try {
  switch (cmd) {
    case 'uuid':
      console.log(crypto.randomUUID());
      break;
    case 'rename-manifest':
      if (args.length !== 3) die('usage: rename-manifest <solution.json> <old-id> <new-id>');
      renameManifest(...args);
      break;
    case 'write-context':
      if (args.length !== 4) die('usage: write-context <file> <solution> <owner> <note>');
      writeContext(...args);
      break;
    case 'export':
      if (args.length !== 3) die('usage: export <bundle-dir> <out.zip> <include-xml>');
      await exportBundle(args[0], args[1], args[2] === 'true');
      break;
    default:
      die(`unknown command '${cmd ?? ''}' (uuid | rename-manifest | write-context | export)`);
  }
} catch (err) {
  die(err.message);
}
