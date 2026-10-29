#!/usr/bin/env node
// The in-app rebrand's transform (cone-buzz-infra Slice 36, ADR-237).
//
// Rewrites the capitalised word "Buzz" inside *string text only* — TypeScript
// and TSX string literals, template literal text and JSX text; Rust string
// literals; whole Markdown files the binary embeds — and scans the same text
// for anything branded that remains. Identifiers, comments, URLs and every
// lower-case `buzz` are never touched. Driven by cone/rebrand.sh; the
// manifests live beside this file:
//
//   word              the replacement word, one line
//   strings.tsv       path<TAB>count — the exact number of word hits in the
//                     file's string text after blocks and lines are applied
//   lines.tsv         path<TAB>old<TAB>new[<TAB>count] — old/new as JSON
//                     strings; old must occur exactly `count` (default 1) times
//   blocks.tsv        path<TAB>name — blocks/<name>.old replaced by
//                     blocks/<name>.new, the old text occurring exactly once
//   replacements.tsv  path<TAB>sha256 — files/<path> replaces the upstream file
//                     whose content hashes so ("-": a new file, must not exist)
//   exceptions.tsv    path<TAB>text<TAB>reason — a scan hit on a line that
//                     contains `text` in that file is not a finding
//
// Commands (cwd: the repository root):
//   node cone/rebrand/transform.mjs measure          print path<TAB>count for every scoped file with hits
//   node cone/rebrand/transform.mjs apply            blocks, lines, word rule (counts verified); exit 1 on any miss
//   node cone/rebrand/transform.mjs scan             after apply: every branded residue, exit 1 if any
//   node cone/rebrand/transform.mjs paths            every path apply may write (for restore)
//   node cone/rebrand/transform.mjs includes         the include_str! sources in scope
//
// The replacements (whole files) are the shell driver's job: it hashes and
// copies, this script never does.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const ROOT = process.cwd();
const HERE = path.join(ROOT, "cone", "rebrand");
const WORD = "Buzz";
const require = createRequire(path.join(ROOT, "desktop", "package.json"));
const ts = require("typescript");

// ---------------------------------------------------------------- scope ----

// The frontend, the app crate, and every workspace crate the app crate links
// (`package = "buzz-…", path = "…"` in desktop/src-tauri/Cargo.toml): their
// string literals end up in buzz-desktop too (merge 1 found "Buzz: signed in"
// from buzz-agent and "newer than this Buzz build" from buzz-voice there).
function linkedCrateRoots() {
  const toml = fs.readFileSync(path.join(ROOT, "desktop/src-tauri/Cargo.toml"), "utf8");
  const roots = [];
  for (const m of toml.matchAll(/package\s*=\s*"(buzz-[a-z-]+)"\s*,\s*path\s*=\s*"([^"]+)"/g)) {
    roots.push(path.relative(ROOT, path.resolve(ROOT, "desktop/src-tauri", m[2], "src")));
  }
  return roots.sort();
}
const CRATE_ROOTS = linkedCrateRoots();
const SRC_ROOTS = ["desktop/src", "desktop/src-tauri/src", ...CRATE_ROOTS];

function isScopedSource(rel) {
  if (CRATE_ROOTS.some((r) => rel.startsWith(r + "/"))) {
    if (!rel.endsWith(".rs")) return false;
    if (/(_tests|\/tests)\.rs$/.test(rel)) return false;
    if (rel.includes("/tests/") || rel.includes("/testdata/")) return false;
    return true;
  }
  if (rel.startsWith("desktop/src/")) {
    if (!/\.(ts|tsx)$/.test(rel)) return false;
    if (/\.(test|test-support|stories|jsdom-test)\.[^/]+$/.test(rel)) return false;
    if (rel.startsWith("desktop/src/testing/")) return false;
    if (rel.includes("/__tests__/")) return false;
    return true;
  }
  if (rel.startsWith("desktop/src-tauri/src/")) {
    if (!rel.endsWith(".rs")) return false;
    if (/(_tests|\/tests)\.rs$/.test(rel)) return false;
    if (rel.includes("/tests/") || rel.includes("/testdata/")) return false;
    return true;
  }
  return false;
}

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === "target") continue;
      walk(p, out);
    } else if (entry.isFile()) out.push(path.relative(ROOT, p));
  }
  return out;
}

function scopedSources() {
  const all = [];
  for (const r of SRC_ROOTS) walk(path.join(ROOT, r), all);
  return all.filter(isScopedSource).sort();
}

// Markdown (or any text) a scoped Rust file embeds with include_str!: part of
// the scope as whole text.
function includeSources(sources) {
  const found = new Set();
  for (const rel of sources) {
    if (!rel.endsWith(".rs")) continue;
    const text = fs.readFileSync(path.join(ROOT, rel), "utf8");
    for (const m of text.matchAll(/include_str!\(\s*"([^"]+)"\s*\)/g)) {
      const target = path.relative(ROOT, path.resolve(ROOT, path.dirname(rel), m[1]));
      found.add(target);
    }
  }
  return [...found].sort();
}

function scopeAll() {
  const sources = scopedSources();
  const includes = includeSources(sources);
  const svgs = walk(path.join(ROOT, "desktop/public"), []).filter((p) => p.endsWith(".svg")).sort();
  const all = [...new Set([...sources, ...includes, ...svgs])]; // a .rs both scoped and embedded counts once
  return { sources, includes, svgs, all };
}

// --------------------------------------------------------- string text ----

// Returns [start, end) ranges of string text in a file's content, by kind.
function textRanges(rel, content) {
  if (rel.endsWith(".ts") || rel.endsWith(".tsx")) return tsRanges(rel, content);
  if (rel.endsWith(".rs")) return rustRanges(content);
  return [[0, content.length]]; // markdown, svg: whole text
}

function tsRanges(rel, content) {
  const kind = rel.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const sf = ts.createSourceFile(rel, content, ts.ScriptTarget.Latest, true, kind);
  const ranges = [];
  const visit = (node) => {
    switch (node.kind) {
      case ts.SyntaxKind.StringLiteral:
      case ts.SyntaxKind.NoSubstitutionTemplateLiteral:
      case ts.SyntaxKind.TemplateHead:
      case ts.SyntaxKind.TemplateMiddle:
      case ts.SyntaxKind.TemplateTail:
      case ts.SyntaxKind.JsxText:
        ranges.push([node.getStart(sf), node.getEnd()]);
        return;
      default:
        ts.forEachChild(node, visit);
    }
  };
  visit(sf);
  return ranges;
}

// A small Rust lexer: skips // and /* */ comments (nested), char literals,
// lifetimes and every `#[cfg(test)]` item (the brace-delimited item that
// follows the attribute: a test module or function inside a production file);
// yields "..." (with escapes), r#"..."#, b"...", br"..." literals.
function rustRanges(src) {
  const ranges = [];
  let i = 0;
  const n = src.length;
  let testPending = false; // saw #[cfg(test)], the next `{` opens the item
  let testDepth = 0; // > 0 while inside that item
  const push = (r) => { if (testDepth === 0) ranges.push(r); };
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "#" && src.startsWith("#[cfg(test)]", i)) { testPending = true; i += 12; continue; }
    if (c === ";" && testPending) { testPending = false; i++; continue; } // `#[cfg(test)] mod tests;` — no item body here
    if (c === "{" && (testPending || testDepth > 0)) { testPending = false; testDepth++; i++; continue; }
    if (c === "}" && testDepth > 0) { testDepth--; i++; continue; }
    if (c === "/" && d === "/") {
      while (i < n && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && d === "*") {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] === "/" && src[i + 1] === "*") { depth++; i += 2; continue; }
        if (src[i] === "*" && src[i + 1] === "/") { depth--; i += 2; continue; }
        i++;
      }
      continue;
    }
    if (c === "'") {
      // char literal: 'x', '\n', '\u{..}', '"' — else a lifetime 'a
      if (d === "\\") {
        let j = i + 2;
        while (j < n && src[j] !== "'") j++;
        i = j + 1;
        continue;
      }
      if (src[i + 2] === "'") { i += 3; continue; }
      i++;
      continue;
    }
    // raw strings: r"…", r#"…"#, br"…", br#"…"#
    if ((c === "r" || (c === "b" && d === "r")) && /[^A-Za-z0-9_]/.test(src[i - 1] ?? " ")) {
      let j = c === "b" ? i + 2 : i + 1;
      let hashes = 0;
      while (src[j] === "#") { hashes++; j++; }
      if (src[j] === '"') {
        const close = '"' + "#".repeat(hashes);
        const end = src.indexOf(close, j + 1);
        if (end < 0) throw new Error("unterminated raw string");
        push([j + 1, end]);
        i = end + close.length;
        continue;
      }
    }
    if (c === '"') {
      let j = i + 1;
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === '"') break;
        j++;
      }
      push([i + 1, j]);
      i = j + 1;
      continue;
    }
    i++;
  }
  return ranges;
}

const WORD_RE = new RegExp(`\\b${WORD}\\b`, "g");

function countInRanges(content, ranges, re) {
  let count = 0;
  for (const [s, e] of ranges) {
    const slice = content.slice(s, e);
    count += (slice.match(re) ?? []).length;
  }
  return count;
}

function replaceInRanges(content, ranges, re, to) {
  let out = "";
  let last = 0;
  for (const [s, e] of ranges) {
    out += content.slice(last, s) + content.slice(s, e).replace(re, to);
    last = e;
  }
  return out + content.slice(last);
}

// ------------------------------------------------------------- manifests ----

function readTsv(name, columns) {
  const file = path.join(HERE, name);
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l && !l.startsWith("#"))
    .map((l, i) => {
      const cells = l.split("\t");
      if (cells.length < columns) throw new Error(`${name}:${i + 1}: expected ${columns} columns`);
      return cells;
    });
}

function readWord() {
  const w = fs.readFileSync(path.join(HERE, "word"), "utf8").trim();
  if (!/^[A-Z][A-Za-z]+$/.test(w)) throw new Error(`word: '${w}' is not a capitalised word`);
  return w;
}

// --------------------------------------------------------------- commands --

function measure() {
  const scope = scopeAll();
  const rows = [];
  for (const rel of scope.all) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const c = countInRanges(content, textRanges(rel, content), WORD_RE);
    if (c > 0) rows.push(`${rel}\t${c}`);
  }
  process.stdout.write(rows.join("\n") + (rows.length ? "\n" : ""));
}

function apply() { applyAll(false); }
function applyPrefix() { applyAll(true); } // blocks and lines only: what `measure` counts after

function applyAll(prefixOnly) {
  const word = readWord();
  const failures = [];
  // 1. blocks
  for (const [rel, name] of readTsv("blocks.tsv", 2)) {
    const file = path.join(ROOT, rel);
    if (!fs.existsSync(file)) { failures.push(`${rel}: missing (blocks.tsv ${name})`); continue; }
    const old = fs.readFileSync(path.join(HERE, "blocks", `${name}.old`), "utf8");
    const neu = fs.readFileSync(path.join(HERE, "blocks", `${name}.new`), "utf8");
    if (rel.endsWith(".rs") && neu.includes('"#')) { failures.push(`${rel}: block ${name} contains '"#', which ends a Rust r#"…"# raw string (use rgb() colours, not hex)`); continue; }
    const content = fs.readFileSync(file, "utf8");
    const hits = content.split(old).length - 1;
    if (hits !== 1) { failures.push(`${rel}: block ${name} found ${hits} times, expected 1`); continue; }
    fs.writeFileSync(file, content.replace(old, () => neu));
  }
  // 2. lines
  for (const cells of readTsv("lines.tsv", 3)) {
    const [rel, oldJson, newJson, countStr] = cells;
    const want = countStr ? Number(countStr) : 1;
    const old = JSON.parse(oldJson);
    const neu = JSON.parse(newJson);
    const file = path.join(ROOT, rel);
    if (rel.endsWith(".rs") && neu.includes('"#')) { failures.push(`${rel}: line replacement contains '"#', which ends a Rust r#"…"# raw string`); continue; }
    if (!fs.existsSync(file)) { failures.push(`${rel}: missing (lines.tsv)`); continue; }
    const content = fs.readFileSync(file, "utf8");
    const hits = content.split(old).length - 1;
    if (hits !== want) { failures.push(`${rel}: line ${oldJson.slice(0, 60)} found ${hits} times, expected ${want}`); continue; }
    fs.writeFileSync(file, content.split(old).join(neu));
  }
  if (prefixOnly) {
    if (failures.length) { process.stderr.write(failures.map((f) => `rebrand apply: ${f}`).join("\n") + "\n"); process.exit(1); }
    return;
  }
  // 3. the word rule, by exact count
  const expected = new Map(readTsv("strings.tsv", 2).map(([rel, c]) => [rel, Number(c)]));
  const scope = scopeAll();
  for (const rel of scope.all) {
    const file = path.join(ROOT, rel);
    const content = fs.readFileSync(file, "utf8");
    const ranges = textRanges(rel, content);
    const have = countInRanges(content, ranges, WORD_RE);
    const want = expected.get(rel) ?? 0;
    if (have !== want) { failures.push(`${rel}: ${have} '${WORD}' in string text, strings.tsv says ${want}`); continue; }
    if (have > 0) fs.writeFileSync(file, replaceInRanges(content, ranges, WORD_RE, word));
  }
  for (const rel of expected.keys()) {
    if (!scope.all.includes(rel)) failures.push(`${rel}: listed in strings.tsv but not in scope (moved, deleted or excluded)`);
  }
  if (failures.length) {
    process.stderr.write(failures.map((f) => `rebrand apply: ${f}`).join("\n") + "\n");
    process.exit(1);
  }
  process.stdout.write(`rebrand apply: ok (${readTsv("blocks.tsv", 2).length} blocks, ${readTsv("lines.tsv", 3).length} lines, ${expected.size} files by the word rule)\n`);
}

const RESIDUE = [
  [new RegExp(`\\b${WORD}\\b`, "g"), WORD],
  [/\bBlock\b/g, "Block"],
  [/honeycomb/gi, "honeycomb"],
  [/honey drip/gi, "honey drip"],
  [/\bbees?\b/gi, "bee"],
  [/🐝/g, "🐝"],
];

function scan() {
  const exceptions = readTsv("exceptions.tsv", 3);
  const scope = scopeAll();
  const findings = [];
  for (const rel of scope.all) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const ranges = textRanges(rel, content);
    for (const [s, e] of ranges) {
      const slice = content.slice(s, e);
      for (const [re, label] of RESIDUE) {
        re.lastIndex = 0;
        if (!re.test(slice)) continue;
        const lineNo = content.slice(0, s).split("\n").length;
        const lineText = content.split("\n")[lineNo - 1] ?? "";
        const excused = exceptions.some(([p, text]) => p === rel && (lineText.includes(text) || slice.includes(text)));
        if (!excused) findings.push(`${rel}:${lineNo}: ${label}: ${lineText.trim().slice(0, 120)}`);
      }
    }
  }
  const unique = [...new Set(findings)];
  if (unique.length) {
    process.stderr.write(unique.map((f) => `rebrand scan: ${f}`).join("\n") + `\nrebrand scan: ${unique.length} residue(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`rebrand scan: ok (${scope.all.length} files, ${exceptions.length} exceptions)\n`);
}

function paths() {
  const set = new Set();
  for (const [rel] of readTsv("blocks.tsv", 2)) set.add(rel);
  for (const [rel] of readTsv("lines.tsv", 3)) set.add(rel);
  for (const [rel] of readTsv("strings.tsv", 2)) set.add(rel);
  process.stdout.write([...set].sort().join("\n") + "\n");
}

function includes() {
  process.stdout.write(includeSources(scopedSources()).join("\n") + "\n");
}

const cmd = process.argv[2];
function roots() { process.stdout.write(SRC_ROOTS.join("\n") + "\n"); } // every directory apply may write under
const commands = { measure, apply, "apply-prefix": applyPrefix, scan, paths, includes, roots };
if (!commands[cmd]) {
  process.stderr.write(`usage: transform.mjs ${Object.keys(commands).join("|")}\n`);
  process.exit(2);
}
commands[cmd]();
