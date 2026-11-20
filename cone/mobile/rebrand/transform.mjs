#!/usr/bin/env node
// The Cone phone app's rebrand (cone-buzz-infra Slice 43; the mechanism of
// Slice 36 / ADR-237 and Slice 51 / ADR-364, ported from the Desktop overlays
// to upstream's Flutter app under mobile/).
//
// Rewrites the capitalised word "Buzz" inside *string text only* — Dart string
// literals (interpolations excluded), Swift string literals (interpolations
// excluded), plist <string> values, and storyboards / strings files whole —
// and scans the same text for anything branded that remains. Identifiers,
// comments, URL schemes and every lower-case `buzz` are never touched. Driven
// by cone/mobile/rebrand.sh; the manifests live beside this file:
//
//   word              the replacement word, one line
//   scope.tsv         kind<TAB>path<TAB>what — `text` roots the word rule reads,
//                     `images` roots the picture inventory reads
//   strings.tsv       path<TAB>count — the exact number of word hits in the
//                     file's string text after lines.tsv, outside keep.tsv
//   lines.tsv         path<TAB>old<TAB>new[<TAB>count] — old/new as JSON
//                     strings; old must occur exactly `count` (default 1) times
//   keep.tsv          path<TAB>text<TAB>count<TAB>reason — a string (JSON) whose
//                     `Buzz` stays: a wire or protocol name, a log line. It
//                     occurs exactly `count` times in the file's string text and
//                     the word rule leaves every hit inside it alone
//   replacements.tsv  path<TAB>sha256 — files/<path> replaces the upstream file
//                     whose content hashes so (the shell driver copies them)
//   kept-images.tsv   path<TAB>sha256<TAB>reason — an upstream picture that
//                     stays, pinned to its content
//   exceptions.tsv    path<TAB>text<TAB>reason — a scan hit on a line that
//                     contains `text` in that file is not a finding
//   identity.tsv      name<TAB>value — the iOS identity every configuration
//                     must resolve to after apply
//
// Commands (cwd: the repository root):
//   count          print path<TAB>count for every scoped file with hits (strings.tsv rows)
//   hits           print path:line<TAB>kind<TAB>the string text around each hit (for review)
//   apply          lines, the word rule (counts verified); exit 1 on any miss
//   apply-prefix   lines only (what `count` counts after)
//   scan           after apply: every branded residue (Buzz, BUZZ, Block, bee), exit 1 if any
//   measure        after apply: the user-visible "Buzz" left that no keep row covers, by kind; exit 1 unless 0
//   assert         after apply: identity, plists, pictures — each failure names its assertion
//   paths          every text path apply may write (for restore)
//   roots          every directory apply may write under
//   scope          every text file in scope, one per line

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const ROOT = process.cwd();
const HERE = path.join(ROOT, "cone", "mobile", "rebrand");
const WORD = "Buzz";

// ------------------------------------------------------------- manifests ----

function readTsv(name, columns) {
  const file = path.join(HERE, name);
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .map((l, i) => [l, i + 1])
    .filter(([l]) => l && !l.startsWith("#"))
    .map(([l, n]) => {
      const cells = l.split("\t");
      if (cells.length < columns) throw new Error(`${name}:${n}: expected ${columns} columns, got ${cells.length}`);
      return cells;
    });
}

function readWord() {
  const w = fs.readFileSync(path.join(HERE, "word"), "utf8").trim();
  if (!/^[A-Z][A-Za-z]+$/.test(w)) throw new Error(`word: '${w}' is not a capitalised word`);
  return w;
}

function readKeeps() {
  const byPath = new Map();
  for (const [rel, textJson, count] of readTsv("keep.tsv", 4)) {
    const list = byPath.get(rel) ?? [];
    list.push({ text: JSON.parse(textJson), count: Number(count) });
    byPath.set(rel, list);
  }
  return byPath;
}

// ---------------------------------------------------------------- scope ----

const TEXT_EXT = /\.(dart|swift|plist|storyboard|xib|strings|stringsdict|xcstrings|intentdefinition|pbxproj|xcscheme)$/;
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|pdf|heic)$/i;

function walk(dir, out) {
  const abs = path.join(ROOT, dir);
  if (!fs.existsSync(abs)) return out;
  if (fs.statSync(abs).isFile()) { out.push(dir); return out; }
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    const rel = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (["build", ".dart_tool", "Pods", ".symlinks", "ephemeral"].includes(entry.name)) continue;
      walk(rel, out);
    } else if (entry.isFile()) out.push(rel);
  }
  return out;
}

function isTestOrGenerated(rel) {
  if (/(^|\/)(test|tests|Tests|testing|test_driver|integration_test|fixtures|Fixtures)\//.test(rel)) return true;
  if (/(_test|Tests?)\.(dart|swift)$/.test(rel)) return true;
  if (/\.(g|freezed|mocks)\.dart$/.test(rel)) return true;
  if (/GeneratedPluginRegistrant\./.test(rel)) return true;
  return false;
}

function scopeRows(kind) { return readTsv("scope.tsv", 3).filter(([k]) => k === kind).map(([, p]) => p); }

let SCOPE = null;
function scopeAll() {
  if (SCOPE) return SCOPE;
  const all = new Set();
  for (const root of scopeRows("text")) {
    for (const rel of walk(root, [])) if (TEXT_EXT.test(rel) && !isTestOrGenerated(rel)) all.add(rel);
  }
  SCOPE = [...all].sort();
  return SCOPE;
}

function imageInventory() {
  const all = new Set();
  for (const root of scopeRows("images")) {
    for (const rel of walk(root, [])) if (IMAGE_EXT.test(rel)) all.add(rel);
  }
  return [...all].sort();
}

function kindOf(rel) {
  if (rel.endsWith(".dart")) return "dart";
  if (rel.endsWith(".swift")) return "swift";
  if (rel.endsWith(".plist")) return "plist";
  if (/\.(pbxproj|xcscheme)$/.test(rel)) return "project";
  return "text";
}

// --------------------------------------------------------- string text ----

// [start, end) ranges of string text in a file's content.
function textRanges(rel, content) {
  switch (kindOf(rel)) {
    case "dart": return dartRanges(content);
    case "swift": return swiftRanges(content);
    case "plist": return plistRanges(content);
    default: return [[0, content.length]]; // storyboards, strings files, the Xcode project and scheme: whole text
  }
}

const IDENT = /[A-Za-z0-9_$]/;

// A Dart lexer: skips // and nested /* */ comments; yields the literal text of
// '…', "…", '''…''', """…""" and their raw r-forms, split around every
// interpolation ($name, ${…}) so code inside one is never string text. A piece
// includes the delimiter at its end of the literal, so a keep row can name a
// whole literal with its quotes.
function dartRanges(src) {
  const ranges = [];
  const n = src.length;
  const code = (start, stopAtBrace) => {
    let i = start;
    let depth = 0;
    while (i < n) {
      const c = src[i];
      const d = src[i + 1];
      if (c === "/" && d === "/") { while (i < n && src[i] !== "\n") i++; continue; }
      if (c === "/" && d === "*") {
        let depth2 = 1;
        i += 2;
        while (i < n && depth2 > 0) {
          if (src[i] === "/" && src[i + 1] === "*") { depth2++; i += 2; continue; }
          if (src[i] === "*" && src[i + 1] === "/") { depth2--; i += 2; continue; }
          i++;
        }
        continue;
      }
      if (c === "r" && (d === "'" || d === '"') && !IDENT.test(src[i - 1] ?? " ")) { i = literal(i + 1, true, i); continue; }
      if (c === "'" || c === '"') { i = literal(i, false, i); continue; }
      if (c === "{") { depth++; i++; continue; }
      if (c === "}") {
        if (stopAtBrace && depth === 0) return i + 1;
        depth--; i++; continue;
      }
      i++;
    }
    return i;
  };
  const literal = (q, raw, start) => {
    const quote = src[q];
    const triple = src[q + 1] === quote && src[q + 2] === quote;
    const delim = triple ? quote.repeat(3) : quote;
    let i = q + delim.length;
    let piece = start;
    while (i < n) {
      if (!raw && src[i] === "\\") { i += 2; continue; }
      if (src.startsWith(delim, i)) { ranges.push([piece, i + delim.length]); return i + delim.length; }
      if (!triple && src[i] === "\n") { ranges.push([piece, i]); return i; } // unterminated: stop at the line
      if (!raw && src[i] === "$") {
        if (src[i + 1] === "{") { ranges.push([piece, i]); i = code(i + 2, true); piece = i; continue; }
        if (/[A-Za-z_]/.test(src[i + 1] ?? "")) {
          ranges.push([piece, i]);
          i++;
          while (i < n && /[A-Za-z0-9_]/.test(src[i])) i++;
          piece = i;
          continue;
        }
      }
      i++;
    }
    ranges.push([piece, n]);
    return n;
  };
  code(0, false);
  return ranges.filter(([s, e]) => e > s);
}

// A Swift lexer: skips // and nested /* */ comments; yields the literal text of
// "…", """…""" and their raw #"…"# forms, split around every interpolation
// (\(…), \#(…) in a raw literal). Pieces include the literal's own quotes.
function swiftRanges(src) {
  const ranges = [];
  const n = src.length;
  const code = (start, stopAtParen) => {
    let i = start;
    let depth = 0;
    while (i < n) {
      const c = src[i];
      const d = src[i + 1];
      if (c === "/" && d === "/") { while (i < n && src[i] !== "\n") i++; continue; }
      if (c === "/" && d === "*") {
        let depth2 = 1;
        i += 2;
        while (i < n && depth2 > 0) {
          if (src[i] === "/" && src[i + 1] === "*") { depth2++; i += 2; continue; }
          if (src[i] === "*" && src[i + 1] === "/") { depth2--; i += 2; continue; }
          i++;
        }
        continue;
      }
      if (c === "#" || c === '"') {
        let j = i;
        while (src[j] === "#") j++;
        if (src[j] === '"') { i = literal(i, j - i); continue; }
        i = j > i ? j : i + 1;
        continue;
      }
      if (c === "(") { depth++; i++; continue; }
      if (c === ")") {
        if (stopAtParen && depth === 0) return i + 1;
        depth--; i++; continue;
      }
      i++;
    }
    return i;
  };
  const literal = (start, hashes) => {
    const h = "#".repeat(hashes);
    const q = start + hashes;
    const triple = src.startsWith('"""', q);
    const close = (triple ? '"""' : '"') + h;
    const escape = "\\" + h;
    let i = q + (triple ? 3 : 1);
    let piece = start;
    while (i < n) {
      if (src.startsWith(escape + "(", i)) { ranges.push([piece, i]); i = code(i + escape.length + 1, true); piece = i; continue; }
      if (src.startsWith(escape, i)) { i += escape.length + 1; continue; }
      if (src.startsWith(close, i)) { ranges.push([piece, i + close.length]); return i + close.length; }
      if (!triple && src[i] === "\n") { ranges.push([piece, i]); return i; }
      i++;
    }
    ranges.push([piece, n]);
    return n;
  };
  code(0, false);
  return ranges.filter(([s, e]) => e > s);
}

// An XML plist: the text of every <string> value (keys are never shown).
function plistRanges(src) {
  const ranges = [];
  for (const m of src.matchAll(/<string>([\s\S]*?)<\/string>/g)) {
    const s = m.index + "<string>".length;
    ranges.push([s, s + m[1].length]);
  }
  return ranges;
}

const WORD_RE = () => new RegExp(`\\b${WORD}\\b`, "g");

// Every word hit in string text, as absolute offsets, minus the hits inside a
// keep.tsv text for this file. Returns { hits, keepCounts }.
function wordHits(content, ranges, keeps) {
  const hits = [];
  for (const [s, e] of ranges) {
    for (const m of content.slice(s, e).matchAll(WORD_RE())) hits.push(s + m.index);
  }
  const kept = new Set();
  const keepCounts = new Map();
  for (const text of keeps) {
    let count = 0;
    for (const [s, e] of ranges) {
      const slice = content.slice(s, e);
      let from = 0;
      for (;;) {
        const at = slice.indexOf(text, from);
        if (at < 0) break;
        count++;
        for (const m of text.matchAll(WORD_RE())) kept.add(s + at + m.index);
        from = at + text.length;
      }
    }
    keepCounts.set(text, count);
  }
  return { hits: hits.filter((h) => !kept.has(h)), keepCounts };
}

function read(rel) { return fs.readFileSync(path.join(ROOT, rel), "utf8"); }
function sha256(rel) { return crypto.createHash("sha256").update(fs.readFileSync(path.join(ROOT, rel))).digest("hex"); }
function fail(prefix, failures) {
  process.stderr.write(failures.map((f) => `${prefix}: ${f}`).join("\n") + "\n");
  process.exit(1);
}

// --------------------------------------------------------------- commands --

function count() {
  const keeps = readKeeps();
  const rows = [];
  for (const rel of scopeAll()) {
    const content = read(rel);
    const { hits } = wordHits(content, textRanges(rel, content), (keeps.get(rel) ?? []).map((k) => k.text));
    if (hits.length > 0) rows.push(`${rel}\t${hits.length}`);
  }
  process.stdout.write(rows.join("\n") + (rows.length ? "\n" : ""));
}

function hitList(keeps) {
  const out = [];
  for (const rel of scopeAll()) {
    const content = read(rel);
    const ranges = textRanges(rel, content);
    const { hits } = wordHits(content, ranges, (keeps.get(rel) ?? []).map((k) => k.text));
    for (const h of hits) {
      const [s, e] = ranges.find(([a, b]) => h >= a && h < b);
      const lineNo = content.slice(0, h).split("\n").length;
      const ctx = content.slice(Math.max(s, h - 60), Math.min(e, h + 60)).replace(/\s+/g, " ");
      out.push({ rel, lineNo, kind: kindOf(rel), ctx });
    }
  }
  return out;
}

function hitsCmd() {
  const out = hitList(readKeeps()).map((h) => `${h.rel}:${h.lineNo}\t${h.kind}\t${h.ctx}`);
  process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
}

function applyAll(prefixOnly) {
  const word = readWord();
  const failures = [];
  // 1. lines
  for (const [rel, oldJson, newJson, countStr] of readTsv("lines.tsv", 3)) {
    const want = countStr ? Number(countStr) : 1;
    const old = JSON.parse(oldJson);
    const neu = JSON.parse(newJson);
    if (!fs.existsSync(path.join(ROOT, rel))) { failures.push(`${rel}: missing (lines.tsv)`); continue; }
    const content = read(rel);
    const hits = content.split(old).length - 1;
    if (hits !== want) { failures.push(`${rel}: line ${oldJson.slice(0, 70)} found ${hits} times, expected ${want}`); continue; }
    fs.writeFileSync(path.join(ROOT, rel), content.split(old).join(neu));
  }
  if (prefixOnly) {
    if (failures.length) fail("rebrand apply", failures);
    return;
  }
  // 2. the word rule, by exact count, around the kept names
  const expected = new Map(readTsv("strings.tsv", 2).map(([rel, c]) => [rel, Number(c)]));
  const keeps = readKeeps();
  const scope = scopeAll();
  for (const rel of scope) {
    const content = read(rel);
    const fileKeeps = keeps.get(rel) ?? [];
    const { hits, keepCounts } = wordHits(content, textRanges(rel, content), fileKeeps.map((k) => k.text));
    for (const k of fileKeeps) {
      const have = keepCounts.get(k.text) ?? 0;
      if (have !== k.count) failures.push(`${rel}: keep ${JSON.stringify(k.text).slice(0, 70)} found ${have} times in string text, keep.tsv says ${k.count}`);
    }
    const want = expected.get(rel) ?? 0;
    if (hits.length !== want) { failures.push(`${rel}: ${hits.length} '${WORD}' in string text, strings.tsv says ${want}`); continue; }
    if (hits.length > 0) {
      let out = "";
      let last = 0;
      for (const h of hits) { out += content.slice(last, h) + word; last = h + WORD.length; }
      fs.writeFileSync(path.join(ROOT, rel), out + content.slice(last));
    }
  }
  for (const rel of expected.keys()) if (!scope.includes(rel)) failures.push(`${rel}: listed in strings.tsv but not in scope (moved, deleted or excluded)`);
  for (const rel of keeps.keys()) if (!scope.includes(rel)) failures.push(`${rel}: listed in keep.tsv but not in scope (moved, deleted or excluded)`);
  if (failures.length) fail("rebrand apply", failures);
  const keepRows = [...keeps.values()].reduce((a, l) => a + l.length, 0);
  const words = [...expected.values()].reduce((a, c) => a + c, 0);
  process.stdout.write(`rebrand apply: ok (${readTsv("lines.tsv", 3).length} lines, ${words} words in ${expected.size} files, ${keepRows} kept names)\n`);
}

const RESIDUE = [
  [() => new RegExp(`\\b${WORD}\\b`, "g"), WORD],
  [() => new RegExp(`\\b${WORD}[a-z]+`, "g"), `${WORD}…`], // a word made from it ("Buzzies"); CamelCase identifiers are not words
  [() => new RegExp(`\\b${WORD.toUpperCase()}\\b`, "g"), WORD.toUpperCase()], // BUZZ_* names are not words
  [() => /\bBlock\b/g, "Block"],
  [() => /\bbees?\b/gi, "bee"],
  [() => /\bhoney/gi, "honey"],
  [() => /🐝/g, "🐝"],
  [() => /\bxyz\.block\b/g, "xyz.block"], // Block's reverse-DNS identifiers
];

function scan() {
  const exceptions = readTsv("exceptions.tsv", 3);
  const keeps = readKeeps();
  const findings = [];
  for (const rel of scopeAll()) {
    const content = read(rel);
    const lines = content.split("\n");
    const fileKeeps = (keeps.get(rel) ?? []).map((k) => k.text);
    for (const [s, e] of textRanges(rel, content)) {
      let slice = content.slice(s, e);
      for (const k of fileKeeps) slice = slice.split(k).join(" ".repeat(k.length));
      for (const [mk, label] of RESIDUE) {
        for (const m of slice.matchAll(mk())) {
          const lineNo = content.slice(0, s + m.index).split("\n").length;
          const lineText = lines[lineNo - 1] ?? "";
          if (exceptions.some(([p, text]) => p === rel && lineText.includes(text))) continue;
          findings.push(`${rel}:${lineNo}: ${label}: ${lineText.trim().slice(0, 140)}`);
        }
      }
    }
  }
  const unique = [...new Set(findings)];
  if (unique.length) {
    process.stderr.write(unique.map((f) => `rebrand scan: ${f}`).join("\n") + `\nrebrand scan: ${unique.length} residue(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`rebrand scan: ok (${scopeAll().length} files, ${exceptions.length} exceptions)\n`);
}

// After apply: what a person could still read as "Buzz", outside keep.tsv.
function measure() {
  const keeps = readKeeps();
  const left = hitList(keeps);
  const by = { dart: 0, swift: 0, plist: 0, project: 0, text: 0 };
  for (const h of left) by[h.kind]++;
  let kept = 0;
  for (const list of keeps.values()) for (const k of list) kept += k.count;
  for (const h of left) process.stdout.write(`measure: ${h.rel}:${h.lineNo}\t${h.kind}\t${h.ctx}\n`);
  process.stdout.write(`measure: ${left.length} user-visible '${WORD}' left after apply (dart ${by.dart}, swift ${by.swift}, plist ${by.plist}, Xcode project ${by.project}, other ${by.text}); ${kept} kept by keep.tsv\n`);
  if (left.length) process.exit(1);
}

// ----------------------------------------------------------- assertions ----

// A minimal xcconfig reader: #include / #include? relative to the file,
// `NAME = value` (later wins), conditional `NAME[sdk=…]` settings ignored. A
// missing include is skipped: Generated.xcconfig and the Pods files exist only
// after `flutter build` / `pod install` and set no identity.
function xcconfig(rel, vars = new Map(), seen = new Set()) {
  const file = path.join(ROOT, rel);
  if (!fs.existsSync(file) || seen.has(rel)) return vars;
  seen.add(rel);
  for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
    const line = raw.replace(/\/\/.*$/, "").trim();
    const inc = line.match(/^#include\??\s+"([^"]+)"/);
    if (inc) { xcconfig(path.join(path.dirname(rel), inc[1]), vars, seen); continue; }
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (m) vars.set(m[1], m[2].trim());
  }
  return vars;
}

function expand(value, vars, depth = 0) {
  if (depth > 10) return value;
  return value.replace(/\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]/g, (_, name) => (vars.has(name) ? expand(vars.get(name), vars, depth + 1) : `$(${name})`));
}

function plistValue(rel, key) {
  const m = read(rel).match(new RegExp(`<key>${key}</key>\\s*<string>([\\s\\S]*?)</string>`));
  return m ? m[1] : null;
}

function plistArray(rel, key) {
  const m = read(rel).match(new RegExp(`<key>${key}</key>\\s*<array>([\\s\\S]*?)</array>`));
  return m ? [...m[1].matchAll(/<string>([\s\S]*?)<\/string>/g)].map((x) => x[1]) : null;
}

function png(rel) {
  const b = fs.readFileSync(path.join(ROOT, rel));
  if (b.length < 33 || b.toString("latin1", 1, 4) !== "PNG") return null;
  let alpha = [4, 6].includes(b[25]);
  for (let off = 8; off + 8 <= b.length;) {
    const len = b.readUInt32BE(off);
    const type = b.toString("latin1", off + 4, off + 8);
    if (type === "tRNS") alpha = true;
    if (type === "IEND") break;
    off += 12 + len;
  }
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20), colorType: b[25], alpha };
}

const IOS = "mobile/ios";
const APPICON = `${IOS}/Runner/Assets.xcassets/AppIcon.appiconset`;
const XCCONFIG = `${IOS}/Flutter/AppOverrides.xcconfig`;
const TEMPLATE = "cone/mobile/AppOverrides.xcconfig";

function assertAll() {
  const failures = [];
  const bad = (name, msg) => failures.push(`[${name}] ${msg}`);
  const word = readWord();

  // identity — the decided identity, in every configuration, through upstream's own include chain
  if (!fs.existsSync(path.join(ROOT, XCCONFIG))) bad("identity", `${XCCONFIG} is missing`);
  else if (read(XCCONFIG) !== read(TEMPLATE)) bad("identity", `${XCCONFIG} differs from ${TEMPLATE}`);
  const identity = readTsv("identity.tsv", 2);
  const resolved = {};
  for (const cfg of ["Debug", "Release"]) {
    const vars = xcconfig(`${IOS}/Flutter/${cfg}.xcconfig`);
    resolved[cfg] = vars;
    for (const [name, want] of identity) {
      const have = vars.has(name) ? expand(vars.get(name), vars) : "<unset>";
      if (have !== want) bad("identity", `${cfg}: ${name} resolves to '${have}', not '${want}' (${IOS}/Flutter/${cfg}.xcconfig and its includes)`);
    }
  }
  const pbx = read(`${IOS}/Runner.xcodeproj/project.pbxproj`);
  const bundleId = identity.find(([n]) => n === "BUNDLE_IDENTIFIER")?.[1];
  const team = identity.find(([n]) => n === "BUZZ_DEVELOPMENT_TEAM")?.[1];
  for (const m of pbx.matchAll(/PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;/g)) {
    const have = expand(m[1], resolved.Release);
    if (have !== bundleId && !have.startsWith(`${bundleId}.`)) bad("identity", `project.pbxproj: PRODUCT_BUNDLE_IDENTIFIER ${m[1]} resolves to '${have}', outside ${bundleId}`);
  }
  for (const m of pbx.matchAll(/DEVELOPMENT_TEAM = "?([^";]+)"?;/g)) {
    const have = expand(m[1], resolved.Release);
    if (have !== team) bad("identity", `project.pbxproj: DEVELOPMENT_TEAM ${m[1]} resolves to '${have}', not ${team}`);
  }

  // plists — every Info.plist in scope still parses; the names and prompts say the word; the schemes stay
  const plists = scopeAll().filter((r) => r.endsWith(".plist"));
  for (const rel of plists) {
    try { execFileSync("plutil", ["-lint", "-s", rel], { cwd: ROOT, stdio: "pipe" }); } catch (e) {
      if (e.code !== "ENOENT") bad("plists", `${rel}: plutil -lint fails after apply`);
    }
  }
  const runner = `${IOS}/Runner/Info.plist`;
  if (plistValue(runner, "CFBundleName") !== word) bad("plists", `${runner}: CFBundleName is '${plistValue(runner, "CFBundleName")}', not '${word}'`);
  if (plistValue(runner, "CFBundleDisplayName") !== "$(APP_DISPLAY_NAME)") bad("plists", `${runner}: CFBundleDisplayName is no longer $(APP_DISPLAY_NAME), so AppOverrides.xcconfig no longer names the app`);
  for (const key of ["NSFaceIDUsageDescription", "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"]) {
    const v = plistValue(runner, key);
    if (v === null || !new RegExp(`\\b${word}\\b`).test(v)) bad("plists", `${runner}: ${key} does not name ${word}: '${v}'`);
  }
  const schemes = plistArray(runner, "CFBundleURLSchemes") ?? [];
  if (!schemes.includes("buzz")) bad("plists", `${runner}: the URL scheme 'buzz' is gone (schemes: ${schemes.join(", ")}); buzz:// links must still open the app`);

  // pictures — every one in the inventory is Cone's (replaced) or kept with a reason; app icons opaque at their sizes
  const replaced = new Map(readTsv("replacements.tsv", 2).map(([p, s]) => [p, s]));
  const keptImages = new Map(readTsv("kept-images.tsv", 3).map(([p, s]) => [p, s]));
  for (const rel of imageInventory()) {
    if (replaced.has(rel)) {
      if (sha256(rel) !== sha256(`cone/mobile/rebrand/files/${rel}`)) bad("pictures", `${rel}: not Cone's copy after apply`);
    } else if (keptImages.has(rel)) {
      if (sha256(rel) !== keptImages.get(rel)) bad("pictures", `${rel}: kept as upstream's, but its content changed (sha256 ${sha256(rel)}): review it, then replace or re-pin it in kept-images.tsv`);
    } else bad("pictures", `${rel}: an upstream picture neither replaced (replacements.tsv) nor kept with a reason (kept-images.tsv)`);
  }
  for (const rel of keptImages.keys()) if (!imageInventory().includes(rel)) bad("pictures", `${rel}: in kept-images.tsv but not in the inventory`);
  const contents = JSON.parse(read(`${APPICON}/Contents.json`));
  for (const img of contents.images ?? []) {
    if (!img.filename) { bad("app icon", `${APPICON}/Contents.json: an entry without a file (${img.idiom} ${img.size}@${img.scale}${img.appearances ? ", " + JSON.stringify(img.appearances) : ""})`); continue; }
    const rel = `${APPICON}/${img.filename}`;
    const info = fs.existsSync(path.join(ROOT, rel)) ? png(rel) : null;
    if (!info) { bad("app icon", `${rel}: missing or not a PNG`); continue; }
    const px = Math.round(parseFloat(img.size) * parseFloat(img.scale));
    if (info.width !== px || info.height !== px) bad("app icon", `${rel}: ${info.width}x${info.height}, Contents.json wants ${px}x${px}`);
    if (info.alpha) bad("app icon", `${rel}: has an alpha channel (colour type ${info.colorType}); an iOS app icon must be opaque`);
    if (!replaced.has(rel)) bad("app icon", `${rel}: not replaced by Cone's`);
  }

  if (failures.length) fail("rebrand assert", failures);
  process.stdout.write(`rebrand assert: ok (identity: ${identity.length} settings in Debug and Release; plists: ${plists.length}; pictures: ${imageInventory().length}, ${replaced.size} replaced, ${keptImages.size} kept; app icon: ${(contents.images ?? []).length} sizes, opaque)\n`);
}

function paths() {
  const set = new Set();
  for (const [rel] of readTsv("lines.tsv", 3)) set.add(rel);
  for (const [rel] of readTsv("strings.tsv", 2)) set.add(rel);
  process.stdout.write([...set].sort().join("\n") + "\n");
}

function roots() {
  const set = new Set(["mobile"]);
  process.stdout.write([...set].join("\n") + "\n");
}

function scope() { process.stdout.write(scopeAll().join("\n") + "\n"); }

const commands = {
  count, hits: hitsCmd, apply: () => applyAll(false), "apply-prefix": () => applyAll(true),
  scan, measure, assert: assertAll, paths, roots, scope,
};
const cmd = process.argv[2];
if (!commands[cmd]) {
  process.stderr.write(`usage: transform.mjs ${Object.keys(commands).join("|")}\n`);
  process.exit(2);
}
commands[cmd]();
