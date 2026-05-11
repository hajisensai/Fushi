#!/usr/bin/env node
/**
 * convert-yomitan-transforms.mjs
 *
 * Reads Yomitan language transform descriptor files and outputs minified JSON
 * for each language. The JSON is consumed by the hoshidicts C++ deinflector.
 *
 * Usage:  node convert-yomitan-transforms.mjs
 *
 * Prerequisites:
 *   - Yomitan source at ../../yomitan/ext/js/language/
 *   - Node >= 18 (ESM dynamic import)
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
const YOMITAN_LANG_DIR = path.resolve(__dirname, '../../yomitan/ext/js/language');
const ORIGINAL_TRANSFORMS = path.join(YOMITAN_LANG_DIR, 'language-transforms.js');
const BACKUP_TRANSFORMS   = ORIGINAL_TRANSFORMS + '.bak';
const OUTPUT_DIR = path.resolve(__dirname, '../hibiki/assets/transforms');

// ---------------------------------------------------------------------------
// Language table: code → { dir, file, exportName }
// ---------------------------------------------------------------------------
/** @type {Array<{code: string, dir: string, file: string, exportName: string}>} */
const LANGUAGES = [
  { code: 'ar',  dir: 'ar',  file: 'arabic-transforms.js',        exportName: 'arabicTransforms' },
  { code: 'de',  dir: 'de',  file: 'german-transforms.js',        exportName: 'germanTransforms' },
  { code: 'el',  dir: 'el',  file: 'modern-greek-transforms.js',  exportName: 'modernGreekTransforms' },
  { code: 'en',  dir: 'en',  file: 'english-transforms.js',       exportName: 'englishTransforms' },
  { code: 'eo',  dir: 'eo',  file: 'esperanto-transforms.js',     exportName: 'esperantoTransforms' },
  { code: 'es',  dir: 'es',  file: 'spanish-transforms.js',       exportName: 'spanishTransforms' },
  { code: 'eu',  dir: 'eu',  file: 'basque-transforms.js',        exportName: 'basqueTransforms' },
  { code: 'fr',  dir: 'fr',  file: 'french-transforms.js',        exportName: 'frenchTransforms' },
  { code: 'ga',  dir: 'ga',  file: 'irish-transforms.js',         exportName: 'irishTransforms' },
  { code: 'grc', dir: 'grc', file: 'ancient-greek-transforms.js', exportName: 'ancientGreekTransforms' },
  { code: 'ja',  dir: 'ja',  file: 'japanese-transforms.js',      exportName: 'japaneseTransforms' },
  { code: 'ka',  dir: 'ka',  file: 'georgian-transforms.js',      exportName: 'georgianTransforms' },
  { code: 'ko',  dir: 'ko',  file: 'korean-transforms.js',        exportName: 'koreanTransforms' },
  { code: 'la',  dir: 'la',  file: 'latin-transforms.js',         exportName: 'latinTransforms' },
  { code: 'sga', dir: 'sga', file: 'old-irish-transforms.js',     exportName: 'oldIrishTransforms' },
  { code: 'sq',  dir: 'sq',  file: 'albanian-transforms.js',      exportName: 'albanianTransforms' },
  { code: 'tl',  dir: 'tl',  file: 'tagalog-transforms.js',       exportName: 'tagalogTransforms' },
  { code: 'yi',  dir: 'yi',  file: 'yiddish-transforms.js',       exportName: 'yiddishTransforms' },
];

// ---------------------------------------------------------------------------
// Shim content — replaces language-transforms.js during import
// ---------------------------------------------------------------------------
const SHIM_CONTENT = `
/**
 * Shim for language-transforms.js — intercepts factory calls and stores
 * raw arguments as properties so the conversion script can read them.
 */

export function suffixInflection(inflectedSuffix, deinflectedSuffix, conditionsIn, conditionsOut) {
  return {
    type: 'suffix',
    _fromSuffix: inflectedSuffix,
    _toSuffix: deinflectedSuffix,
    conditionsIn,
    conditionsOut,
    // Keep deinflected so existing code that reads it still works
    deinflected: deinflectedSuffix,
    isInflected: new RegExp(inflectedSuffix + '$'),
    deinflect: (text) => text.slice(0, -inflectedSuffix.length) + deinflectedSuffix,
  };
}

export function prefixInflection(inflectedPrefix, deinflectedPrefix, conditionsIn, conditionsOut) {
  return {
    type: 'prefix',
    _fromPrefix: inflectedPrefix,
    _toPrefix: deinflectedPrefix,
    conditionsIn,
    conditionsOut,
    isInflected: new RegExp('^' + inflectedPrefix),
    deinflect: (text) => deinflectedPrefix + text.slice(inflectedPrefix.length),
  };
}

export function wholeWordInflection(inflectedWord, deinflectedWord, conditionsIn, conditionsOut) {
  return {
    type: 'wholeWord',
    _from: inflectedWord,
    _to: deinflectedWord,
    conditionsIn,
    conditionsOut,
    isInflected: new RegExp('^' + inflectedWord + '$'),
    deinflect: () => deinflectedWord,
  };
}
`;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Convert a single Yomitan condition object to our JSON format.
 * @param {string} key
 * @param {object} cond
 * @returns {object}
 */
function convertCondition(key, cond) {
  /** @type {Record<string, any>} */
  const out = { name: cond.name };
  if (typeof cond.isDictionaryForm === 'boolean') {
    out.isDictionaryForm = cond.isDictionaryForm;
  }
  if (Array.isArray(cond.subConditions) && cond.subConditions.length > 0) {
    out.subConditions = cond.subConditions;
  }
  return out;
}

/**
 * Convert a single rule object from the shim format to our JSON format.
 * Returns null for rules we cannot represent (type === 'other').
 * @param {object} rule
 * @returns {object | null}
 */
function convertRule(rule) {
  if (rule.type === 'suffix') {
    return {
      type: 'suffix',
      fromSuffix: rule._fromSuffix,
      toSuffix: rule._toSuffix,
      conditionsIn: rule.conditionsIn,
      conditionsOut: rule.conditionsOut,
    };
  }
  if (rule.type === 'prefix') {
    return {
      type: 'prefix',
      fromPrefix: rule._fromPrefix,
      toPrefix: rule._toPrefix,
      conditionsIn: rule.conditionsIn,
      conditionsOut: rule.conditionsOut,
    };
  }
  if (rule.type === 'wholeWord') {
    return {
      type: 'wholeWord',
      from: rule._from,
      to: rule._to,
      conditionsIn: rule.conditionsIn,
      conditionsOut: rule.conditionsOut,
    };
  }
  // 'other' type — regex rules we cannot represent
  return null;
}

/**
 * Convert a full Yomitan transform descriptor to our JSON schema.
 * @param {object} descriptor
 * @returns {object}
 */
function convertDescriptor(descriptor) {
  // Conditions
  /** @type {Record<string, object>} */
  const conditions = {};
  for (const [key, cond] of Object.entries(descriptor.conditions)) {
    conditions[key] = convertCondition(key, cond);
  }

  // Transforms — skip groups that end up with zero extractable rules
  /** @type {Record<string, object>} */
  const transforms = {};
  for (const [key, transform] of Object.entries(descriptor.transforms)) {
    const rules = transform.rules
      .map(convertRule)
      .filter((r) => r !== null);
    if (rules.length > 0) {
      transforms[key] = {
        name: transform.name,
        description: transform.description || '',
        rules,
      };
    }
  }

  return {
    language: descriptor.language,
    conditions,
    transforms,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  // Ensure output directory exists
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  // Backup original language-transforms.js
  console.log('Backing up original language-transforms.js ...');
  fs.copyFileSync(ORIGINAL_TRANSFORMS, BACKUP_TRANSFORMS);

  // Install shim
  console.log('Installing shim ...');
  fs.writeFileSync(ORIGINAL_TRANSFORMS, SHIM_CONTENT, 'utf-8');

  /** @type {string[]} */
  const succeeded = [];
  /** @type {Array<{code: string, error: string}>} */
  const failed = [];

  try {
    for (const lang of LANGUAGES) {
      const srcPath = path.join(YOMITAN_LANG_DIR, lang.dir, lang.file);
      const outPath = path.join(OUTPUT_DIR, `${lang.code}.json`);

      try {
        // Dynamic import with file:// URL and cache-bust to avoid stale modules
        const url = pathToFileURL(srcPath).href + '?t=' + Date.now();
        const mod = await import(url);
        const descriptor = mod[lang.exportName];

        if (!descriptor) {
          throw new Error(`Export '${lang.exportName}' not found in module`);
        }

        const json = convertDescriptor(descriptor);
        fs.writeFileSync(outPath, JSON.stringify(json), 'utf-8');

        const transformCount = Object.keys(json.transforms).length;
        const conditionCount = Object.keys(json.conditions).length;
        let ruleCount = 0;
        for (const t of Object.values(json.transforms)) {
          ruleCount += /** @type {any} */ (t).rules.length;
        }
        console.log(`  ✓ ${lang.code}: ${transformCount} groups, ${ruleCount} rules, ${conditionCount} conditions`);
        succeeded.push(lang.code);
      } catch (/** @type {any} */ err) {
        console.error(`  ✗ ${lang.code}: ${err.message}`);
        failed.push({ code: lang.code, error: err.message });
      }
    }
  } finally {
    // Always restore original
    console.log('\nRestoring original language-transforms.js ...');
    fs.copyFileSync(BACKUP_TRANSFORMS, ORIGINAL_TRANSFORMS);
    fs.unlinkSync(BACKUP_TRANSFORMS);
    console.log('Restored.');
  }

  // Summary
  console.log(`\n=== Summary ===`);
  console.log(`Succeeded: ${succeeded.length}/${LANGUAGES.length} (${succeeded.join(', ')})`);
  if (failed.length > 0) {
    console.log(`Failed: ${failed.length} (${failed.map((f) => f.code).join(', ')})`);
  }
}

main().catch((err) => {
  console.error('Fatal error:', err);
  // Attempt restore on fatal error
  if (fs.existsSync(BACKUP_TRANSFORMS)) {
    fs.copyFileSync(BACKUP_TRANSFORMS, ORIGINAL_TRANSFORMS);
    fs.unlinkSync(BACKUP_TRANSFORMS);
    console.log('Restored original after fatal error.');
  }
  process.exit(1);
});
