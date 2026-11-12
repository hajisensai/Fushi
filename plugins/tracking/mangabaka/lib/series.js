/// <reference path="../../../../tools/tracking-plugin-sdk/fushi-tracking-plugin.d.ts" />
// Series JSON -> Subject, for both the v1 series shape and the v2 search shape. Port of Fushi's former
// built-in MangaBaka client (`parseSeries`) and provider (`mangaBakaBookSubject`).
'use strict';

/** MangaBaka series `type` values that count as manga (Manga section). */
const COMIC_TYPES = ['manga', 'manhwa', 'manhua', 'oel'];
/** MangaBaka series `type` values that count as books (Books section). */
const BOOK_TYPES = ['novel'];
const COMIC_TYPE_SET = new Set(COMIC_TYPES);
const BOOK_TYPE_SET = new Set(BOOK_TYPES);

/** @type {{ [kind: string]: string[] }} Series types searched for each Fushi kind. */
const TYPES_BY_KIND = { manga: COMIC_TYPES, novel: BOOK_TYPES };

/**
 * MangaBaka sends some counts as strings (`"18"`, `"1432"`) and progress as numbers.
 * @param {unknown} value @returns {number | undefined}
 */
function toInt(value) {
  let n = Number.NaN;
  if (typeof value === 'number') n = value;
  else if (typeof value === 'string' && value.trim()) n = Number(value.trim());
  return Number.isFinite(n) ? Math.trunc(n) : undefined;
}

/** @param {unknown} value @returns {number | undefined} only counts above zero (0 means "unknown"). */
function toPositive(value) {
  const n = toInt(value);
  return n !== undefined && n > 0 ? n : undefined;
}

/** @param {string} type @returns {FushiTracking.Kind | null} null = not a book type: drop it. */
function kindOfType(type) {
  if (BOOK_TYPE_SET.has(type)) return 'novel';
  if (COMIC_TYPE_SET.has(type)) return 'manga';
  return null;
}

/** @param {unknown} language @returns {string} `ja` for `ja-JP`; '' when absent. */
function baseLanguage(language) {
  return String(language ?? '').split('-')[0];
}

/**
 * The first listed title passing [test].
 * @param {any[]} listed @param {(item: any) => boolean} test @returns {string | undefined}
 */
function firstListedTitle(listed, test) {
  const item = listed.find((i) => typeof i.title === 'string' && i.title.trim() && test(i));
  return item ? item.title.trim() : undefined;
}

/**
 * Every known title, main title first. v1 has `title` / `native_title` / `romanized_title`; v2 search only
 * has `titles[]` in no particular order, so its main title is the English primary, else one in the
 * series' original language.
 * @param {any} json @returns {string[]}
 */
function titlesOf(json) {
  /** @type {Set<string>} insertion-ordered, so the main title stays first */
  const titles = new Set();
  const add = (/** @type {unknown} */ value) => {
    const t = typeof value === 'string' ? value.trim() : '';
    if (t) titles.add(t);
  };
  add(json.title);
  add(json.native_title);
  add(json.romanized_title);
  /** @type {any[]} */
  const listed = Array.isArray(json.titles) ? json.titles.filter((/** @type {any} */ i) => i && typeof i === 'object') : [];
  if (titles.size === 0) {
    add(firstListedTitle(listed, (item) => item.language === 'en' && item.is_primary === true));
    const language = baseLanguage(json.original_language);
    if (language) add(firstListedTitle(listed, (item) => baseLanguage(item.language) === language));
  }
  for (const item of listed) add(item.title);
  return [...titles];
}

/**
 * Ids of the same series on other sites (`source.anilist.id`, `source.my_anime_list.id`).
 * @param {any} json @returns {{ [idType: string]: number } | undefined}
 */
function linkedIdsOf(json) {
  const source = json.source && typeof json.source === 'object' ? json.source : {};
  const sourceId = (/** @type {string} */ key) => {
    const entry = source[key];
    return entry && typeof entry === 'object' ? toPositive(entry.id) : undefined;
  };
  /** @type {{ [idType: string]: number }} */
  const linkedIds = {};
  const aniList = sourceId('anilist');
  const mal = sourceId('my_anime_list');
  if (aniList) linkedIds.anilist = aniList;
  if (mal) linkedIds.mal = mal;
  return Object.keys(linkedIds).length ? linkedIds : undefined;
}

/** @param {unknown} authors @returns {string[]} */
function authorsOf(authors) {
  if (!Array.isArray(authors)) return [];
  return authors.filter((a) => typeof a === 'string' && a.trim()).map((/** @type {string} */ a) => a.trim());
}

/**
 * The subject of a book series; null for a type that is not a book, or a series without a title.
 * @param {any} json @param {number} id @param {string} type @returns {FushiTracking.Subject | null}
 */
function subjectOf(json, id, type) {
  const kind = kindOfType(type);
  const titles = titlesOf(json);
  if (!kind || titles.length === 0) return null;
  return {
    id,
    name: titles[0],
    kind,
    titles,
    authors: authorsOf(json.authors),
    totalChapters: toPositive(json.total_chapters),
    // MangaBaka sets final_volume only once the series has finished.
    finalVolume: toPositive(json.final_volume),
    finished: json.status === 'completed',
    linkedIds: linkedIdsOf(json),
  };
}

/**
 * The parts of a series the plugin needs.
 * @typedef {{ id: number, type: string, mergedWith: number | null, subject: FushiTracking.Subject | null }} Series
 */

/**
 * @param {any} json one series object (v1 or v2)
 * @returns {Series | null} null when it has no numeric id (skipped)
 */
function parseSeries(json) {
  if (!json || typeof json !== 'object' || typeof json.id !== 'number') return null;
  const id = Math.trunc(json.id);
  const type = typeof json.type === 'string' ? json.type : 'other';
  // A merged series points at the series that replaced it.
  const mergedWith = json.state === 'merged' ? toPositive(json.merged_with) ?? null : null;
  return { id, type, mergedWith, subject: subjectOf(json, id, type) };
}

/** @param {unknown} data @returns {Series[]} */
function parseSeriesList(data) {
  if (!Array.isArray(data)) return [];
  return data.flatMap((item) => {
    const s = parseSeries(item);
    return s ? [s] : [];
  });
}

module.exports = { TYPES_BY_KIND, toInt, parseSeries, parseSeriesList };
