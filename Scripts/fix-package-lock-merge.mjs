import fs from 'fs';

const input = process.argv[2] || 'package-lock.main.json';
const referencePath = process.argv[3] || 'package-lock.json';
const output = process.argv[4] || 'package-lock.main.fixed.json';
const reportPath = process.argv[5] || 'package-lock.fix-report.json';

let lines = fs.readFileSync(input, 'utf8').split('\n');
const refText = fs.readFileSync(referencePath, 'utf8');
const refRoot = JSON.parse(refText);
const refPackages = refRoot.packages || refRoot.dependencies || {};

const report = {
  structurePatches: [],
  relocations: [],
  merges: [],
  structureRepairs: [],
  discarded: [],
};

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

function deepMergePreferBase(base, extra) {
  const added = [];
  if (!isPlainObject(base) || !isPlainObject(extra)) return added;
  for (const [key, extraVal] of Object.entries(extra)) {
    if (!(key in base)) {
      base[key] = structuredClone(extraVal);
      added.push(key);
    } else if (isPlainObject(base[key]) && isPlainObject(extraVal)) {
      for (const sub of deepMergePreferBase(base[key], extraVal)) added.push(`${key}.${sub}`);
    }
  }
  return added;
}

function parseBlockLines(blockLines) {
  const attempts = [
    `{${blockLines.slice(1, -1).join('\n')}}`,
    `{${blockLines
      .slice(1, -1)
      .join('\n')
      .replace(/,(\s*})/g, '$1')}}`,
  ];
  for (const src of attempts) {
    try {
      return JSON.parse(src);
    } catch {
      /* try next */
    }
  }
  return null;
}

function extractBlockFrom(arr, startLine) {
  let depth = 0;
  let started = false;
  for (let i = startLine; i < arr.length; i++) {
    for (const ch of arr[i]) {
      if (ch === '{') {
        depth++;
        started = true;
      } else if (ch === '}') {
        depth--;
        if (started && depth === 0) {
          return { start: startLine, end: i, lines: arr.slice(startLine, i + 1) };
        }
      }
    }
  }
  return null;
}

function isPackageKeyLine(line) {
  const m = line.match(/^    "([^"]*)": \{$/);
  if (!m) return null;
  const key = m[1];
  if (key === '' || key.startsWith('node_modules/')) return key;
  return null;
}

function extractPackageBlock(arr, startLine) {
  for (let i = startLine + 1; i < arr.length; i++) {
    if (isPackageKeyLine(arr[i])) {
      let end = i - 1;
      while (end > startLine && !arr[end].trim()) end--;
      return { start: startLine, end, lines: arr.slice(startLine, end + 1) };
    }
    if (/^  \}\s*$/.test(arr[i])) {
      return { start: startLine, end: i - 1, lines: arr.slice(startLine, i) };
    }
  }
  return null;
}

function getRefPackage(key) {
  if (refPackages[key]) return structuredClone(refPackages[key]);
  return null;
}

function repairFromReference(key, blockLines) {
  const parsed = parseBlockLines(blockLines);
  const ref = getRefPackage(key);
  if (!ref) return parsed;

  if (parsed) {
    const added = deepMergePreferBase(parsed, ref);
    if (added.length) {
      report.structureRepairs.push({ key, type: 'fill-missing-fields', addedFields: added });
    }
    return parsed;
  }

  const version = blockLines.join('\n').match(/"version": "([^"]+)"/)?.[1];
  if (version && ref.version === version) {
    const repaired = structuredClone(ref);
    report.structureRepairs.push({
      key,
      type: 'restore-truncated-block',
      version,
      note: 'même version/integrity — champs structurels complétés',
    });
    return repaired;
  }
  return null;
}

function patchStructure(arr) {
  const apply = (name, fn) => {
    if (fn()) report.structurePatches.push(name);
  };

  apply('@esbuild/win32-x64 close before @emnapi', () => {
    const idx = arr.findIndex((l, i) => l.includes('"node": ">=18"') && arr[i + 1]?.includes('@emnapi/core'));
    if (idx === -1) return false;
    arr.splice(idx + 1, 0, '      }', '    },');
    return true;
  });

  apply('ansi-styles close before ansi-regex', () => {
    const idx = arr.findIndex(
      (l, i) => l.includes('ansi-styles?sponsor=1') && arr[i + 1]?.includes('node_modules/ansi-regex'),
    );
    if (idx === -1) return false;
    arr.splice(idx + 1, 0, '      }', '    },');
    return true;
  });

  apply('fraction.js 5.3.4 close before foreground-child', () => {
    const idx = arr.findIndex(
      (l, i) =>
        l.trim() === '"license": "MIT",' &&
        arr[i - 3]?.includes('fraction.js-5.3.4') &&
        arr[i + 1]?.includes('foreground-child'),
    );
    if (idx === -1) return false;
    arr.splice(idx + 1, 0, '    },');
    return true;
  });

  apply('hasown close before glob/brace-expansion', () => {
    const idx = arr.findIndex(
      (l, i) =>
        l.trim() === '"license": "MIT",' &&
        arr[i - 3]?.includes('hasown-2.0.4') &&
        arr[i + 1]?.includes('glob/node_modules/brace-expansion'),
    );
    if (idx === -1) return false;
    arr.splice(idx + 1, 0, '    },');
    return true;
  });

  apply('@rollup win32-ia32 double bracket', () => {
    const idx = arr.findIndex(
      (l, i) => arr[i]?.trim() === '"win32"' && arr[i + 2]?.trim() === '],' && arr[i + 3]?.includes('"engines"'),
    );
    if (idx === -1) return false;
    arr.splice(idx + 2, 1);
    return true;
  });

  apply('typescript-estree minimatch engines close', () => {
    const idx = arr.findIndex(
      (l, i) =>
        arr[i]?.includes('minimatch-10.2.5') &&
        arr[i + 8]?.includes('"peerDependenciesMeta"') &&
        !arr[i + 7]?.trim().endsWith('},'),
    );
    if (idx === -1) return false;
    const engIdx = arr.findIndex((l, j) => j > idx && j < idx + 15 && l.trim() === '"node": "18 || 20 || >=22"');
    if (engIdx === -1) return false;
    arr.splice(engIdx + 1, 0, '      },');
    return true;
  });
}

function resolveInlineSplice(arr, fullKey) {
  const start = arr.findIndex((l) => l === `    "${fullKey}": {`);
  if (start === -1) return;
  const block = extractPackageBlock(arr, start);
  if (!block) return;

  const versions = [];
  for (let j = 1; j < block.lines.length - 1; j++) {
    if (/^\s+"version":/.test(block.lines[j])) versions.push(j);
  }
  if (versions.length < 2) return;

  const spliceAt = versions[1];
  const newer = parseBlockLines([
    block.lines[0],
    ...block.lines.slice(1, spliceAt),
    '      }',
    '    }',
  ]);
  const older = parseBlockLines(['    "x": {', ...block.lines.slice(spliceAt, -1), '    }']);
  if (!newer || !older) return;

  const merged = structuredClone(newer);
  const added = deepMergePreferBase(merged, older);
  arr.splice(start, block.end - start + 1, ...stringifyPackage(fullKey, merged));
  report.merges.push({
    key: fullKey,
    action: 'inline-splice-resolved',
    keptVersion: merged.version,
    fromVersion: older.version,
    addedFields: added,
  });
}

function preprocessTypeUtilsSplice(arr) {
  const firstIdx = arr.findIndex((l) => l === '    "node_modules/@typescript-eslint/type-utils": {');
  const secondIdx = arr.findIndex(
    (l, i) => i > firstIdx && l === '    "node_modules/@typescript-eslint/type-utils": {',
  );
  if (firstIdx === -1 || secondIdx === -1) return;

  const block2 = extractBlockFrom(arr, secondIdx);
  if (!block2) return;

  const tsApiIdx = arr.findIndex(
    (l, i) => i > firstIdx && i < secondIdx && l.includes('"ts-api-utils": "^2.5.0"'),
  );
  const newerPartial =
    tsApiIdx !== -1
      ? parseBlockLines([
          arr[firstIdx],
          ...arr.slice(firstIdx + 1, tsApiIdx + 1),
          '      }',
          '    }',
        ])
      : null;
  const older = parseBlockLines(block2.lines);
  if (!newerPartial || !older) return;

  const merged = structuredClone(newerPartial);
  const added = deepMergePreferBase(merged, older);
  arr.splice(firstIdx, block2.end - firstIdx + 1, ...stringifyPackage('node_modules/@typescript-eslint/type-utils', merged));
  report.merges.push({
    key: 'node_modules/@typescript-eslint/type-utils',
    action: 'splice-resolved',
    keptVersion: merged.version,
    fromVersion: older.version,
    addedFields: added,
  });
}

function upsert(map, order, key, obj, meta) {
  if (!obj) {
    report.unparsed = report.unparsed || [];
    report.unparsed.push({ key, ...meta });
    return;
  }
  if (!obj.version && key !== '') {
    report.unparsed = report.unparsed || [];
    report.unparsed.push({ key, ...meta });
    return;
  }
  if (!map.has(key)) {
    map.set(key, structuredClone(obj));
    ensureOrder(key);
    report.merges.push({ key, action: 'insert', version: obj.version, ...meta });
    return;
  }
  const cur = map.get(key);
  const cmp = compareVersions(cur.version, obj.version);
  if (cmp >= 0) {
    const added = deepMergePreferBase(cur, obj);
    if (added.length) {
      report.merges.push({
        key,
        action: 'merge-into-newer',
        keptVersion: cur.version,
        fromVersion: obj.version,
        addedFields: added,
        ...meta,
      });
    } else {
      report.discarded.push({ key, version: obj.version, reason: cmp > 0 ? 'older' : 'identical', ...meta });
    }
  } else {
    const added = deepMergePreferBase(obj, cur);
    map.set(key, obj);
    report.merges.push({
      key,
      action: 'promoted-newer',
      keptVersion: obj.version,
      fromVersion: cur.version,
      addedFields: added,
      ...meta,
    });
  }
}

function preprocessOrphanSplices(arr) {
  const pluginIdx = arr.findIndex((l) => l === '    "node_modules/@typescript-eslint/eslint-plugin": {');
  const plugin2Idx = arr.findIndex(
    (l, i) => i > pluginIdx && l === '    "node_modules/@typescript-eslint/eslint-plugin": {',
  );
  if (pluginIdx === -1 || plugin2Idx === -1) return;

  const block2 = extractBlockFrom(arr, plugin2Idx);
  if (!block2) return;

  const findBetween = (needle) => {
    for (let j = pluginIdx + 1; j < plugin2Idx; j++) {
      if (arr[j] === needle) return j;
    }
    return -1;
  };

  const relocateOrphan = (needle, key) => {
    const idx = findBetween(needle);
    if (idx === -1) return;
    const ob = extractBlockFrom(arr, idx);
    if (!ob) return;
    const o = parseBlockLines(ob.lines);
    if (!o) return;
    upsert(packageMap, order, key, o, {
      source: 'relocated-from-eslint-plugin-splice',
      line: ob.start + 1,
    });
    report.relocations.push({
      from: 'node_modules/@typescript-eslint/eslint-plugin',
      to: key,
      line: ob.start + 1,
      version: o.version,
    });
  };

  relocateOrphan('    "node_modules/@types/react": {', 'node_modules/@types/react');
  relocateOrphan('    "node_modules/@types/react-dom": {', 'node_modules/@types/react-dom');

  const propIdx = arr.findIndex(
    (l, i) => i > pluginIdx && i < plugin2Idx && l.includes('prop-types-15.7.13'),
  );
  if (propIdx !== -1) {
    const fragObj = parseBlockLines([
      '    "x": {',
      '      "version": "15.7.13",',
      arr[propIdx + 1],
      arr[propIdx + 2],
      '      "dev": true',
      '    }',
    ]);
    if (fragObj) {
      upsert(packageMap, order, 'node_modules/@types/prop-types', fragObj, {
        source: 'relocated-fragment-from-eslint-plugin-splice',
      });
      report.relocations.push({
        from: 'node_modules/@typescript-eslint/eslint-plugin',
        to: 'node_modules/@types/prop-types',
        version: fragObj.version,
        note: 'fragment — merged if unique fields',
      });
    }
  }

  const tsApiIdx = arr.findIndex((l, i) => i > pluginIdx && i < plugin2Idx && l.includes('"ts-api-utils": "^2.5.0"'));
  const newerPartial =
    tsApiIdx !== -1
      ? parseBlockLines([
          arr[pluginIdx],
          ...arr.slice(pluginIdx + 1, tsApiIdx + 1),
          '      }',
          '    }',
        ])
      : null;
  const older = parseBlockLines(block2.lines);

  if (newerPartial && older) {
    const merged = structuredClone(newerPartial);
    const added = deepMergePreferBase(merged, older);
    const mergedLines = stringifyPackage('node_modules/@typescript-eslint/eslint-plugin', merged);
    arr.splice(pluginIdx, block2.end - pluginIdx + 1, ...mergedLines);
    report.merges.push({
      key: 'node_modules/@typescript-eslint/eslint-plugin',
      action: 'splice-resolved',
      keptVersion: merged.version,
      fromVersion: older.version,
      addedFields: added,
    });
  }
}

const packageMap = new Map();
const order = [];

function ensureOrder(key) {
  if (!order.includes(key)) order.push(key);
}

function stringifyPackage(key, obj) {
  const body = JSON.stringify(obj, null, 2).slice(1, -1);
  return [`    "${key}": {`, ...body.split('\n').map((l) => (l ? `  ${l}` : l)), '    },'];
}

patchStructure(lines);
preprocessOrphanSplices(lines);
preprocessTypeUtilsSplice(lines);
for (const key of [
  'node_modules/@typescript-eslint/typescript-estree',
  'node_modules/sucrase',
  'node_modules/ts-api-utils',
  'node_modules/typescript-eslint',
]) {
  resolveInlineSplice(lines, key);
}

const packagesStart = lines.findIndex((l) => l.trim() === '"packages": {');
const header = lines.slice(0, packagesStart + 1);
const footer = [];
const rawBlocks = [];

let i = packagesStart + 1;
while (i < lines.length) {
  if (/^  \},?\s*$/.test(lines[i] || '')) {
    footer.push(...lines.slice(i));
    break;
  }
  const key = isPackageKeyLine(lines[i] || '');
  if (key) {
    const block = extractPackageBlock(lines, i);
    if (!block) {
      report.extractionError = { line: i + 1, key };
      break;
    }
    rawBlocks.push({ key, ...block });
    i = block.end + 1;
    continue;
  }
  i++;
}

for (const block of rawBlocks) {
  const versions = [];
  for (let j = 1; j < block.lines.length - 1; j++) {
    if (/^\s+"version":/.test(block.lines[j])) versions.push(j);
  }
  if (versions.length >= 2) {
    const newerLines = [...block.lines.slice(0, versions[1])];
    if (!newerLines[newerLines.length - 1].trim().endsWith('}')) newerLines.push('      }');
    newerLines.push('    }');
    const newer = parseBlockLines(newerLines);
    const older = parseBlockLines(['    "x": {', ...block.lines.slice(versions[1], -1), '    }']);
    if (newer && older) {
      const merged = structuredClone(newer);
      const added = deepMergePreferBase(merged, older);
      upsert(packageMap, order, block.key, merged, {
        source: 'inline-splice',
        line: block.start + 1,
        addedFields: added,
      });
      continue;
    }
  }

  const obj = repairFromReference(block.key, block.lines);
  upsert(packageMap, order, block.key, obj, { source: 'block', line: block.start + 1 });
}

if (!packageMap.has('') && refPackages['']) {
  packageMap.set('', structuredClone(refPackages['']));
  report.merges.push({ key: '', action: 'insert-root-from-reference', version: refPackages[''].version });
}

const finalOrder = [];
const seenOrder = new Set();
for (const block of rawBlocks) {
  if (packageMap.has(block.key) && !seenOrder.has(block.key)) {
    finalOrder.push(block.key);
    seenOrder.add(block.key);
  }
}
for (const key of order) {
  if (packageMap.has(key) && !seenOrder.has(key)) {
    finalOrder.push(key);
    seenOrder.add(key);
  }
}
if (packageMap.has('') && !seenOrder.has('')) finalOrder.unshift('');

const outBlocks = finalOrder.map((key, idx) => {
  const bl = stringifyPackage(key, packageMap.get(key));
  if (idx < finalOrder.length - 1) bl[bl.length - 1] = '    },';
  else bl[bl.length - 1] = '    }';
  return bl;
});

const tail = footer.length > 0 ? footer : ['  }', '}'];

const outText = [...header, ...outBlocks.flat(), ...tail].join('\n') + '\n';
fs.writeFileSync(output, outText);

let valid = false;
try {
  JSON.parse(outText);
  valid = true;
} catch (e) {
  if (e instanceof Error) {
    report.jsonError = {
      name: e.name,
      message: e.message,
      stack: e.stack,
    };
  } else {
    report.jsonError = {
      message: String(e),
    };
  }
}

fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');

console.log(`Patches: ${report.structurePatches.length} | Relocations: ${report.relocations.length}`);
console.log(`Structure repairs: ${report.structureRepairs.length} | Merges: ${report.merges.length}`);
if (report.extractionError) console.log('Extraction stopped:', report.extractionError);
if (report.unparsed?.length) console.log('Unparsed:', report.unparsed.length);
console.log(valid ? `VALID -> ${output}` : `INVALID: ${report.jsonError}`);
