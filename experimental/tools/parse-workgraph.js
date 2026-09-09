#!/usr/bin/env node
// ---------------------------------------------------------------------------
// Experimental v2 tooling — not part of the published npm package.
//
// Parses a dxc `-Fc` disassembly (produced with `-Zi -Qembed_debug` for full
// fidelity — see run-dxc.sh/.ps1 --mode compile) into the same rough shape
// the current regex-based tool (src/nodes.js et al.) extracts from raw HLSL,
// but sourced from the compiled DXIL metadata instead of text scanning.
//
// Two metadata systems are combined, see experimental/README.md for the
// sourcing/verification behind each:
//   - `!dx.entryPoints` (+ the tag scheme documented at
//     https://microsoft.github.io/DirectX-Specs/d3d/WorkGraphs.html#dxil):
//     launch mode, NumThreads, dispatch grid, NodeID self/linkage, and each
//     input/output record's resolved MaxRecords — all dead-code-eliminated
//     and #define-resolved by dxc itself.
//   - Debug info (`!DISubprogram`/`!DICompositeType`/`!dx.source.contents`,
//     from `-Zi -Qembed_debug`): each node's defining (file, line), the
//     record types' real names and field lists, and the original — comments
//     and all — per-file source text, used to recover a node's doc comment
//     and (best-effort) its original unevaluated attribute expressions.
//
// Global-resource-usage extraction (`!dx.resources` + per-node
// `createHandleForLib` calls) is present but UNVERIFIED — this repo's
// fixture had no global resources until just now, so this path hasn't been
// tested against a real compile yet. Treat `globalsUsed` output as
// provisional until confirmed.
//
// Usage: node parse-workgraph.js <disassembly.ll> [--json]
// ---------------------------------------------------------------------------
'use strict';

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Tag scheme (documented: DirectX-Specs WorkGraphs.html "DXIL Shader
// function attributes", cross-checked against DxilMetadataHelper.h and
// empirically against this repo's fixture — see experimental/README.md).
// ---------------------------------------------------------------------------

const PROP_TAGS = {
    4: 'numThreads',
    5: 'shaderFlags',
    8: 'shaderKind',
    13: 'nodeLaunchType',
    14: 'isProgramEntry',
    15: 'nodeID',
    16: 'localRootArgumentsTableIndex',
    17: 'shareInputOf',
    18: 'dispatchGrid',
    19: 'maxRecursionDepth',
    20: 'inputs',
    21: 'outputs',
    22: 'maxDispatchGrid',
};

// Confirmed for launch types 1-3 in the official spec table; 4 (mesh) is
// empirically observed in this fixture's own compiled output but missing
// from that same spec table (looks like a doc gap, not a sign it's
// unofficial — mesh launch nodes are documented extensively elsewhere on
// that page). Unknown values fall back to a numeric label rather than
// failing, deliberately, since this table isn't guaranteed exhaustive.
const LAUNCH_TYPES = { 1: 'broadcasting', 2: 'coalescing', 3: 'thread', 4: 'mesh' };

// ---------------------------------------------------------------------------
// LLVM metadata text parser: just enough of the grammar dxc's -Fc emits to
// walk `!N = !{...}` tuples and `!N = !DIXxx(key: val, ...)` debug-info
// nodes. Not a general LLVM IR parser.
// ---------------------------------------------------------------------------

function splitTopLevel(s) {
    const parts = [];
    let depth = 0;
    let cur = '';
    let inStr = false;
    for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (inStr) {
            cur += c;
            if (c === '"') inStr = false;
            continue;
        }
        if (c === '"') {
            inStr = true;
            cur += c;
            continue;
        }
        if (c === '{' || c === '(') depth++;
        if (c === '}' || c === ')') depth--;
        if (c === ',' && depth === 0) {
            parts.push(cur.trim());
            cur = '';
            continue;
        }
        cur += c;
    }
    if (cur.trim().length) parts.push(cur.trim());
    return parts;
}

// LLVM metadata strings escape every special/non-ASCII byte as \XX (hex);
// there's never a literal unescaped `"` inside one, so a plain scan for the
// closing quote is safe.
function decodeLLVMString(inner) {
    const bytes = [];
    for (let i = 0; i < inner.length; i++) {
        if (inner[i] === '\\' && /^[0-9A-Fa-f]{2}/.test(inner.slice(i + 1, i + 3))) {
            bytes.push(parseInt(inner.slice(i + 1, i + 3), 16));
            i += 2;
        } else {
            bytes.push(inner.charCodeAt(i));
        }
    }
    return Buffer.from(bytes).toString('utf8');
}

function parseElement(tok) {
    tok = tok.trim();
    if (tok === 'null') return null;
    if (tok === 'true') return true;
    if (tok === 'false') return false;
    let m;
    if ((m = tok.match(/^!(\d+)$/))) return { $ref: Number(m[1]) };
    if ((m = tok.match(/^i\d+\s+(-?\d+|true|false)$/))) {
        if (m[1] === 'true') return true;
        if (m[1] === 'false') return false;
        return Number(m[1]);
    }
    if ((m = tok.match(/^!"([^"]*)"$/))) return decodeLLVMString(m[1]);
    if ((m = tok.match(/^"([^"]*)"$/))) return decodeLLVMString(m[1]);
    if (/^-?\d+$/.test(tok)) return Number(tok);
    // Global/function references: plain `@Name` for unmangled names (HLSL
    // node function names), or `@"Mangled\01Name@@..."` for anything MSVC
    // name-mangling produced (resource globals — `?`/`@` in the mangled
    // name require LLVM's quoted-identifier syntax), which can itself be
    // wrapped in a `bitcast (... to ...)` constant expression. Search
    // rather than anchor, since bitcast wrapping means the reference isn't
    // necessarily at the start of the token.
    // Deliberately NOT decoded (unlike !"..." string metadata elsewhere):
    // this raw form (e.g. literal `\01?itemMeta@@...`) is exactly what
    // recurs verbatim at each reference site in the disassembly text
    // (declaration, every createHandleForLib call site), which is what
    // findGlobalsUsed() text-matches against — decoding here would break
    // that match for no benefit, since this value is never shown to a user
    // directly (paramKind/recordType/name from debug info cover display).
    if ((m = tok.match(/@"([^"]*)"/))) return { $func: m[1] };
    if ((m = tok.match(/@([\w.$?]+)/))) return { $func: m[1] };
    if (/^[A-Za-z_][\w]*$/.test(tok)) return tok; // bare enum-like identifier (DW_TAG_*, DIFlag* etc.)
    return { $raw: tok };
}

function parseRHS(rhs) {
    rhs = rhs.trim();
    if (rhs.startsWith('distinct ')) rhs = rhs.slice('distinct '.length).trim();
    if (rhs.startsWith('!{') && rhs.endsWith('}')) {
        return { $tuple: splitTopLevel(rhs.slice(2, -1)).map(parseElement) };
    }
    const m = rhs.match(/^!(DI\w+)\((.*)\)$/s);
    if (m) {
        const fields = { $kind: m[1] };
        for (const pair of splitTopLevel(m[2])) {
            const idx = pair.indexOf(':');
            if (idx === -1) continue;
            fields[pair.slice(0, idx).trim()] = parseElement(pair.slice(idx + 1).trim());
        }
        return fields;
    }
    return { $raw: rhs };
}

function loadDisassembly(filePath) {
    const text = fs.readFileSync(filePath, 'utf8');
    const rawMap = new Map();
    const named = new Map();
    for (const line of text.split(/\r?\n/)) {
        let m = line.match(/^!(\d+) = (.*)$/);
        if (m) {
            rawMap.set(Number(m[1]), m[2]);
            continue;
        }
        m = line.match(/^!([A-Za-z][\w.]*) = !\{(.*)\}$/);
        if (m) {
            named.set(
                m[1],
                splitTopLevel(m[2]).map((t) => {
                    const mm = t.match(/^!(\d+)$/);
                    return mm ? Number(mm[1]) : null;
                })
            );
        }
    }
    return { rawMap, named, text };
}

// ---------------------------------------------------------------------------
// Deep resolver: !N refs -> fully resolved values, memoized, with a
// call-stack (not visited-set) cycle guard so legitimately shared/deduped
// nodes (very common in this format — see README) aren't misflagged.
// ---------------------------------------------------------------------------

function makeResolver(rawMap) {
    const cache = new Map();
    const resolving = new Set();

    function resolveDeep(v) {
        if (v === null || typeof v !== 'object') return v;
        if (Array.isArray(v)) return v.map(resolveDeep);
        if ('$ref' in v) return resolveId(v.$ref);
        if ('$tuple' in v) return v.$tuple.map(resolveDeep);
        if ('$kind' in v) {
            const out = { $kind: v.$kind };
            for (const k of Object.keys(v)) if (k !== '$kind') out[k] = resolveDeep(v[k]);
            return out;
        }
        return v; // $func / $raw / already-plain values
    }

    function resolveId(id) {
        if (cache.has(id)) return cache.get(id);
        if (resolving.has(id)) return { $cycle: id };
        if (!rawMap.has(id)) return { $missing: id };
        resolving.add(id);
        const deep = resolveDeep(parseRHS(rawMap.get(id)));
        resolving.delete(id);
        cache.set(id, deep);
        return deep;
    }

    return resolveId;
}

// ---------------------------------------------------------------------------
// Path normalization: dxc keys file identity by the literal include-path
// spelling used at each #include site (confirmed the hard way — see the
// #pragma once finding in experimental/README.md), so the same physical
// file can show up under multiple spellings in both debug-info file refs
// and dx.source.contents. Normalize both sides the same way so lookups
// still join correctly.
// ---------------------------------------------------------------------------

function normalizePath(p) {
    return path.posix.normalize(p.replace(/\\/g, '/')).replace(/^(\.\/)+/, '');
}

// ---------------------------------------------------------------------------
// Comment extraction: mirrors src/comments.js's heuristic (the contiguous
// `//` block immediately preceding, no blank line in between) but is
// line-based since that's what debug info gives us (a defining line
// number), not the character-offset addressing src/comments.js uses against
// live source. Skips back over the HLSL attribute lines
// ([Shader("node")] etc.) directly above the function signature first.
// ---------------------------------------------------------------------------

function extractLeadingComment(fileContent, functionLine) {
    const lines = fileContent.split('\n');
    let i = functionLine - 1 - 1; // 0-based index of the line above the function's own line
    while (i >= 0 && /^\s*\[.*\]\s*$/.test(lines[i])) i--;
    const collected = [];
    while (i >= 0 && /^\s*\/\//.test(lines[i])) {
        collected.unshift(lines[i].replace(/^\s*\/\/ ?/, ''));
        i--;
    }
    return collected.length ? collected.join('\n').trim() : null;
}

// ---------------------------------------------------------------------------
// High-level extraction
// ---------------------------------------------------------------------------

function decodeIORecord(list) {
    const rec = {};
    if (!Array.isArray(list)) return rec;
    for (let i = 0; i < list.length; i += 2) {
        const tag = list[i];
        const val = list[i + 1];
        if (tag === 1) rec.ioFlagsRaw = val; // not decoded further — record kind/type name comes from debug info instead
        else if (tag === 2) rec.recordLayoutRaw = val; // best-effort byte layout, prefer debug-info field list for display
        else if (tag === 3) rec.maxRecords = val;
        else if (tag === 0 && Array.isArray(val)) rec.linkedNodeID = { name: val[0], index: val[1] };
        else (rec.unknownTags = rec.unknownTags || []).push([tag, val]);
    }
    return rec;
}

function decodeProps(list) {
    const out = {};
    if (!Array.isArray(list)) return out;
    for (let i = 0; i < list.length; i += 2) {
        const tag = list[i];
        const val = list[i + 1];
        const key = PROP_TAGS[tag];
        if (!key) {
            (out.unknownTags = out.unknownTags || []).push([tag, val]);
            continue;
        }
        if (key === 'nodeLaunchType') {
            out.nodeLaunchType = { raw: val, label: LAUNCH_TYPES[val] || `unknown(${val})` };
        } else if (key === 'nodeID') {
            out.nodeID = Array.isArray(val) ? { name: val[0], index: val[1] } : val;
        } else if (key === 'inputs' || key === 'outputs') {
            out[key] = Array.isArray(val) ? val.map(decodeIORecord) : [];
        } else {
            out[key] = val;
        }
    }
    return out;
}

// Same INPUT_TYPES/OUTPUT_TYPES vocabulary as src/nodes.js — used here to
// tell an actual node-I/O parameter apart from an ordinary one (system-value
// scalars like `uint gtid`/`uint dtid`, or mesh-shader `out
// indices/vertices/primitives` arrays, which aren't work-graph edges). These
// can appear interleaved with the I/O parameters in the function's parameter
// list (e.g. CollectNode's `uint gtid` comes before its input record), so
// they have to be filtered out before zipping debug-info params against the
// !dx.entryPoints inputs/outputs lists positionally — the two lists don't
// line up 1:1 with the full DISubroutineType parameter list otherwise.
const NODE_IO_KINDS = new Set([
    'RWDispatchNodeInputRecord',
    'DispatchNodeInputRecord',
    'RWGroupNodeInputRecords',
    'GroupNodeInputRecords',
    'ThreadNodeInputRecord',
    'EmptyNodeInput',
    'NodeOutputArray',
    'NodeOutput',
    'EmptyNodeOutputArray',
    'EmptyNodeOutput',
]);

// Walks a DISubroutineType's `types` list (element 0 is the return type,
// always null for these — node functions return void) to recover each
// node-I/O parameter's real HLSL type name, e.g.
// "GroupNodeInputRecords<ResultRecord>", including the record struct's field
// list when debug info nested it. Non-node-I/O parameters are dropped (see
// NODE_IO_KINDS above), so the result lines up positionally with
// !dx.entryPoints' inputs/outputs lists.
function describeParams(subprogram) {
    const subroutine = subprogram.type;
    if (!subroutine || subroutine.$kind !== 'DISubroutineType' || !Array.isArray(subroutine.types)) return [];
    return subroutine.types
        .slice(1) // drop the leading return-type slot
        .filter((t) => t && typeof t === 'object' && typeof t.name === 'string')
        .map((t) => {
            const m = t.name.match(/^(\w+)<(\w+)>$/);
            return { paramKind: m ? m[1] : t.name, recordType: m ? m[2] : null, templateParams: t.templateParams };
        })
        .filter((p) => NODE_IO_KINDS.has(p.paramKind))
        .map(({ paramKind, recordType, templateParams }) => {
            let recordFields = null;
            if (recordType && Array.isArray(templateParams)) {
                const recordDIType = templateParams[0] && templateParams[0].type;
                if (recordDIType && Array.isArray(recordDIType.elements)) {
                    recordFields = recordDIType.elements
                        .filter((e) => e && e.$kind === 'DIDerivedType')
                        .map((e) => ({ name: e.name, sizeBits: e.size }));
                }
            }
            return { paramKind, recordType, recordFields };
        });
}

function getSubprogramsByFunctionName(resolveId, named) {
    const byName = new Map();
    const cuIds = named.get('llvm.dbg.cu') || [];
    for (const cuId of cuIds) {
        const cu = resolveId(cuId);
        const subprograms = Array.isArray(cu.subprograms) ? cu.subprograms : [];
        for (const sp of subprograms) {
            if (!sp || sp.$kind !== 'DISubprogram') continue;
            const funcName = sp.function && sp.function.$func;
            if (!funcName) continue;
            byName.set(funcName, {
                name: sp.name,
                file: sp.file && sp.file.filename,
                line: sp.line,
                scopeLine: sp.scopeLine,
                params: describeParams(sp),
            });
        }
    }
    return byName;
}

function getSourceFiles(resolveId, named) {
    const byPath = new Map();
    for (const id of named.get('dx.source.contents') || []) {
        const pair = resolveId(id);
        if (Array.isArray(pair) && pair.length === 2) {
            byPath.set(normalizePath(pair[0]), pair[1]);
        }
    }
    return byPath;
}

function extractFunctionBody(disText, funcName) {
    const m = disText.match(new RegExp(`define void @${funcName}\\(\\)\\s*\\{([\\s\\S]*?)\\n\\}`));
    return m ? m[1] : '';
}

// UNVERIFIED — see the module doc comment. Written against the documented
// !dx.resources shape and general DXIL resource-binding conventions, not
// yet checked against a real compiled example (this fixture had no global
// resources until this same change added one; needs a fresh compile to
// confirm/fix).
function getResources(resolveId, named) {
    const ids = named.get('dx.resources') || [];
    if (ids.length === 0) return null;
    const resourceLists = resolveId(ids[0]); // [SRVs, UAVs, CBVs, Samplers]
    if (!Array.isArray(resourceLists)) return null;
    const classes = ['SRV', 'UAV', 'CBV', 'Sampler'];
    const resources = [];
    resourceLists.forEach((list, classIdx) => {
        if (!Array.isArray(list)) return;
        for (const entry of list) {
            if (!Array.isArray(entry)) continue;
            const globalRef = entry.find((e) => e && typeof e === 'object' && e.$func);
            const name = entry.find((e) => typeof e === 'string');
            resources.push({
                resourceClass: classes[classIdx],
                globalVariable: globalRef ? globalRef.$func : null,
                name: name || null,
                raw: entry,
            });
        }
    });
    return resources;
}

// UNVERIFIED, same caveat as getResources — best-effort text scan of a
// node's own DXIL function body for createHandleForLib calls, matched back
// to a resource by the referenced global's mangled name.
function findGlobalsUsed(disText, funcName, resources) {
    if (!resources || resources.length === 0) return [];
    const body = extractFunctionBody(disText, funcName);
    const used = new Set();
    for (const res of resources) {
        if (res.globalVariable && body.includes(`@"${res.globalVariable}"`)) {
            used.add(res.name || res.globalVariable);
        }
    }
    return [...used];
}

function buildGraph(dis) {
    const resolveId = makeResolver(dis.rawMap);
    const subprogramsByName = getSubprogramsByFunctionName(resolveId, dis.named);
    const sourceFiles = getSourceFiles(resolveId, dis.named);
    const resources = getResources(resolveId, dis.named);

    const nodes = [];
    for (const id of dis.named.get('dx.entryPoints') || []) {
        const ep = resolveId(id);
        const funcRef = ep[0];
        if (!funcRef || typeof funcRef !== 'object' || !funcRef.$func) continue; // skip the library-level null placeholder
        const funcName = funcRef.$func;
        const props = decodeProps(ep[4]);
        const debugInfo = subprogramsByName.get(funcName);

        let comment = null;
        if (debugInfo && debugInfo.file && debugInfo.line) {
            const content = sourceFiles.get(normalizePath(debugInfo.file));
            if (content) comment = extractLeadingComment(content, debugInfo.line);
        }

        nodes.push({
            name: funcName,
            launchMode: props.nodeLaunchType || null,
            isProgramEntry: !!props.isProgramEntry,
            numThreads: props.numThreads || null,
            dispatchGrid: props.dispatchGrid || null,
            maxDispatchGrid: props.maxDispatchGrid || null,
            nodeID: props.nodeID || null,
            inputs: (props.inputs || []).map((rec, i) => ({ ...rec, ...(debugInfo && debugInfo.params[i]) })),
            outputs: (props.outputs || []).map((rec, i) => ({
                ...rec,
                ...(debugInfo && debugInfo.params[(props.inputs || []).length + i]),
            })),
            sourceFile: debugInfo ? debugInfo.file : null,
            sourceLine: debugInfo ? debugInfo.line : null,
            comment,
            globalsUsed: findGlobalsUsed(dis.text, funcName, resources),
        });
    }

    return { nodes, resources };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function main() {
    const args = process.argv.slice(2);
    const filePath = args.find((a) => !a.startsWith('--'));
    if (!filePath) {
        console.error('usage: parse-workgraph.js <disassembly.ll> [--json]');
        process.exit(1);
    }
    const dis = loadDisassembly(filePath);
    const graph = buildGraph(dis);

    if (args.includes('--json')) {
        console.log(JSON.stringify(graph, null, 2));
        return;
    }

    for (const node of graph.nodes) {
        console.log(`\n${node.name}  (${node.launchMode ? node.launchMode.label : 'unknown'}${node.isProgramEntry ? ', entry' : ''})`);
        if (node.comment) console.log(`  # ${node.comment.split('\n').join('\n  # ')}`);
        console.log(`  source: ${node.sourceFile}:${node.sourceLine}`);
        if (node.numThreads) console.log(`  NumThreads: (${node.numThreads.join(', ')})`);
        if (node.dispatchGrid) console.log(`  DispatchGrid: (${node.dispatchGrid.join(', ')})`);
        if (node.maxDispatchGrid) console.log(`  MaxDispatchGrid: (${node.maxDispatchGrid.join(', ')})`);
        for (const inp of node.inputs) {
            console.log(`  in:  ${inp.paramKind}<${inp.recordType}>${inp.maxRecords != null ? ` maxRecords=${inp.maxRecords}` : ''}`);
        }
        for (const out of node.outputs) {
            const link = out.linkedNodeID ? ` -> ${out.linkedNodeID.name}[${out.linkedNodeID.index}]` : '';
            console.log(`  out: ${out.paramKind}<${out.recordType}> maxRecords=${out.maxRecords}${link}`);
        }
        if (node.globalsUsed.length) console.log(`  globals: ${node.globalsUsed.join(', ')}`);
    }
    if (graph.resources) {
        console.log('\nresources:');
        for (const r of graph.resources) console.log(`  ${r.resourceClass} ${r.name} (${r.globalVariable})`);
    }
}

if (require.main === module) main();

module.exports = { loadDisassembly, buildGraph };
