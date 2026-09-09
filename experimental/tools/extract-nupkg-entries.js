#!/usr/bin/env node
// ---------------------------------------------------------------------------
// Experimental v2 tooling — not part of the published npm package.
//
// Extracts a handful of named entries out of a .nupkg (which is just a
// regular, non-zip64 ZIP archive) using only Node builtins (fs, zlib) — no
// `unzip` binary or npm dependency required, in keeping with the main tool's
// "Node builtins only" rule. Reads the central directory from the end of the
// archive (authoritative compressed/uncompressed sizes even for the
// streamed/data-descriptor case) rather than trusting local file headers.
//
// Usage: node extract-nupkg-entries.js <pkg.nupkg> <outDir> <entryPath...>
// Each <entryPath> is matched exactly against the ZIP entry name (forward
// slashes); matched files are written flat into <outDir> under their
// basename.
// ---------------------------------------------------------------------------
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const EOCD_SIG = 0x06054b50;
const CDH_SIG = 0x02014b50;
const LFH_SIG = 0x04034b50;

function findEndOfCentralDirectory(buf) {
    // EOCD is at least 22 bytes, and can be followed by up to 65535 bytes of
    // comment, so scan backwards from the end.
    const maxCommentLen = 65535;
    const minPos = Math.max(0, buf.length - 22 - maxCommentLen);
    for (let i = buf.length - 22; i >= minPos; i--) {
        if (buf.readUInt32LE(i) === EOCD_SIG) return i;
    }
    throw new Error('not a valid zip file (no End Of Central Directory record found)');
}

function readCentralDirectory(buf) {
    const eocdPos = findEndOfCentralDirectory(buf);
    const entryCount = buf.readUInt16LE(eocdPos + 10);
    const cdOffset = buf.readUInt32LE(eocdPos + 16);

    const entries = [];
    let pos = cdOffset;
    for (let i = 0; i < entryCount; i++) {
        if (buf.readUInt32LE(pos) !== CDH_SIG) {
            throw new Error(`central directory entry ${i} has a bad signature at offset ${pos}`);
        }
        const method = buf.readUInt16LE(pos + 10);
        const compSize = buf.readUInt32LE(pos + 20);
        const uncompSize = buf.readUInt32LE(pos + 24);
        const nameLen = buf.readUInt16LE(pos + 28);
        const extraLen = buf.readUInt16LE(pos + 30);
        const commentLen = buf.readUInt16LE(pos + 32);
        const localHeaderOffset = buf.readUInt32LE(pos + 42);
        const name = buf.toString('utf8', pos + 46, pos + 46 + nameLen);

        entries.push({ name, method, compSize, uncompSize, localHeaderOffset });
        pos += 46 + nameLen + extraLen + commentLen;
    }
    return entries;
}

function extractEntry(buf, entry) {
    const pos = entry.localHeaderOffset;
    if (buf.readUInt32LE(pos) !== LFH_SIG) {
        throw new Error(`local file header for "${entry.name}" has a bad signature at offset ${pos}`);
    }
    const nameLen = buf.readUInt16LE(pos + 26);
    const extraLen = buf.readUInt16LE(pos + 28);
    const dataStart = pos + 30 + nameLen + extraLen;
    const compressed = buf.subarray(dataStart, dataStart + entry.compSize);

    if (entry.method === 0) return compressed; // stored, no compression
    if (entry.method === 8) return zlib.inflateRawSync(compressed); // deflate
    throw new Error(`entry "${entry.name}" uses unsupported ZIP compression method ${entry.method}`);
}

function main() {
    const [, , nupkgPath, outDir, ...wantedNames] = process.argv;
    if (!nupkgPath || !outDir || wantedNames.length === 0) {
        console.error('usage: extract-nupkg-entries.js <pkg.nupkg> <outDir> <entryPath...>');
        process.exit(1);
    }

    const buf = fs.readFileSync(nupkgPath);
    const entries = readCentralDirectory(buf);
    const byName = new Map(entries.map(e => [e.name, e]));

    fs.mkdirSync(outDir, { recursive: true });

    let missing = [];
    for (const wanted of wantedNames) {
        const entry = byName.get(wanted);
        if (!entry) {
            missing.push(wanted);
            continue;
        }
        const data = extractEntry(buf, entry);
        const outPath = path.join(outDir, path.basename(wanted));
        fs.writeFileSync(outPath, data);
        console.error(`extracted ${wanted} -> ${outPath} (${data.length} bytes)`);
    }

    if (missing.length > 0) {
        console.error(`\nEntries not found in ${nupkgPath}:\n  ${missing.join('\n  ')}`);
        console.error('\nAvailable entries:');
        for (const e of entries) console.error(`  ${e.name}`);
        process.exit(1);
    }
}

main();
