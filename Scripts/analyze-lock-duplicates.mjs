import fs from 'fs';

const file = process.argv[2] || 'package-lock.main.json';
const text = fs.readFileSync(file, 'utf8');
const lines = text.split('\n');

function extractBlockFrom(linesArr, startLine) {
  let depth = 0;
  let started = false;
  for (let i = startLine; i < linesArr.length; i++) {
    for (const ch of linesArr[i]) {
      if (ch === '{') {
        depth++;
        started = true;
      } else if (ch === '}') {
        depth--;
        if (started && depth === 0) {
          return { start: startLine, end: i, lines: linesArr.slice(startLine, i + 1) };
        }
      }
    }
  }
  return null;
}

function parseBlockObject(blockLines) {
  try {
    return JSON.parse(`{${blockLines.slice(1, -1).join('\n')}}`);
  } catch {
    return null;
  }
}

function compareVersions(a, b) {
  const pa = String(a || '0').split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b || '0').split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const da = pa[i] || 0;
    const db = pb[i] || 0;
    if (da !== db) return da > db ? 1 : -1;
  }
  return 0;
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function keysOnlyInExtra(base, extra, path = '') {
  const out = [];
  if (!isPlainObject(base) || !isPlainObject(extra)) return out;
  for (const [key, extraVal] of Object.entries(extra)) {
    const p = path ? `${path}.${key}` : key;
    if (!(key in base)) {
      out.push({ path: p, value: extraVal });
    } else if (isPlainObject(base[key]) && isPlainObject(extraVal)) {
      out.push(...keysOnlyInExtra(base[key], extraVal, p));
    }
  }
  return out;
}

// --- duplicate keys ---
const keyPattern = /^    "(node_modules\/[^"]+)": \{/;
const allKeys = [];
for (let i = 0; i < lines.length; i++) {
  const m = lines[i].match(keyPattern);
  if (m) allKeys.push({ line: i + 1, key: m[1] });
}
const byKey = {};
for (const k of allKeys) {
  if (!byKey[k.key]) byKey[k.key] = [];
  byKey[k.key].push(k.line);
}
const dupKeys = Object.entries(byKey).filter(([, v]) => v.length > 1);

// --- inline splices (multiple version in one block) ---
const versionInBlock = [];
let currentPkg = null;
let versionCount = 0;
let versionLines = [];
for (let i = 0; i < lines.length; i++) {
  const pkgMatch = lines[i].match(/^    "(node_modules\/[^"]+)": \{/);
  if (pkgMatch) {
    if (currentPkg && versionCount > 1) {
      versionInBlock.push({ pkg: currentPkg, lines: versionLines });
    }
    currentPkg = pkgMatch[1];
    versionCount = 0;
    versionLines = [];
  }
  if (/^\s+"version":/.test(lines[i]) && currentPkg) {
    versionCount++;
    versionLines.push(i + 1);
  }
}
if (currentPkg && versionCount > 1) {
  versionInBlock.push({ pkg: currentPkg, lines: versionLines });
}

// --- merge preview for parseable duplicate pairs ---
const duplicateMergePlan = [];
for (const [key, lineNums] of dupKeys) {
  const copies = [];
  for (const ln of lineNums) {
    const block = extractBlockFrom(lines, ln - 1);
    const obj = block ? parseBlockObject(block.lines) : null;
    copies.push({ line: ln, obj, parseable: !!obj });
  }
  const parseable = copies.filter((c) => c.obj);
  const plan = {
    key,
    occurrences: lineNums,
    parseable: parseable.length,
    copies: copies.map((c) => ({
      line: c.line,
      version: c.obj?.version ?? '(non parseable)',
      parseable: c.parseable,
    })),
    action: null,
    uniqueFromOlder: [],
  };

  if (parseable.length >= 2) {
    parseable.sort((a, b) => compareVersions(b.obj.version, a.obj.version));
    const base = parseable[0].obj;
    const olderVersions = [];
    const allUnique = [];
    for (let j = 1; j < parseable.length; j++) {
      olderVersions.push(parseable[j].obj.version);
      allUnique.push(...keysOnlyInExtra(base, parseable[j].obj));
    }
    plan.action = `Garder v${base.version} (l.${parseable[0].line}), fusionner contenu unique des v${olderVersions.join(', v')}`;
    plan.uniqueFromOlder = allUnique.map((u) => u.path);
    plan.keptLine = parseable[0].line;
    plan.removedLines = parseable.slice(1).map((p) => p.line);
  } else if (parseable.length === 1) {
    plan.action = `Garder la copie parseable v${parseable[0].obj.version}, l'autre copie nécessite extraction manuelle du splice`;
    plan.keptLine = parseable[0].line;
    plan.removedLines = copies.filter((c) => !c.parseable).map((c) => c.line);
  } else {
    plan.action = 'Aucune copie parseable — extraction manuelle du splice requise';
  }
  duplicateMergePlan.push(plan);
}

// --- other structural anomalies ---
const anomalies = [];
for (let i = 0; i < lines.length - 1; i++) {
  if (/^\s+\],\s*$/.test(lines[i]) && /^\s+\],?\s*$/.test(lines[i + 1])) {
    anomalies.push({ type: 'double-bracket', line: i + 1, detail: '], suivi de ],' });
  }
  if (/^\s+"integrity":.*,\s*$/.test(lines[i]) && /^\s+\},?\s*$/.test(lines[i + 1]) && /^\s+"node_modules\//.test(lines[i + 2] || '')) {
    anomalies.push({ type: 'truncated-block', line: i + 1, detail: 'bloc tronqué avant package suivant' });
  }
}

const report = {
  summary: {
    duplicatePackageKeys: dupKeys.length,
    inlineSplices: versionInBlock.length,
    structuralAnomalies: anomalies.length,
  },
  duplicateMergePlan,
  inlineSplices: versionInBlock,
  structuralAnomalies: anomalies,
};

fs.writeFileSync('package-lock.analysis.json', JSON.stringify(report, null, 2) + '\n');

console.log('# Analyse "garde les 2" sur main\n');
console.log(`## Résumé`);
console.log(`- ${dupKeys.length} packages en double`);
console.log(`- ${versionInBlock.length} splices internes (2+ "version" dans un bloc)`);
console.log(`- ${anomalies.length} autres anomalies structurelles\n`);

console.log(`## Plan de fusion (version récente + contenu unique de l'ancienne)\n`);
for (const p of duplicateMergePlan) {
  console.log(`### ${p.key}`);
  console.log(`Occurrences: lignes ${p.occurrences.join(', ')}`);
  for (const c of p.copies) {
    console.log(`  - L${c.line}: v${c.version}${c.parseable ? '' : ' ⚠ splice'}`);
  }
  console.log(`Action: ${p.action}`);
  if (p.uniqueFromOlder?.length) {
    console.log(`  → à récupérer de l'ancienne: ${p.uniqueFromOlder.join(', ')}`);
  } else if (p.parseable >= 2) {
    console.log(`  → rien d'unique dans l'ancienne (doublon pur)`);
  }
  console.log('');
}

console.log(`## Splices internes\n`);
for (const s of versionInBlock) {
  console.log(`- ${s.pkg}: "version" aux lignes ${s.lines.join(', ')}`);
}

console.log(`\nRapport complet: package-lock.analysis.json`);
