//
//  popup.js
//  Hibiki (adapted from Hoshi Reader for Android InAppWebView)
//
//  Copyright © 2026 Manhhao.
//  Copyright © 2023-2025 Yomitan Authors.
//  Copyright © 2021-2022 Yomichan Authors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

const KANJI_RANGE = '\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3005';
const KANJI_PATTERN = new RegExp(`[${KANJI_RANGE}]`);
const KANJI_SEGMENT_PATTERN = new RegExp(`[${KANJI_RANGE}]+|[^${KANJI_RANGE}]+`, 'g');
const KANA_PATTERN = /[\u3040-\u30FF\uFF66-\uFF9F]/;
const CJK_PATTERN = new RegExp(`[${KANJI_RANGE}]`);
const DEFAULT_HARMONIC_RANK = '9999999';
const SMALL_KANA_SET = new Set('ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ');
const NUMERIC_TAG = /^\d+$/;
// this might not cover every tag
const POS_TAGS = new Set(['n', 'adj-i', 'adj-na', 'adj-no', 'v1', 'vk', 'vs', 'vs-i', 'vs-s', 'vz', 'vi', 'vt']);
const audioUrls = {};

function audioCacheKey(expression, reading) {
    return `${expression || ''}\u0000${reading || ''}`;
}

async function resolveCachedAudioUrl(expression, reading, entryIndex) {
    const key = audioCacheKey(expression, reading);
    const cached = audioUrls[entryIndex];
    if (cached?.key === key) {
        return cached.url;
    }
    const url = await fetchAudioUrl(expression, reading);
    if (url) {
        audioUrls[entryIndex] = { key, url };
    } else {
        delete audioUrls[entryIndex];
    }
    return url;
}

let currentAudio = null;
let lastSelection = '';
let currentDictionaryMedia = null;
const selectedDictionaries = {};

// TODO-270 D: tri-state mine button — "overwrite the latest mined card".
//
// After a successful mine that returned a backend note id (AnkiConnect only),
// remember WHICH word was the latest card so its ✓ becomes a green
// "editable" ✓⤺: clicking it again UPDATES that same note (repo.updateMinedNote)
// instead of deleting+re-creating. Mining a different word, or re-querying,
// supersedes the previous latest — only the single most-recently-mined word in
// this popup session stays editable; older ones fall back to an ordinary ✓.
//
// `lastMinedNoteId` is the note id to overwrite; `lastMinedEntryKey` identifies
// which expression / reading owns that id. AnkiDroid never returns an id
// (noteId stays null) → the latest state is never entered → graceful degrade to
// the existing two-state behaviour.
let lastMinedNoteId = null;
let lastMinedEntryKey = null;

// Stable identity for a popup entry (expression + reading): the same key the
// Dart side and the lookup-time duplicateCheck use.
function mineEntryKey(expression, reading) {
    return `${expression || ''}\u0000${reading || ''}`;
}

// Normalize the mineEntry/updateEntry handler reply into {ankiConnect, noteId}.
// The Dart handler now returns the structured MinePopupResult JSON; older/edge
// returns (a bare boolean, or null) are tolerated so a handler that has not been
// wired for updates still drives the ✓ refresh exactly as before.
function parseMineResult(reply) {
    if (reply && typeof reply === 'object') {
        const rawId = reply.noteId;
        const noteId = (typeof rawId === 'number' && Number.isFinite(rawId))
            ? rawId
            : null;
        return { ankiConnect: reply.ankiConnect === true, noteId };
    }
    return { ankiConnect: reply === true, noteId: null };
}

// Records the just-mined word as the editable "latest" card when the backend
// returned a note id; clears it otherwise (AnkiDroid / failure) so the button
// never shows a green ✓⤺ it cannot honour.
function rememberLatestMined(expression, reading, noteId) {
    if (typeof noteId === 'number' && Number.isFinite(noteId)) {
        lastMinedNoteId = noteId;
        lastMinedEntryKey = mineEntryKey(expression, reading);
    } else {
        lastMinedNoteId = null;
        lastMinedEntryKey = null;
    }
}

// True when [expression]/[reading] is the single most-recently-mined word whose
// card can still be overwritten in place (a real note id is held for it).
function isLatestEditable(expression, reading) {
    return lastMinedNoteId !== null &&
        lastMinedEntryKey === mineEntryKey(expression, reading);
}

// TODO-393/405「查词窗口句子上下文制卡」(取代 TODO-382 单按钮逐句追加)：弹窗里用「➕➖
// 递增递减步进器」把当前正查句之前/之后的 N 句作上下文纳入这张制卡的 sentence 字段。
//
// 数据流：JS 不持有句子文本/音频区间（都由宿主 Dart 的 MiningSentenceDraft 拥有），只
// 镜像两个标量「上几句 / 下几句」用于驱动步进器计数显示：
//   - 点➕（该方向 n+=1）/ 点➖（该方向 max(0, n-1)）→ callHandler('setSentenceContext',
//     {prev, next}) → 宿主按这两个数解析上下文句**整体替换**草稿 → 回传上下文句总数
//     （上 N + 下 N）。JS 镜像的是「请求几句」，真实合成由宿主按真句边界封顶。
//   - 制卡成功（mineEntry）/ 换词查词 → 宿主清空草稿 → JS 把两个镜像标量归零。
// 上下文是「选多少句」的标量：➕➖只是把这个标量升 1 / 降 1（整体替换草稿），不是把句子
// 越攒越多地累加进 JS。JS 不设硬上限——由宿主的段落/cue 边界天然封顶。
let sentenceCtxPrev = 0;
let sentenceCtxNext = 0;
// 兼容守卫/旧调用：保留镜像总数（上 N + 下 N）。
let sentenceDraftCount = 0;

// 刷新页面上所有句子上下文选择器的视觉态（多词条头共享同一对镜像标量）。
// querySelectorAll 不可用时（极端 fake DOM）静默跳过，不影响制卡主流程。
function refreshAllSentenceContextPickers() {
    sentenceDraftCount = sentenceCtxPrev + sentenceCtxNext;
    if (typeof document.querySelectorAll !== 'function') return;
    document.querySelectorAll('.sentence-context-picker')
        .forEach(refreshSentenceContextPicker);
    document.querySelectorAll('.clear-draft-button')
        .forEach(refreshClearDraftButton);
}

// 把一个上下文步进器里两个方向的计数显示同步到镜像标量：更新计数文本、n>0 时给计数加
// .selected（绿色高亮），并在 n<=0 时禁用对应方向的➖（不能再减到负）。
function refreshSentenceContextPicker(picker) {
    if (!picker || typeof picker.querySelectorAll !== 'function') return;
    picker.querySelectorAll('.context-count').forEach(function(count) {
        const dir = count.dataset.dir;
        const n = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
        count.textContent = String(n);
        count.classList.toggle('selected', n > 0);
    });
    picker.querySelectorAll('.context-stepper-btn.minus').forEach(function(btn) {
        const dir = btn.dataset.dir;
        const n = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
        btn.disabled = n <= 0;
    });
}

// TODO-382/393 可撤销：刷新「清空已加句子」按钮可见性。仅在已选上下文（总数>0）时显示，
// 给用户一个明确、可见的「回到只制当前句」入口。
function refreshClearDraftButton(button) {
    if (!button) return;
    button.title = window.i18nClearSentenceDraftTooltip || '清空已加句子';
    button.hidden = (sentenceCtxPrev + sentenceCtxNext) <= 0;
}

// 把当前两个镜像标量发给宿主整体设置上下文，回传上下文句总数。宿主未接入 / 出错时
// 返回当前镜像总数（不漂移）。
async function setSentenceContextOnHost() {
    try {
        const reply = await window.flutter_inappwebview.callHandler(
            'setSentenceContext', { prev: sentenceCtxPrev, next: sentenceCtxNext });
        const n = (typeof reply === 'number' && Number.isFinite(reply)) ? reply : 0;
        return n >= 0 ? n : 0;
    } catch (e) {
        console.error('setSentenceContext failed', e);
        return sentenceCtxPrev + sentenceCtxNext;
    }
}

// 清空宿主草稿（回到只制当前句），回传清空后的句数（恒 0）。
async function clearSentenceDraftOnHost() {
    try {
        const reply = await window.flutter_inappwebview.callHandler('clearSentenceDraft');
        const n = (typeof reply === 'number' && Number.isFinite(reply)) ? reply : 0;
        return n >= 0 ? n : 0;
    } catch (e) {
        console.error('clearSentenceDraft failed', e);
        return sentenceCtxPrev + sentenceCtxNext;
    }
}

// BUG-297 / TODO-393：把句子上下文镜像标量归零（不发宿主信号）。换词复用常驻热槽
// WebView 时宿主只重注入 lookupEntries 再调 renderPopup()（不重载页面），这三个模块级
// 标量不像页面刷新那样自动归零，renderPopup 据残留值会把上一个词的「上 N / 下 N」按钮
// 着色成 selected、清空按钮显示出来，与宿主已清空的草稿不一致。宿主在换词注入脚本里调
// 本函数把镜像与已清的草稿对齐，再 renderPopup() 重建选择器即回到初始 0/0 态。
// 制卡成功(mineEntry)/点×清空两处已各自就地归零（同事件内同步），不依赖本函数。
window.resetSentenceContextMirror = function() {
    sentenceCtxPrev = 0;
    sentenceCtxNext = 0;
    sentenceDraftCount = 0;
};

// 构造一个句子上下文步进器：两行「上 [➖][N][➕]」+「下 [➖][N][➕]」。点➕该方向 n+=1、点
// ➖该方向 max(0, n-1)，把该方向的上下文句数整组重发宿主。无 JS 硬上限——由宿主的段落/
// cue 边界天然封顶（镜像可继续升、宿主合成时按真句封顶）。
function buildSentenceContextPicker() {
    const picker = el('div', { className: 'sentence-context-picker' });
    const setDirCount = async function(dir, n) {
        if (picker.dataset.busy === '1') return;
        picker.dataset.busy = '1';
        try {
            if (dir === 'prev') sentenceCtxPrev = n;
            else sentenceCtxNext = n;
            sentenceDraftCount = await setSentenceContextOnHost();
            refreshAllSentenceContextPickers();
        } finally {
            picker.dataset.busy = '';
        }
    };
    const makeStepperBtn = function(dir, sign, symbol) {
        const btn = el('button', {
            className: 'context-stepper-btn ' + sign,
            textContent: symbol,
        });
        btn.dataset.dir = dir;
        btn.onclick = function() {
            const cur = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
            const next = sign === 'plus' ? cur + 1 : Math.max(0, cur - 1);
            // 已到 0 再点➖是空操作（避免无谓重发宿主）。
            if (next === cur) return;
            setDirCount(dir, next);
        };
        return btn;
    };
    const makeRow = function(dir, label) {
        const row = el('div', { className: 'context-row' });
        row.appendChild(el('span', { className: 'context-label', textContent: label }));
        row.appendChild(makeStepperBtn(dir, 'minus', '➖'));
        const count = el('span', { className: 'context-count', textContent: '0' });
        count.dataset.dir = dir;
        row.appendChild(count);
        row.appendChild(makeStepperBtn(dir, 'plus', '➕'));
        return row;
    };
    picker.appendChild(makeRow('prev', window.i18nContextPrevLabel || '上'));
    picker.appendChild(makeRow('next', window.i18nContextNextLabel || '下'));
    return picker;
}


function el(tag, props = {}, children = []) {
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
        if (key in element) {
            element[key] = value;
        } else {
            element.setAttribute(key, value);
        }
    }
    
    if (children.length) {
        element.append(...children);
    }
    
    return element;
}

function toHiragana(text) {
    return text.replace(/[\u30A1-\u30F6]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0x60));
}

function toKebabCase(str) {
    return str.replace(/([A-Z])/g, (_, c, i) => (i ? '-' : '') + c.toLowerCase());
}

// https://github.com/yomidevs/yomitan/blob/c0abb9e98a15aeb6b6f8f6e2d91fe5e54240b54a/ext/js/language/ja/japanese.js#L332
function isStringPartiallyJapanese(text) {
    if (!text) {
        return false;
    }
    return KANA_PATTERN.test(text) || CJK_PATTERN.test(text);
}

// https://github.com/yomidevs/yomitan/blob/c0abb9e98a15aeb6b6f8f6e2d91fe5e54240b54a/ext/js/language/zh/chinese.js#L54
function isStringPartiallyChinese(text) {
    if (!text) {
        return false;
    }
    return CJK_PATTERN.test(text) || /[\u3100-\u312F\u31A0-\u31BF]/.test(text);
}

// https://github.com/yomidevs/yomitan/blob/c0abb9e98a15aeb6b6f8f6e2d91fe5e54240b54a/ext/js/language/text-utilities.js#L28
function getLanguageFromText(text, language) {
    const partiallyJapanese = isStringPartiallyJapanese(text);
    const partiallyChinese = isStringPartiallyChinese(text);
    if (!['zh', 'yue'].includes(language ?? '')) {
        if (partiallyJapanese) {
            return 'ja';
        }
        if (partiallyChinese) {
            return 'zh';
        }
    }
    return language ?? null;
}

function openExternalLink(url) {
    window.flutter_inappwebview.callHandler('openLink', url);
}

function showDescription(element) {
    const description = element.getAttribute('data-description');
    if (!description) {
        return;
    }
    const overlay = document.querySelector('.overlay');
    document.querySelector('.overlay-content').textContent = description;
    overlay.style.display = 'block';
}

function closeOverlay() {
    document.querySelector('.overlay').style.display = 'none';
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L171
function createFuriganaSegment(text, reading) {
    return {text, reading};
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L242
function getFuriganaKanaSegments(text, reading) {
    const textLength = text.length;
    const newSegments = [];
    let start = 0;
    let state = (reading[0] === text[0]);
    for (let i = 1; i < textLength; ++i) {
        const newState = (reading[i] === text[i]);
        if (state === newState) { continue; }
        newSegments.push(createFuriganaSegment(text.substring(start, i), state ? '' : reading.substring(start, i)));
        state = newState;
        start = i;
    }
    newSegments.push(createFuriganaSegment(text.substring(start, textLength), state ? '' : reading.substring(start, textLength)));
    return newSegments;
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L182
function segmentizeFurigana(reading, readingNormalized, groups, groupsStart) {
    const groupCount = groups.length - groupsStart;
    if (groupCount <= 0) {
        return reading.length === 0 ? [] : null;
    }
    
    const group = groups[groupsStart];
    const {isKana, text} = group;
    const textLength = text.length;
    if (isKana) {
        const {textNormalized} = group;
        if (textNormalized !== null && readingNormalized.startsWith(textNormalized)) {
            const segments = segmentizeFurigana(
                                                reading.substring(textLength),
                                                readingNormalized.substring(textLength),
                                                groups,
                                                groupsStart + 1,
                                                );
            if (segments !== null) {
                if (reading.startsWith(text)) {
                    segments.unshift(createFuriganaSegment(text, ''));
                } else {
                    segments.unshift(...getFuriganaKanaSegments(text, reading));
                }
                return segments;
            }
        }
        return null;
    } else {
        let result = null;
        for (let i = reading.length; i >= textLength; --i) {
            const segments = segmentizeFurigana(
                                                reading.substring(i),
                                                readingNormalized.substring(i),
                                                groups,
                                                groupsStart + 1,
                                                );
            if (segments !== null) {
                if (result !== null) {
                    // More than one way to segmentize the tail; mark as ambiguous
                    return null;
                }
                const segmentReading = reading.substring(0, i);
                segments.unshift(createFuriganaSegment(text, segmentReading));
                result = segments;
            }
            // There is only one way to segmentize the last non-kana group
            if (groupCount === 1) {
                break;
            }
        }
        return result;
    }
}

function segmentFurigana(expression, reading) {
    if (!reading || reading === expression) {
        return [[expression, '']];
    }
    
    const groups = [];
    const segmentMatches = expression.match(KANJI_SEGMENT_PATTERN) || [];
    for (const text of segmentMatches) {
        const isKana = !KANJI_PATTERN.test(text[0]);
        const textNormalized = isKana ? toHiragana(text) : null;
        groups.push({isKana, text, textNormalized});
    }
    
    const readingNormalized = toHiragana(reading);
    const segments = segmentizeFurigana(reading, readingNormalized, groups, 0);
    
    if (segments !== null) {
        return segments.map(seg => [seg.text, seg.reading]);
    }
    
    return [[expression, reading]];
}

function buildFuriganaEl(parent, expression, reading) {
    const segments = segmentFurigana(expression, reading);
    for (const [text, furigana] of segments) {
        if (furigana) {
            const ruby = el('ruby', {}, [text]);
            ruby.appendChild(el('rt', { textContent: furigana }));
            parent.appendChild(ruby);
        } else {
            parent.appendChild(document.createTextNode(text));
        }
    }
    return segments.length === 1 && segments[0][1];
}

function constructFuriganaPlain(expression, reading) {
    let result = '';
    for (const [text, furigana] of segmentFurigana(expression, reading)) {
        if (furigana) {
            result += `${text}[${furigana}]`;
        } else {
            // space to separate from next furigana segment, not sure if this is the correct solution
            result += `${text} `;
        }
    }
    return result;
}


function applyTableStyles(html) {
    const tableStyle = 'table-layout:auto;border-collapse:collapse;';
    const cellStyle = 'border-style:solid;padding:0.25em;vertical-align:top;border-width:1px;border-color:currentColor;';
    const thStyle = 'font-weight:bold;' + cellStyle;
    
    return html
    .replace(/<table(?=[>\s])/g, `<table style="${tableStyle}"`)
    .replace(/<th(?=[>\s])/g, `<th style="${thStyle}"`)
    .replace(/<td(?=[>\s])/g, `<td style="${cellStyle}"`);
}

function applyImageStyles(node, imageContainer, aspectRatioSizer, imageBackground, image, filename, appearance, useEmUnits) {
    // .gloss-image-link
    node.style.cssText += 'display:inline-block;position:relative;line-height:1;max-width:100%;';
    // .gloss-image-container
    imageContainer.style.cssText += `display:inline-block;white-space:nowrap;max-width:100%;max-height:100vh;position:relative;vertical-align:top;line-height:0;overflow:hidden;font-size:${useEmUnits ? '1em' : '1px'};`;
    // .gloss-image-link[data-has-aspect-ratio=true] .gloss-image-sizer
    aspectRatioSizer.style.cssText += 'display:inline-block;width:0;vertical-align:top;font-size:0;';
    // .gloss-image-link[data-has-aspect-ratio=true] .gloss-image
    image.style.cssText += 'display:inline-block;vertical-align:top;object-fit:contain;border:none;outline:none;position:absolute;left:0;top:0;width:100%;height:100%;';
    // .gloss-image-background, set image url directly
    if (appearance === 'monochrome') {
        imageBackground.style.cssText += `--image:url("${filename}");position:absolute;left:0;top:0;width:100%;height:100%;-webkit-mask-repeat:no-repeat;-webkit-mask-position:center center;-webkit-mask-mode:alpha;-webkit-mask-size:contain;-webkit-mask-image:var(--image);mask-repeat:no-repeat;mask-position:center center;mask-mode:alpha;mask-size:contain;mask-image:var(--image);background-color:currentColor;`;
        image.style.opacity = '0';
    }
}

function getMediaFilename(dictionary, path) {
    const key = `${dictionary}\n${path}`;
    if (!currentDictionaryMedia.has(key)) {
        const extension = path.split('.').pop();
        currentDictionaryMedia.set(key, {
            dictionary,
            path,
            filename: `hoshi_dict_${currentDictionaryMedia.size}.${extension}`,
        });
    }
    return currentDictionaryMedia.get(key).filename;
}

function setStructuredContentElementStyle(element, style) {
    for (const [property, value] of Object.entries(style)) {
        if ((property === 'marginTop' || property === 'marginLeft' || property === 'marginRight' || property === 'marginBottom') && typeof value === 'number') {
            element.style[property] = `${value}em`;
        } else {
            element.style[property] = value;
        }
    }
}

function hasMismatchedNaturalAspectRatio(img, invAspectRatio) {
    if (img.naturalWidth <= 0 || img.naturalHeight <= 0 || invAspectRatio <= 0) {
        return false;
    }
    const naturalInvAspectRatio = img.naturalHeight / img.naturalWidth;
    return Math.abs(Math.log(naturalInvAspectRatio / invAspectRatio)) > Math.log(1.5);
}

function closeImageLightbox() {
    document.querySelector('.dict-image-lightbox')?.remove();
}

function openImageLightbox(imageUrl, alt) {
    closeImageLightbox();
    const overlay = document.createElement('div');
    overlay.className = 'dict-image-lightbox';
    overlay.setAttribute('role', 'button');
    overlay.setAttribute('aria-label', 'Close image preview');

    const image = document.createElement('img');
    image.className = 'dict-image-lightbox-image';
    image.src = imageUrl;
    image.alt = alt || '';
    overlay.appendChild(image);

    // 点灯箱任何位置（含图片本身）都关闭：放大图 max-width/height:100% 几乎铺满
    // 视口，用户必然点图片关闭。早先给图片 stopPropagation 拦掉了遮罩的关闭，导致
    // 只有四周 16px 边距能关＝「关不掉」（BUG-107）。预览无任何图内交互，故让整个
    // 灯箱统一 tap-to-close。
    overlay.addEventListener('click', () => closeImageLightbox());

    document.body.appendChild(overlay);
}

function enableDefinitionImagePreview(node, imageUrl, alt) {
    node.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
        openImageLightbox(imageUrl, alt);
    });
}

const COMPACT_GLOSSARIES_ANKI = `.yomitan-glossary ul[data-sc-content="glossary"] > li:not(:first-child)::before, .yomitan-glossary .glossary-list > li:not(:first-child)::before { white-space: pre-wrap; content: " | "; display: inline; color: rgb(119, 119, 119); }
.yomitan-glossary ul[data-sc-content="glossary"] > li, .yomitan-glossary .glossary-list > li { display: inline; }
.yomitan-glossary ul[data-sc-content="glossary"], .yomitan-glossary .glossary-list { display: inline; list-style: none; padding-left: 0px; }`;

// the following two should roughly match the glossary format of yomitan and keep compatibility with notetypes like lapis
// 23.01.2026: this still has some differences
// 24.01.2026: should be a bit closer now
// 25.01.2026: fixed jmdict
// 19.02.2026: fixed jmdict legacy
// 24.03.2026: fixed compact glossaries for jmdict legacy
function constructSingleGlossaryHtml(entryIndex) {
    if (!window.lookupEntries || entryIndex >= window.lookupEntries.length) {
        return {};
    }
    
    const entry = window.lookupEntries[entryIndex];
    const glossaries = {};
    
    let lastDict = null;
    let currentGlossary = '';
    let prevTags = null;
    const flush = () => {
        if (!lastDict) {
            return;
        }
        
        let html = `<div style="text-align: left;" class="yomitan-glossary"><ol>${currentGlossary}</ol>`;
        const css = window.dictionaryStyles?.[lastDict] ?? '';
        if (css) {
            const scopedCss = constructDictCss(css, lastDict, `.yomitan-glossary [data-dictionary="${lastDict}"]`);
            const formatted = scopedCss
            .replace(/\s+/g, ' ')
            .replace(/\s*\{\s*/g, ' { ')
            .replace(/\s*\}\s*/g, ' }\n')
            .replace(/;\s*/g, '; ')
            .trim();
            html += `<style>${formatted}</style>`;
        }
        if (window.compactGlossariesAnki) {
            html += `<style>${COMPACT_GLOSSARIES_ANKI}</style>`;
        }
        html += `</div>`;
        
        glossaries[lastDict] = html;
        currentGlossary = '';
    };
    
    entry.glossaries.forEach(g => {
        const dictName = g.dictionary;
        const dictChanged = lastDict !== dictName;
        if (dictChanged) {
            flush();
            lastDict = dictName;
            prevTags = null;
        }

        const tempDiv = document.createElement('div');
        if (typeof g.content === 'string') {
            try {
                renderStructuredContent(tempDiv, JSON.parse(g.content), null, dictName, true);
            } catch {
                if (/<[a-z][\s\S]*>/i.test(g.content)) {
                    tempDiv.innerHTML = sanitizeHtml(g.content);
                } else {
                    renderStructuredContent(tempDiv, g.content, null, dictName, true);
                }
            }
        } else {
            renderStructuredContent(tempDiv, g.content, null, dictName, true);
        }

        const parsedTags = parseTags(g.definitionTags).filter(tag => !NUMERIC_TAG.test(tag));
        const posTags = [...new Set(parsedTags.filter(isPartOfSpeech))].sort();
        const currentTags = JSON.stringify(posTags);
        const filteredTags = parsedTags.filter(tag => !isPartOfSpeech(tag) || !(prevTags !== null && prevTags === currentTags));
        const tags = filteredTags.length > 0 ? filteredTags.join(', ') : '';
        const content = applyTableStyles(tempDiv.innerHTML);
        let listIdentifier = '';
        if (dictChanged) {
            label = tags ? `(${tags}, ${dictName})` : `(${dictName})`;
        } else {
            label = tags ? `(${tags})` : '';
        }
        currentGlossary += `<li data-dictionary="${dictName}"><i>${label}</i> <span>${content}</span></li>`
        prevTags = currentTags;
    });
    
    flush();
    return glossaries;
}

function constructGlossaryHtml(entryIndex) {
    if (!window.lookupEntries || entryIndex >= window.lookupEntries.length) {
        return null;
    }
    
    const entry = window.lookupEntries[entryIndex];
    let glossaryItems = '';
    const styles = {};
    let lastDict = '';
    let prevTags = null;
    let index = 0;
    
    entry.glossaries.forEach(g => {
        const dictName = g.dictionary;

        const tempDiv = document.createElement('div');
        if (typeof g.content === 'string') {
            try {
                renderStructuredContent(tempDiv, JSON.parse(g.content), null, dictName, true);
            } catch {
                if (/<[a-z][\s\S]*>/i.test(g.content)) {
                    tempDiv.innerHTML = sanitizeHtml(g.content);
                } else {
                    renderStructuredContent(tempDiv, g.content, null, dictName, true);
                }
            }
        } else {
            renderStructuredContent(tempDiv, g.content, null, dictName, true);
        }

        index++;
        let label = '';
        const parsedTags = parseTags(g.definitionTags).filter(tag => !NUMERIC_TAG.test(tag));
        const posTags = [...new Set(parsedTags.filter(isPartOfSpeech))].sort();
        const currentTags = JSON.stringify(posTags);
        const filteredTags = parsedTags.filter(tag => !isPartOfSpeech(tag) || !(prevTags !== null && prevTags === currentTags));
        const tags = filteredTags.length > 0 ? filteredTags.join(', ') : '';
        if (dictName !== lastDict) {
            index = 1;
            lastDict = dictName;
            label = tags ? `(${index}, ${tags}, ${dictName})` : `(${index}, ${dictName})`
        }
        else {
            label = tags ? `(${index}, ${tags})` : `(${index})`
        }
        
        glossaryItems += `<li data-dictionary="${dictName}"><i>${label}</i> <span>${applyTableStyles(tempDiv.innerHTML)}</span></li>`;
        prevTags = currentTags;
        
        const css = window.dictionaryStyles?.[dictName];
        if (css && !styles[dictName]) {
            styles[dictName] = css;
        }
    });
    
    let result = '<div style="text-align: left;" class="yomitan-glossary"><ol>';
    result += glossaryItems;
    result += '</ol>';
    
    for (const [dictName, css] of Object.entries(styles)) {
        const scopedCss = constructDictCss(css, dictName, `.yomitan-glossary [data-dictionary="${dictName}"]`);
        const formatted = scopedCss
        .replace(/\s+/g, ' ')
        .replace(/\s*\{\s*/g, ' { ')
        .replace(/\s*\}\s*/g, ' }\n')
        .replace(/;\s*/g, '; ')
        .trim();
        result += `<style>${formatted}</style>`;
    }
    if (window.compactGlossariesAnki) {
        result += `<style>${COMPACT_GLOSSARIES_ANKI}</style>`;
    }
    result += '</div>';
    return result;
}

function constructFrequencyHtml(frequencies) {
    if (!frequencies || frequencies.length === 0) {
        return '';
    }
    
    let result = '<ul style="text-align: left;">';
    frequencies.forEach(freqGroup => {
        if (!freqGroup?.frequencies?.length) {
            return;
        }
        const dictName = freqGroup.dictionary || '';
        freqGroup.frequencies.forEach(freq => {
            result += `<li>${dictName}: ${freq.displayValue || freq.value}</li>`;
        });
    });
    result += '</ul>';
    return result;
}

function constructPitchPositionHtml(pitches) {
    if (!pitches?.length) {
        return '';
    }
    
    let result = '<ol>';
    pitches.forEach(pitchGroup => {
        pitchGroup.pitchPositions.forEach(pos => {
            result += `<li><span style="display:inline;"><span>[</span><span>${pos}</span><span>]</span></span></li>`;
        });
    });
    result += '</ol>';
    return result;
}

function constructPitchCategories(pitches, reading, rules) {
    if (!pitches?.length) {
        return '';
    }
    
    const verbOrAdj = isVerbOrAdjective(rules);
    const categories = [];
    pitches.forEach(pitchGroup => {
        pitchGroup.pitchPositions.forEach(pos => {
            const category = getPitchCategory(reading, pos, verbOrAdj);
            if (category && !categories.includes(category)) {
                categories.push(category);
            }
        });
    });
    return categories.join(',');
}

// https://github.com/yomidevs/yomitan/blob/d810b2f0842536d24ab82b6cd75d00841710e57b/ext/js/display/structured-content-generator.js#L64
function createDefinitionImage(data, dictionary, exporting = false) {
    const {
        path,
        width = 100,
        height = 100,
        preferredWidth,
        preferredHeight,
        title,
        pixelated,
        imageRendering,
        appearance,
        background,
        collapsed,
        collapsible,
        verticalAlign,
        border,
        borderRadius,
        sizeUnits,
        data: nodeData,
    } = data;
    
    const hasPreferredWidth = (typeof preferredWidth === 'number');
    const hasPreferredHeight = (typeof preferredHeight === 'number');
    const hasDimensions = (hasPreferredWidth || hasPreferredHeight || typeof data.width === 'number' || typeof data.height === 'number');
    const invAspectRatio = (
                            hasPreferredWidth && hasPreferredHeight ?
                            preferredHeight / preferredWidth :
                            height / width
                            );
    const usedWidth = (
                       hasPreferredWidth ?
                       preferredWidth :
                       (hasPreferredHeight ? preferredHeight / invAspectRatio : width)
                       );
    const effectiveSizeUnits = typeof sizeUnits === 'string' ? sizeUnits : null;
    const isSvg = /\.svg$/i.test(path);
    const useEmUnits = effectiveSizeUnits === 'em';

    const node = document.createElement(exporting ? 'span' : 'a');
    node.classList.add('gloss-image-link');
    if (!exporting) {
        node.target = '_blank';
        node.rel = 'noreferrer noopener';
    }
    
    const imageContainer = document.createElement('span');
    imageContainer.classList.add('gloss-image-container');
    node.appendChild(imageContainer);
    
    const aspectRatioSizer = document.createElement('span');
    aspectRatioSizer.classList.add('gloss-image-sizer');
    imageContainer.appendChild(aspectRatioSizer);
    
    const imageBackground = document.createElement('span');
    imageBackground.classList.add('gloss-image-background');
    imageContainer.appendChild(imageBackground);
    
    const overlay = document.createElement('span');
    overlay.classList.add('gloss-image-container-overlay');
    imageContainer.appendChild(overlay);
    
    node.dataset.path = path;
    node.dataset.dictionary = dictionary;
    node.dataset.hasAspectRatio = 'true';
    node.dataset.imageRendering = typeof imageRendering === 'string' ? imageRendering : (pixelated ? 'pixelated' : 'auto');
    node.dataset.appearance = typeof appearance === 'string' ? appearance : 'auto';
    node.dataset.background = typeof background === 'boolean' ? `${background}` : 'true';
    node.dataset.collapsed = typeof collapsed === 'boolean' ? `${collapsed}` : 'false';
    node.dataset.collapsible = typeof collapsible === 'boolean' ? `${collapsible}` : 'true';
    if (typeof verticalAlign === 'string') {
        node.dataset.verticalAlign = verticalAlign;
    }
    if (useEmUnits) {
        node.dataset.sizeUnits = effectiveSizeUnits;
    }
    
    aspectRatioSizer.style.paddingTop = `${invAspectRatio * 100}%`;
    
    if (typeof border === 'string') { imageContainer.style.border = border; }
    if (typeof borderRadius === 'string') { imageContainer.style.borderRadius = borderRadius; }
    console.log('[IMG_CREATE]', path, 'dims=' + hasDimensions, 'svg=' + isSvg, usedWidth + 'x' + (usedWidth * invAspectRatio) + (useEmUnits ? 'em' : 'px'));
    if (useEmUnits) {
        imageContainer.style.width = `${usedWidth}em`;
    } else if (!hasDimensions && isSvg) {
        node.dataset.hasAspectRatio = 'false';
        imageContainer.style.width = 'auto';
        imageContainer.style.minWidth = '1.2em';
        imageContainer.style.height = '1.2em';
        imageContainer.style.fontSize = 'inherit';
        imageContainer.style.lineHeight = '0';
        imageContainer.style.overflow = 'visible';
        aspectRatioSizer.style.display = 'none';
    } else {
        imageContainer.style.width = `${usedWidth}px`;
    }
    if (typeof title === 'string') {
        imageContainer.title = title;
    }

    if (!exporting) {
        const imageUrl = rewriteDictionaryMediaPath(path, dictionary);
        if (imageUrl === null) return node;
        enableDefinitionImagePreview(node, imageUrl, nodeData?.alt || title || '');
        const inlineSvg = !hasDimensions && isSvg;
        if (!inlineSvg && shouldRenderDefinitionImageToCanvas(path, appearance, usedWidth, invAspectRatio)) {
            imageContainer.appendChild(createDefinitionImageCanvas(imageUrl, nodeData?.alt || title || '', (canvas, sourceImage) => {
                renderDefinitionImageToCanvas(canvas, sourceImage, usedWidth, invAspectRatio, appearance);
            }));
        } else {
            const img = document.createElement('img');
            img.classList.add('gloss-image');
            img.alt = nodeData?.alt || title || '';
            if (inlineSvg) {
                img.style.height = '1.2em';
                img.style.width = 'auto';
                img.style.position = 'static';
                img.style.display = 'inline-block';
            }
            img.addEventListener('load', () => {
                const shouldUseNaturalPixels = !isSvg && img.naturalWidth > 0 && img.naturalHeight > 0 && (!useEmUnits || hasMismatchedNaturalAspectRatio(img, invAspectRatio));
                if (shouldUseNaturalPixels) {
                    if (!hasDimensions) {
                        imageContainer.style.width = `${Math.min(img.naturalWidth, window.innerWidth - 20)}px`;
                    } else if (hasMismatchedNaturalAspectRatio(img, invAspectRatio)) {
                        imageContainer.style.width = `${Math.min(img.naturalWidth, window.innerWidth - 20)}px`;
                    } else if (useEmUnits) {
                        imageContainer.style.width = `${usedWidth}px`;
                    }
                    aspectRatioSizer.style.paddingTop = `${(img.naturalHeight / img.naturalWidth) * 100}%`;
                    if (useEmUnits) {
                        delete node.dataset.sizeUnits;
                        node.style.maxWidth = '100%';
                        imageContainer.style.maxWidth = '100%';
                    }
                } else if (!hasDimensions && !isSvg) {
                    imageContainer.style.width = `${Math.min(img.naturalWidth, window.innerWidth - 20)}px`;
                    aspectRatioSizer.style.paddingTop = `${(img.naturalHeight / img.naturalWidth) * 100}%`;
                }
            }, {once: true});
            img.addEventListener('error', (e) => {
                console.log('[IMG_ERROR]', path, imageUrl);
                imageContainer.style.display = 'none';
            }, {once: true});
            img.src = imageUrl;
            imageContainer.appendChild(img);
        }
    } else {
        const alt = nodeData?.alt || title || '';
        const filename = (window.useAnkiConnect || window.embedMedia) ? getMediaFilename(dictionary, path) : null;
        const image = document.createElement(filename ? 'img' : 'span');
        image.classList.add('gloss-image');
        if (filename) {
            image.alt = alt;
            image.src = filename;
            if (useEmUnits) {
                const emSize = 14;
                const scaleFactor = 2 * window.devicePixelRatio;
                image.width = usedWidth * emSize * scaleFactor;
            } else {
                image.width = usedWidth;
            }
            image.height = image.width * invAspectRatio;
            applyImageStyles(node, imageContainer, aspectRatioSizer, imageBackground, image, filename, appearance, useEmUnits);
        } else {
            image.textContent = alt;
        }
        imageContainer.appendChild(image);
    }
    if (useEmUnits && !exporting) {
        node.style.maxWidth = 'none';
        imageContainer.style.maxWidth = 'none';
        const scrollWrapper = document.createElement('div');
        scrollWrapper.className = 'gloss-image-scroll';
        scrollWrapper.appendChild(node);
        return scrollWrapper;
    }
    return node;
}

// ai slop
function shouldRenderDefinitionImageToCanvas(path, appearance, usedWidth, invAspectRatio) {
    return /\.svg$/i.test(path) && appearance === 'monochrome' && usedWidth <= 4 && (usedWidth * invAspectRatio) <= 4;
}

function createDefinitionImageCanvas(imageUrl, alt, onLoad) {
    const canvas = document.createElement('canvas');
    canvas.classList.add('gloss-image');
    canvas.setAttribute('role', 'img');
    canvas.setAttribute('aria-label', alt);
    
    const sourceImage = new Image();
    sourceImage.addEventListener('load', () => {
        onLoad(canvas, sourceImage);
    }, {once: true});
    sourceImage.src = imageUrl;
    
    return canvas;
}

function renderDefinitionImageToCanvas(canvas, image, usedWidth, invAspectRatio, appearance) {
    const emSize = Number.parseFloat(getComputedStyle(document.documentElement).fontSize);
    const scaleFactor = Math.ceil(window.devicePixelRatio * 2);
    const pixelWidth = Math.round(usedWidth * emSize * scaleFactor);
    const pixelHeight = Math.round(usedWidth * emSize * invAspectRatio * scaleFactor);
    const maxCanvasSize = 128;
    const scale = Math.min(
                           1,
                           maxCanvasSize / Math.max(pixelWidth, pixelHeight),
                           Math.sqrt((maxCanvasSize * maxCanvasSize) / (pixelWidth * pixelHeight))
                           );
    
    canvas.style.width = '100%';
    canvas.style.height = '100%';
    canvas.width = Math.round(pixelWidth * scale);
    canvas.height = Math.round(pixelHeight * scale);
    
    const context = canvas.getContext('2d');
    if (!context) {
        return;
    }
    
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    
    if (appearance === 'monochrome') {
        context.globalCompositeOperation = 'source-in';
        context.fillStyle = document.documentElement.getAttribute('data-theme') === 'dark' ? '#ffffff' : '#000000';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.globalCompositeOperation = 'source-over';
    }
}

// https://github.com/yomidevs/yomitan/blob/c0abb9e98a15aeb6b6f8f6e2d91fe5e54240b54a/ext/js/data/anki-note-data-creator.js#L177-L221
function getFrequencyHarmonicRank(frequencies) {
    if (!frequencies || frequencies.length === 0) {
        return DEFAULT_HARMONIC_RANK;
    }
    
    const values = [];
    const seenDictionaries = new Set();
    frequencies.forEach(freqGroup => {
        const dictionary = freqGroup?.dictionary;
        if (dictionary && seenDictionaries.has(dictionary)) {
            return;
        }
        if (dictionary) {
            seenDictionaries.add(dictionary);
        }
        
        const firstFreq = freqGroup?.frequencies?.[0];
        if (!firstFreq) {
            return;
        }
        
        const displayValue = firstFreq.displayValue;
        if (displayValue != null) {
            const match = String(displayValue).match(/^\d+/);
            if (match) {
                const parsed = Number.parseInt(match[0], 10);
                if (parsed > 0) {
                    values.push(parsed);
                    return;
                }
            }
        }
        
        const val = firstFreq.value;
        if (val && val > 0) {
            values.push(val);
        }
    });
    
    if (values.length === 0) {
        return DEFAULT_HARMONIC_RANK;
    }
    
    const sumOfReciprocals = values.reduce((sum, val) => sum + (1 / val), 0);
    return String(Math.floor(values.length / sumOfReciprocals));
}

// Builds the Anki field payload for a popup entry. Shared by mineEntry (create)
// and updateEntry (overwrite the latest card) so both carry identical fields,
// media, and audio — no second render path to drift (TODO-270 D).
async function buildMinePayload(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const idx = entryIndex || 0;
    const furiganaPlain = constructFuriganaPlain(expression, reading);
    currentDictionaryMedia = new Map();
    const glossary = constructGlossaryHtml(idx);
    const freqHarmonicRank = getFrequencyHarmonicRank(frequencies);
    const frequenciesHtml = constructFrequencyHtml(frequencies);
    const singleGlossaries = constructSingleGlossaryHtml(idx);
    const dictionaryMedia = currentDictionaryMedia;
    currentDictionaryMedia = null;
    const glossaryFirst = Object.values(singleGlossaries)[0] || '';
    const pitchPositions = constructPitchPositionHtml(pitches);
    const pitchCategories = constructPitchCategories(pitches, reading, rules);

    const audioReading = reading || expression;
    let audio = '';
    if (window.audioSources?.length && window.needsAudio) {
        audio = await resolveCachedAudioUrl(expression, audioReading, idx);
    } else {
        const cached = audioUrls[idx];
        if (cached?.key === audioCacheKey(expression, audioReading)) {
            audio = cached.url;
        }
    }

    return {
        expression,
        reading,
        matched,
        furiganaPlain,
        frequenciesHtml,
        freqHarmonicRank,
        glossary,
        glossaryFirst,
        singleGlossaries: JSON.stringify(singleGlossaries),
        pitchPositions,
        pitchCategories,
        popupSelectionText,
        audio,
        selectedDictionary: selectedDictionaries[idx]?.name || '',
        dictionaryMedia: JSON.stringify([...dictionaryMedia.values()])
    };
}

async function mineEntry(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const payload = await buildMinePayload(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
    return await window.flutter_inappwebview.callHandler('mineEntry', payload);
}

// TODO-270 D: overwrite an EXISTING card ([noteId]) in place with freshly-built
// fields (same payload as mineEntry). Used by the green ✓⤺ "latest editable"
// state so "I mined the wrong content, fix the last card" truly updates that
// note instead of creating a second one.
async function updateEntry(noteId, expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const fields = await buildMinePayload(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
    return await window.flutter_inappwebview.callHandler('updateEntry', { noteId, fields });
}

const INLINE_HTML_RE = /<(?:ruby|rt|rp|b|i|em|strong|span|sup|sub|br)\b[^>]*>/i;
const URL_RE = /(?:https?:\/\/|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|org|net|edu|gov|io|dev|app|jp|uk|de|fr|info|me|co)\/)[^\s<>　，、。！））)]+/gi;
const SAFE_TAGS = new Set(['ruby','rt','rp','b','i','em','strong','span','sup','sub','br','a']);

function sanitizeHtml(html) {
    const parser = new DOMParser();
    const doc = parser.parseFromString(html, 'text/html');
    doc.querySelectorAll('script,iframe,object,embed,form,meta,link,style,svg,math').forEach(el => el.remove());
    doc.querySelectorAll('*').forEach(el => {
        for (const attr of [...el.attributes]) {
            if (attr.name.startsWith('on') || attr.name === 'srcdoc' ||
                (attr.name === 'href' && /^\s*(javascript|data):/i.test(attr.value)) ||
                (attr.name === 'src' && /^\s*(javascript|data):/i.test(attr.value))) {
                el.removeAttribute(attr.name);
            }
        }
    });
    return doc.body.innerHTML;
}

function sanitizeInlineHtml(html) {
    const tmp = document.createElement('div');
    tmp.innerHTML = sanitizeHtml(html);
    tmp.querySelectorAll('*').forEach(el => {
        const tag = el.tagName.toLowerCase();
        if (!SAFE_TAGS.has(tag)) {
            el.replaceWith(...el.childNodes);
            return;
        }
        [...el.attributes].forEach(attr => {
            if (attr.name.startsWith('on') || attr.name === 'style' && /expression|javascript/i.test(attr.value)) {
                el.removeAttribute(attr.name);
            }
        });
    });
    return tmp.innerHTML;
}

function linkifyUrls(html) {
    return html.replace(URL_RE, url => {
        const href = /^https?:\/\//i.test(url) ? url : 'https://' + url;
        if (/^\s*(javascript|data|vbscript):/i.test(href)) return url;
        const escapedHref = href.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        const escapedText = url.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        return `<a href="${escapedHref}">${escapedText}</a>`;
    });
}

function appendRichTextLine(parent, line) {
    const hasHtml = INLINE_HTML_RE.test(line);
    const hasUrl = URL_RE.test(line);
    URL_RE.lastIndex = 0;
    if (!hasHtml && !hasUrl) {
        parent.appendChild(document.createTextNode(line));
        return;
    }
    let html = hasHtml ? sanitizeInlineHtml(line) : line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    if (hasUrl || URL_RE.test(html)) {
        URL_RE.lastIndex = 0;
        const tmp2 = document.createElement('div');
        tmp2.innerHTML = html;
        const walker = document.createTreeWalker(tmp2, NodeFilter.SHOW_TEXT);
        const textNodes = [];
        while (walker.nextNode()) textNodes.push(walker.currentNode);
        textNodes.forEach(tn => {
            if (URL_RE.test(tn.textContent)) {
                URL_RE.lastIndex = 0;
                const span = document.createElement('span');
                span.innerHTML = linkifyUrls(tn.textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'));
                tn.replaceWith(...span.childNodes);
            }
        });
        html = tmp2.innerHTML;
    }
    if (hasHtml) {
        console.log('[RICHTEXT_HTML] input=' + line.substring(0, 150) + ' | sanitized=' + html.substring(0, 150));
    }
    const frag = document.createElement('span');
    frag.innerHTML = html;
    while (frag.firstChild) parent.appendChild(frag.firstChild);
}

function renderStructuredContent(parent, node, language = null, dictName = null, exporting = false) {
    if (typeof node === 'string') {
        node.split(/\r?\n/).forEach((line, i) => {
            if (i > 0) {
                parent.appendChild(document.createElement('br'));
            }
            if (line) {
                if (!language && !parent.hasAttribute('lang')) {
                    const detected = getLanguageFromText(line, language);
                    if (detected) {
                        parent.setAttribute('lang', detected);
                    }
                }
                appendRichTextLine(parent, line);
            }
        });
        return;
    }
    
    if (Array.isArray(node)) {
        // Yomitan "form-of"/non-lemma glossary: an array of [term, [tag, ...]]
        // pairs (e.g. wty-ja-en alt-of entries arrive as
        // [["时",["Hyōgai"]],["时",["alt-of"]],...]). The generic flattening
        // below would emit bare adjacent text nodes with no spacing or styling
        // → "时Hyōgai时alt-of时alternative时kanji", which reads as mojibake
        // (BUG-057). Render each pair as its own line: term + tag chips.
        if (node.length > 0 && node.every(isTaggedTermPair)) {
            renderTaggedTermPairs(parent, node);
            return;
        }

        const isStringArray = node.every(item => typeof item === 'string');
        const insideSpan = parent.tagName === 'SPAN';
        if (isStringArray && node.length > 1 && !insideSpan) {
            const ul = document.createElement('ul');
            ul.classList.add('glossary-list');
            node.forEach(child => {
                const li = document.createElement('li');
                appendRichTextLine(li, child);
                ul.appendChild(li);
            });
            parent.appendChild(ul);
            return;
        }
        
        const items = node.map(item =>
                               item?.type === 'structured-content' ? item.content : item
                               );
        const isLinkArray = items.every(item => item?.tag === 'a');
        if (isLinkArray && node.length > 1) {
            const ul = document.createElement('ul');
            ul.classList.add('glossary-list');
            node.forEach(child => {
                const li = document.createElement('li');
                renderStructuredContent(li, child, language, dictName, exporting);
                ul.appendChild(li);
            });
            parent.appendChild(ul);
            return;
        }
        
        node.forEach(child => renderStructuredContent(parent, child, language, dictName, exporting));
        return;
    }
    
    if (!node || typeof node !== 'object') {
        return;
    }
    
    if (node.type === 'structured-content') {
        const container = document.createElement('span');
        container.classList.add('structured-content');
        parent.appendChild(container);
        renderStructuredContent(container, node.content, language, dictName, exporting);
        return;
    }
    
    if (node.tag === 'img' || node.type === 'image') {
        parent.appendChild(createDefinitionImage(node, dictName, exporting));
        return;
    }
    
    const tagName = node.tag || 'span';
    const element = document.createElement(tagName);
    element.classList.add(`gloss-sc-${tagName}`);
    let nextLanguage = language;
    
    if (node.href) {
        element.setAttribute('href', node.href);
        const isExternal = /^https?:\/\//i.test(node.href);
        element.onclick = (e) => {
            e.preventDefault();
            e.stopPropagation();
            if (isExternal) {
                openExternalLink(node.href);
            } else {
                const query = node.href.indexOf('?') >= 0
                    ? new URLSearchParams(node.href.substring(node.href.indexOf('?'))).get('query') || element.textContent || ''
                    : element.textContent || '';
                const rect = element.getBoundingClientRect();
                window.flutter_inappwebview.callHandler('onLinkClick', query, {
                    x: rect.left,
                    y: rect.top,
                    width: rect.width,
                    height: rect.height
                });
            }
        };
    }
    
    if (node.title) {
        element.setAttribute('title', node.title);
    }
    
    if (node.lang) {
        element.setAttribute('lang', node.lang);
        nextLanguage = node.lang;
    }
    
    if (node.data) {
        // this is necessary to fix formatting in dicts like daijisen
        for (const [k, v] of Object.entries(node.data)) {
            const isCJK = /^[\u3000-\u9FFF\uF900-\uFAFF]/.test(k);
            element.setAttribute(`data-sc${isCJK ? '' : '-'}${toKebabCase(k)}`, v);
        }
    }
    
    if (node.style) {
        setStructuredContentElementStyle(element, node.style);
    }
    
    if (node.content) {
        renderStructuredContent(element, node.content, nextLanguage, dictName, exporting);
    }
    
    if (node.colSpan) {
        element.setAttribute('colspan', node.colSpan);
    }
    
    if (node.rowSpan) {
        element.setAttribute('rowspan', node.rowSpan);
    }
    
    if (tagName === 'table') {
        const container = document.createElement('div');
        container.classList.add('gloss-sc-table-container');
        container.appendChild(element);
        parent.appendChild(container);
        return;
    }
    
    parent.appendChild(element);
}

function isPartOfSpeech(tag) {
    return POS_TAGS.has(tag) || tag.startsWith('v5');
}

function parseTags(raw) {
    return (raw || '').split(' ').filter(Boolean);
}

function createGlossaryTags(tags, className = 'glossary-tags') {
    if (!tags?.length) {
        return null;
    }
    return el('div', { className }, tags.map(tag => el('span', { className: 'glossary-tag', textContent: tag })));
}

// True for a Yomitan "form-of" glossary item: a [term, [tag, ...]] pair where
// the term is a string and the tags are an array of strings. See the array
// branch of renderStructuredContent (BUG-057).
function isTaggedTermPair(item) {
    return Array.isArray(item)
        && item.length === 2
        && typeof item[0] === 'string'
        && Array.isArray(item[1])
        && item[1].every(tag => typeof tag === 'string');
}

// Renders an array of [term, [tag, ...]] pairs as a readable list: each pair on
// its own line with the referenced term followed by its tag chips. Replaces the
// generic flattening that produced unspaced "时Hyōgai时alt-of…" mojibake.
function renderTaggedTermPairs(parent, pairs) {
    const list = el('div', { className: 'form-of-list' });
    pairs.forEach(([term, tags]) => {
        const item = el('div', { className: 'form-of-item' });
        const termEl = el('span', { className: 'form-of-term', textContent: term });
        termEl.style.marginRight = '4px';
        item.appendChild(termEl);
        const tagRow = createGlossaryTags(tags, 'glossary-tags form-of-tags');
        if (tagRow) {
            item.appendChild(tagRow);
        }
        list.appendChild(item);
    });
    parent.appendChild(list);
}

function createDeinflectionTag(tag) {
    return el('span', {
        className: 'deinflection-tag',
        textContent: tag.name,
        'data-description': tag.description,
        onclick() {
            showDescription(this);
        }
    });
}

function createFrequencyGroup(freqGroup) {
    const values = freqGroup.frequencies.map(f => f.displayValue || f.value).join(', ');
    return el('span', { className: 'frequency-group', 'data-details': freqGroup.dictionary }, [
        el('span', { className: 'frequency-dict-label', textContent: freqGroup.dictionary }),
        el('span', { className: 'frequency-values', textContent: values })
    ]);
}

function createHarmonicFrequencyTag(frequencies) {
    const rank = getFrequencyHarmonicRank(frequencies);
    return el('span', { className: 'frequency-group harmonic-frequency' }, [
        el('span', { className: 'frequency-dict-label', textContent: 'avg' }),
        el('span', { className: 'frequency-values', textContent: rank })
    ]);
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L350
function isMoraPitchHigh(moraIndex, pitchAccentValue) {
    switch (pitchAccentValue) {
        case 0: return (moraIndex > 0);
        case 1: return (moraIndex < 1);
        default: return (moraIndex > 0 && moraIndex < pitchAccentValue);
    }
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L406
function getKanaMorae(text) {
    const morae = [];
    let i;
    for (const c of text) {
        if (SMALL_KANA_SET.has(c) && (i = morae.length) > 0) {
            morae[i - 1] += c;
        } else {
            morae.push(c);
        }
    }
    return morae;
}

// this might be unreliable
function isVerbOrAdjective(rules) {
    return rules?.some(tag => tag.startsWith('v') || tag.startsWith('adj-i')) ?? false;
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/language/ja/japanese.js#L366
function getPitchCategory(reading, pitchAccentValue, verbOrAdjective = false) {
    if (pitchAccentValue === 0) {
        return 'heiban';
    }
    if (verbOrAdjective) {
        return pitchAccentValue > 0 ? 'kifuku' : null;
    }
    if (pitchAccentValue === 1) {
        return 'atamadaka';
    }
    if (pitchAccentValue > 1) {
        const moraCount = getKanaMorae(reading).length;
        return pitchAccentValue >= moraCount ? 'odaka' : 'nakadaka';
    }
    return null;
}

// https://github.com/yomidevs/yomitan/blob/c24d4c9b39ceec1b5fd133df774c41972e9ebbdc/ext/js/display/pronunciation-generator.js#L38
function createPitchHtml(reading, pitchValue) {
    const morae = getKanaMorae(reading);
    const container = el('span', { className: 'pronunciation-text' });
    
    for (let i = 0; i < morae.length; i++) {
        const mora = morae[i];
        const isHigh = isMoraPitchHigh(i, pitchValue);
        const isHighNext = isMoraPitchHigh(i + 1, pitchValue);
        
        const moraSpan = el('span', {
            className: 'pronunciation-mora',
            'data-pitch': isHigh ? 'high' : 'low',
            'data-pitch-next': isHighNext ? 'high' : 'low',
            textContent: mora
        });
        
        moraSpan.appendChild(el('span', { className: 'pronunciation-mora-line' }));
        container.appendChild(moraSpan);
    }
    
    return container;
}

function createPitchGroup(pitchData, reading) {
    const container = el('div', { className: 'pitch-group', 'data-details': pitchData.dictionary });
    container.appendChild(el('span', { className: 'pitch-dict-label', textContent: pitchData.dictionary }));
    
    const list = el('ul', { className: 'pitch-entries' });
    pitchData.pitchPositions.forEach((pitch) => {
        const li = el('li');
        li.appendChild(createPitchHtml(reading, pitch));
        li.appendChild(document.createTextNode(` [${pitch}]`));
        list.appendChild(li);
    });
    container.appendChild(list);
    
    return container;
}

function createExpressionTagsSection(entry) {
    if (!window.showExpressionTags) return null;
    const container = el('div', { className: 'entry-tags' });
    const row = el('div', { className: 'tag-row expr-tag-row' });
    row.appendChild(el('span', { className: 'expr-tag', textContent: entry.expression }));
    if (entry.reading && entry.reading !== entry.expression) {
        row.appendChild(el('span', { className: 'expr-tag', textContent: entry.reading }));
    }
    container.appendChild(row);
    return container;
}

function createDeinflectionSection(entry) {
    const { deinflectionTrace } = entry;
    if (!deinflectionTrace?.length) return null;
    const container = el('div', { className: 'entry-tags' });
    const row = el('div', { className: 'tag-row' });
    deinflectionTrace.forEach(tag => row.appendChild(createDeinflectionTag(tag)));
    container.appendChild(row);
    return container;
}

function createFrequencySection(frequencies) {
    if (!frequencies?.length) return null;
    const section = el('div', { className: 'category-section frequency-section' });
    const body = el('div', { className: 'category-body' });
    if (window.harmonicFrequency) {
        const normalRow = el('div', { className: 'tag-row', style: 'display:none' });
        frequencies.forEach(freq => normalRow.appendChild(createFrequencyGroup(freq)));
        const harmonicRow = el('div', { className: 'tag-row' });
        harmonicRow.appendChild(createHarmonicFrequencyTag(frequencies));
        const toggle = () => {
            const swap = harmonicRow.style.display !== 'none';
            harmonicRow.style.display = swap ? 'none' : '';
            normalRow.style.display = swap ? '' : 'none';
        };
        normalRow.addEventListener('click', toggle);
        harmonicRow.addEventListener('click', toggle);
        body.appendChild(harmonicRow);
        body.appendChild(normalRow);
    } else {
        const row = el('div', { className: 'tag-row' });
        frequencies.forEach(freq => row.appendChild(createFrequencyGroup(freq)));
        body.appendChild(row);
    }
    section.appendChild(body);
    return section;
}

function createPitchSection(pitches, reading) {
    if (!pitches?.length) return null;
    const section = el('div', { className: 'category-section pitch-section' });
    const body = el('div', { className: 'category-body' });
    const pitchContainer = el('div', { className: 'pitch-list' });
    if (window.deduplicatePitchAccents) {
        const seen = new Set();
        pitches.forEach(pitch => {
            const unique = pitch.pitchPositions.filter(pos => !seen.has(pos));
            if (unique.length > 0) {
                unique.forEach(pos => seen.add(pos));
                pitchContainer.appendChild(createPitchGroup({ dictionary: pitch.dictionary, pitchPositions: unique }, reading));
            }
        });
    } else {
        pitches.forEach(pitch => pitchContainer.appendChild(createPitchGroup(pitch, reading)));
    }
    body.appendChild(pitchContainer);
    section.appendChild(body);
    return section;
}

function createGlossarySectionWrapper(entry) {
    const grouped = {};
    entry.glossaries.forEach(g => {
        (grouped[g.dictionary] ??= []).push({
            content: g.content,
            definitionTags: g.definitionTags,
            termTags: g.termTags
        });
    });
    const dictNames = Object.keys(grouped);
    if (!dictNames.length) return null;
    const section = el('div', { className: 'category-section glossary-section' });
    const body = el('div', { className: 'category-body' });
    section.appendChild(body);
    return { details: section, body, grouped, dictNames };
}

async function fetchAudioUrl(expression, reading) {
    try {
        return await window.flutter_inappwebview.callHandler(
            'resolveWordAudio', { expression, reading });
    } catch {
        return null;
    }
}

async function playWordAudio(audioUrl) {
    try {
        return await window.flutter_inappwebview.callHandler('playWordAudio', {
            url: audioUrl,
            mode: window.audioPlaybackMode || 'interrupt'
        });
    } catch {
        return false;
    }
}

function showAudioError(button) {
    button.textContent = '✕';
    setTimeout(() => {
        button.textContent = '♪';
    }, 1500);
}

function createAudioButton(expression, reading, entryIndex) {
    const button = el('button', {
        className: 'audio-button',
        textContent: '♪',
        onclick: async () => {
            const audioUrl = await resolveCachedAudioUrl(expression, reading || expression, entryIndex);
            if (!audioUrl) {
                showAudioError(button);
                return;
            }
            if (!await playWordAudio(audioUrl)) {
                showAudioError(button);
            }
        }
    });
    return button;
}

function createKanjiBreakdown(expression) {
    const seen = new Set();
    const kanjiChars = [];
    for (const ch of expression) {
        if (KANJI_PATTERN.test(ch) && !seen.has(ch)) {
            seen.add(ch);
            kanjiChars.push(ch);
        }
    }
    if (kanjiChars.length === 0) return null;

    const row = el('div', { className: 'kanji-breakdown' });
    for (const ch of kanjiChars) {
        const tag = el('span', {
            className: 'kanji-tag',
            textContent: ch,
        });
        tag.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const rect = tag.getBoundingClientRect();
            window.flutter_inappwebview.callHandler('onLinkClick', ch, {
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height
            });
        });
        row.appendChild(tag);
    }
    return row;
}

function createEntryHeader(entry, idx) {
    const { expression, reading, matched, frequencies, pitches, rules } = entry;
    const header = el('div', { className: 'entry-header' });
    
    const expressionSpan = el('span', { className: 'expression' });
    let needsScroll = false;
    if (reading && reading !== expression) {
        needsScroll = buildFuriganaEl(expressionSpan, expression, reading);
    } else {
        expressionSpan.textContent = expression;
    }
    expressionSpan.style.cursor = 'pointer';
    expressionSpan.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const rect = expressionSpan.getBoundingClientRect();
        window.flutter_inappwebview.callHandler('onLinkClick', expression, {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height
        });
    });
    if (needsScroll) {
        const expressionScroll = el('div', { className: 'expression-scroll' });
        expressionScroll.appendChild(expressionSpan);
        header.appendChild(expressionScroll);
    } else {
        header.appendChild(expressionSpan);
    }
    
    const buttonsContainer = el('div', { className: 'header-buttons' });
    
    if (window.audioSources?.length) {
        buttonsContainer.appendChild(createAudioButton(expression, reading, idx));
    }

    // BUG-185 (TODO-084/087): the mine button's "已制卡 ✓ / 可制卡 +" state is
    // DETECTED AT LOOKUP TIME and reflects Anki's REAL card existence.
    //
    // PRIMARY MECHANISM — detection at lookup time:
    //   When the popup renders this word (createEntryHeader runs as part of
    //   renderPopup, which rebuilds the DOM on every lookup), the initial
    //   `duplicateCheck` below queries Anki live (AnkiConnect findNotes /
    //   AnkiDroid findDuplicateNotes — both already real-time) and sets a real
    //   `data-mined` state: card in Anki → 已制卡 ✓; card absent → 可制卡 +.
    //   `data-mined` is the source of truth for what a click does, so the ✓ is
    //   NOT decorative — it means "Anki has this card right now".
    //
    //   TODO-084 (re-look-up the word after deleting its card in Anki) is
    //   satisfied for free: a fresh lookup re-renders → re-runs this detection →
    //   card is gone → 可制卡 → can re-mine.
    //
    // EDGE-CASE FALLBACK — same popup, card deleted in Anki WITHOUT re-looking
    //   up (TODO-087): a click on the 已制卡 ✓ button re-verifies against Anki
    //   first; if the card is genuinely gone it re-mines, if it still exists
    //   (dupes off) it just refreshes ✓ and adds nothing. This is a safety net
    //   for stale state, not the primary path.
    //
    // TODO-270 D — THIRD STATE "latest editable": the single most-recently-mined
    //   word (whose backend returned a real note id, AnkiConnect only) shows a
    //   GREEN ✓ with an undo glyph (✓⤺) instead of an ordinary ✓. Clicking it
    //   OVERWRITES that card (updateEntry → repo.updateMinedNote) so a mistake on
    //   the last card is fixed in place — no delete-then-recreate. Mining another
    //   word, or re-querying, supersedes it back to an ordinary ✓ (only the most
    //   recent card stays editable). AnkiDroid returns no id → never green ✓⤺.
    const setMineState = (isMined) => {
        // Single source of truth for the button's lookup-time-detected state.
        // The optional second flag is the "latest editable" sub-state; it is only
        // meaningful when the word is the current latest-mined card.
        const latest = isMined && isLatestEditable(expression, reading);
        mineButton.dataset.mined = isMined ? '1' : '';
        mineButton.dataset.latest = latest ? '1' : '';
        mineButton.textContent = isMined ? (latest ? '✓↩' : '✓') : '+';
        if (isMined) {
            mineButton.classList.add('duplicate');
        } else {
            mineButton.classList.remove('duplicate');
        }
        if (latest) {
            mineButton.classList.add('latest');
        } else {
            mineButton.classList.remove('latest');
        }
    };
    const mineButton = el('button', {
        className: 'mine-button',
        textContent: '+',
        ontouchstart: () => {
            lastSelection = window.getSelection()?.toString() || '';
        },
        onclick: async () => {
            // Single-flight guard against double-firing one click. Always cleared
            // in finally — it is the ONLY thing that disables the button, never a
            // permanent lock (BUG-077).
            if (mineButton.dataset.mining === '1') return;
            mineButton.dataset.mining = '1';
            mineButton.disabled = true;
            try {
                if (mineButton.dataset.latest === '1' && isLatestEditable(expression, reading)) {
                    // TODO-270 D green ✓⤺: this is the latest mined card and it
                    // carries a real note id → OVERWRITE that note in place with
                    // the freshly-built fields (does NOT create a second card).
                    const reply = await updateEntry(
                        lastMinedNoteId, expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
                    const result = parseMineResult(reply);
                    // A successful update keeps the same note id (handler echoes it)
                    // → stays the editable latest. A failed update drops the latest
                    //   flag back to a plain ✓ (the card is still mined).
                    rememberLatestMined(expression, reading, result.noteId);
                    setMineState(true);
                    return;
                }

                if (mineButton.dataset.mined === '1') {
                    // Button shows 已制卡 ✓ (detected mined at lookup time). The
                    // only reason to click it is the TODO-087 edge case: the card
                    // may have been deleted in Anki since, with no re-lookup. So
                    // re-verify against Anki before doing anything.
                    const stillExists = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                    if (stillExists && !window.allowDupes) {
                        // Still really in Anki, dupes off → keep 已制卡, add nothing.
                        setMineState(true);
                        return;
                    }
                    // Deleted in Anki (or dupes allowed) → fall through and re-mine.
                }

                const reply = await mineEntry(expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
                const result = parseMineResult(reply);
                // TODO-393：制卡后宿主清空草稿（合并卡已落地），同步把 JS 两个镜像标量
                // 归零并刷新上下文选择器，使两端状态在同一事件归零、不漂移。仅在启用草稿
                // 的表面才动 DOM（纯查词页未接入时不渲染上下文选择器）。
                if (window.sentenceDraftEnabled) {
                    sentenceCtxPrev = 0;
                    sentenceCtxNext = 0;
                    sentenceDraftCount = 0;
                    refreshAllSentenceContextPickers();
                }
                const refreshFromAnki = async () => {
                    // Re-detect from Anki so the post-mine state is the real one.
                    const wasAdded = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                    setMineState(wasAdded);
                };

                if (result.ankiConnect) {
                    // TODO-270 D: a freshly mined card with a real note id becomes
                    // the new "latest editable"; this also supersedes any prior
                    // latest word (only one editable card at a time).
                    rememberLatestMined(expression, reading, result.noteId);
                    await refreshFromAnki();
                } else {
                    setTimeout(refreshFromAnki, 1000);
                }
            } catch (e) {
                // BUG-077: a rejected mineEntry/duplicateCheck (Dart handler threw,
                // or a JS payload-builder error) must never leave the button stuck
                // disabled showing '+' with no feedback. Restore it to a clickable
                // 可制卡 + so the user sees it failed and can retry.
                console.error('mine button: mineEntry failed', e);
                setMineState(false);
            } finally {
                // The single-flight guard is ALWAYS released; the button's
                // long-term enabled/disabled is driven only by data-mined, never
                // stuck disabled.
                mineButton.dataset.mining = '';
                mineButton.disabled = false;
            }
        }
    });
    buttonsContainer.appendChild(mineButton);
    // Lookup-time detection: query Anki's real card existence for THIS word as
    // the popup renders it, and set the accurate 已制卡 ✓ / 可制卡 + state.
    window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading }).then(isDuplicate => {
        setMineState(isDuplicate);
    });

    // TODO-393「查词窗口句子上下文制卡」：仅支持草稿的表面（书籍/有声书/视频；宿主接受
    // setSentenceContext）渲染「上 N 句 / 下 N 句」上下文选择器。选「上 N」「下 N」把当前
    // 句前/后 N 句作上下文整体设进宿主草稿；紧挨的「×」清空回到只制当前句。不碰 mineEntry
    // 字段契约——只发上下文信号。
    if (window.sentenceDraftEnabled) {
        const picker = buildSentenceContextPicker();
        refreshSentenceContextPicker(picker);
        buttonsContainer.appendChild(picker);

        // TODO-382/393 可撤销：「清空已加句子」按钮（仅已选上下文时显示）。点一次把上下文
        // 句数归零（回到只制当前句），所有选择器同步——明确、可见的撤销入口。
        const clearButton = el('button', {
            className: 'clear-draft-button',
            textContent: '×',
            onclick: async () => {
                if (clearButton.dataset.busy === '1') return;
                clearButton.dataset.busy = '1';
                clearButton.disabled = true;
                try {
                    sentenceCtxPrev = 0;
                    sentenceCtxNext = 0;
                    sentenceDraftCount = await clearSentenceDraftOnHost();
                    refreshAllSentenceContextPickers();
                } finally {
                    clearButton.dataset.busy = '';
                    clearButton.disabled = false;
                }
            },
        });
        refreshClearDraftButton(clearButton);
        buttonsContainer.appendChild(clearButton);
    }

    header.appendChild(buttonsContainer);
    
    return header;
}

window.hoshiPopupMineFirstEntry = async function() {
    const mineButton = document.querySelector('.mine-button');
    if (!mineButton || mineButton.disabled) {
        return false;
    }
    mineButton.click();
    return true;
};

function createGlossarySection(dictName, contents, isFirst, entryIdx) {
    const details = el('details', { className: 'glossary-group' });
    const perDictCollapsed = (window.collapsedDictionaryNames || []).includes(dictName);
    if (isFirst || (!window.collapseDictionaries && !perDictCollapsed)) {
        details.open = true;
    }

    const summary = el('summary', { className: 'dict-label' });
    summary.appendChild(el('span', { className: 'dict-name', textContent: dictName }));
    details.appendChild(summary);

    let longPressTimer = null;
    let longPressed = false;
    const toggleSelection = () => {
        longPressed = true;
        const selected = selectedDictionaries[entryIdx];
        selected?.label.classList.remove('selected');
        if (selected?.name === dictName) {
            delete selectedDictionaries[entryIdx];
        } else {
            selectedDictionaries[entryIdx] = { name: dictName, label: summary };
            summary.classList.add('selected');
        }
    };
    summary.__hoshiToggleSelection = toggleSelection;
    window.__hoshiDictLongPress = (summaryEl) => {
        const toggle = summaryEl?.__hoshiToggleSelection;
        if (typeof toggle !== 'function') return false;
        toggle();
        return true;
    };
    summary.addEventListener('touchstart', (e) => {
        longPressed = false;
        longPressTimer = setTimeout(toggleSelection, 500);
    }, { passive: true });
    summary.addEventListener('touchend', () => {
        clearTimeout(longPressTimer);
        if (longPressed) event?.preventDefault?.();
    });
    summary.addEventListener('touchmove', () => clearTimeout(longPressTimer));
    summary.addEventListener('mousedown', () => {
        longPressed = false;
        longPressTimer = setTimeout(toggleSelection, 500);
    });
    summary.addEventListener('mouseup', () => clearTimeout(longPressTimer));
    summary.addEventListener('mouseleave', () => clearTimeout(longPressTimer));
    
    const dictWrapper = document.createElement('div');
    dictWrapper.setAttribute('data-dictionary', dictName);
    const compactCss = window.compactGlossaries ? `
        ul[data-sc-content="glossary"],
        ol[data-sc-content="glossary"],
        .glossary-list {
            list-style: none;
            padding-left: 0;
            margin: 0;
        }
        ul[data-sc-content="glossary"] > li,
        ol[data-sc-content="glossary"] > li,
        .glossary-list > li {
            display: inline;
        }
        ul[data-sc-content="glossary"] > li::after,
        ol[data-sc-content="glossary"] > li::after,
        .glossary-list > li::after {
            content: " | ";
            opacity: 0.6;
        }
        ul[data-sc-content="glossary"] > li:last-child::after,
        ol[data-sc-content="glossary"] > li:last-child::after,
        .glossary-list > li:last-child::after {
            content: "";
        }
    ` : '';
    
    const dictStyle = window.dictionaryStyles?.[dictName] ?? '';
    let styleText = `
        [data-dictionary="${dictName}"] {
            color: var(--text-color);
            ${compactCss}
        }
    `.trim();
    if (dictStyle) {
        styleText += '\n' + constructDictCss(dictStyle, dictName);
    }
    dictWrapper.appendChild(el('style', { textContent: styleText }));
    
    const termTags = [...new Set(parseTags(contents[0]?.termTags))];
    const renderContent = (parent, content) => {
        if (typeof content === 'string') {
            try {
                renderStructuredContent(parent, JSON.parse(content), null, dictName);
            } catch {
                if (/<[a-z][\s\S]*>/i.test(content)) {
                    const wrapper = el('div');
                    wrapper.innerHTML = rewriteDictLinks(content, dictName);
                    parent.appendChild(wrapper);
                } else {
                    renderStructuredContent(parent, content, null, dictName);
                }
            }
        } else {
            renderStructuredContent(parent, content, null, dictName);
        }
    };
    
    const termTagsRow = createGlossaryTags(termTags);
    if (termTagsRow) {
        dictWrapper.appendChild(termTagsRow);
    }
    
    if (contents.length > 1) {
        const ol = el('ol');
        let prevTags = null;
        contents.forEach((item) => {
            const li = el('li');
            const parsedTags = parseTags(item.definitionTags).filter(tag => !NUMERIC_TAG.test(tag));
            const posTags = [...new Set(parsedTags.filter(isPartOfSpeech))].sort();
            const currentTags = JSON.stringify(posTags);
            const filteredTags = parsedTags.filter(tag => !isPartOfSpeech(tag) || !(prevTags !== null && prevTags === currentTags));
            const tags = createGlossaryTags(filteredTags);
            if (tags) {
                li.appendChild(tags);
            }
            const content = el('div', { className: 'glossary-content' });
            renderContent(content, item.content);
            li.appendChild(content);
            ol.appendChild(li);
            prevTags = currentTags;
        });
        dictWrapper.appendChild(ol);
    } else {
        contents.forEach((item, idx) => {
            const wrapper = el('div');
            const tags = createGlossaryTags(parseTags(item.definitionTags).filter(tag => !NUMERIC_TAG.test(tag)));
            if (tags) {
                wrapper.appendChild(tags);
            }
            const content = el('div', { className: 'glossary-content' });
            renderContent(content, item.content);
            wrapper.appendChild(content);
            dictWrapper.appendChild(wrapper);
        });
    }
    
    details.appendChild(dictWrapper);
    return details;
}

function buildEntryElement(entry, idx) {
    const entryDiv = el('div', { className: 'entry' });
    entryDiv.appendChild(createEntryHeader(entry, idx));

    const kanjiRow = createKanjiBreakdown(entry.expression);
    if (kanjiRow) {
        entryDiv.appendChild(kanjiRow);
    }

    const exprTags = createExpressionTagsSection(entry);
    if (exprTags) {
        entryDiv.appendChild(exprTags);
    }

    const deinflection = createDeinflectionSection(entry);
    if (deinflection) {
        entryDiv.appendChild(deinflection);
    }

    const freqSection = createFrequencySection(entry.frequencies);
    if (freqSection) {
        entryDiv.appendChild(freqSection);
    }

    const pitchSection = createPitchSection(entry.pitches, entry.reading);
    if (pitchSection) {
        entryDiv.appendChild(pitchSection);
    }

    const glossaryWrapper = createGlossarySectionWrapper(entry);
    if (glossaryWrapper) {
        const { details, body, grouped, dictNames } = glossaryWrapper;
        entryDiv.appendChild(details);
        for (let dictIdx = 0; dictIdx < dictNames.length; dictIdx++) {
            body.appendChild(createGlossarySection(dictNames[dictIdx], grouped[dictNames[dictIdx]], dictIdx === 0, idx));
        }
    }

    return entryDiv;
}

function postProcessRuby(container) {
    container.querySelectorAll('.glossary-content ruby').forEach(ruby => {
        ruby.childNodes.forEach(node => {
            if (node.nodeType === Node.TEXT_NODE && node.textContent.trim()) {
                const span = document.createElement('span');
                span.textContent = node.textContent;
                node.replaceWith(span);
            }
        });
    });
}

function applyCustomCSS() {
    document.querySelectorAll('style.hoshi-custom-css').forEach(el => el.remove());
    if (window.globalDictCSS) {
        const style = document.createElement('style');
        style.className = 'hoshi-custom-css';
        style.textContent = window.globalDictCSS;
        document.body.appendChild(style);
    }
    if (window.customDictCSS && typeof window.customDictCSS === 'object') {
        for (const [dictName, css] of Object.entries(window.customDictCSS)) {
            if (!css) continue;
            const style = document.createElement('style');
            style.className = 'hoshi-custom-css';
            style.textContent = constructDictCss(css, dictName);
            document.body.appendChild(style);
        }
    }
}

// TODO-094 S5: kanji dictionary card. A single-character lookup carries
// per-character kanji results (onyomi / kunyomi / radical / strokes / meanings)
// on window.kanjiResults, injected alongside window.lookupEntries by
// dictionary_popup_webview.dart. Rendered as its own card ABOVE the term
// entries so the reading/meaning of the character itself is visible even when
// the same character is also a term headword. Field names mirror
// HoshiKanjiResult.toMap (Dart). Empty / missing -> nothing rendered, so
// multi-char / kana / latin lookups are unaffected.
function createKanjiReadingRow(label, value) {
    if (!value) {
        return null;
    }
    const row = el('div', { className: 'kanji-card-row' });
    row.appendChild(el('span', { className: 'kanji-card-label', textContent: label }));
    row.appendChild(el('span', { className: 'kanji-card-value', textContent: value }));
    return row;
}

function createKanjiCard(kanji) {
    if (!kanji || !kanji.character) {
        return null;
    }
    const card = el('div', { className: 'kanji-card' });

    const head = el('div', { className: 'kanji-card-head' });
    const charEl = el('div', { className: 'kanji-card-char', textContent: kanji.character });
    // Tapping the big character re-looks it up (consistent with the term
    // headword + kanji-breakdown tags), so a kanji card is also a jump-off
    // point for a fresh lookup.
    charEl.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const rect = charEl.getBoundingClientRect();
        window.flutter_inappwebview.callHandler('onLinkClick', kanji.character, {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height
        });
    });
    head.appendChild(charEl);

    const headMeta = el('div', { className: 'kanji-card-meta' });
    const radicalRow = createKanjiReadingRow(window._kanjiLabels?.radical || 'Radical', kanji.radical);
    if (radicalRow) {
        headMeta.appendChild(radicalRow);
    }
    if (typeof kanji.strokes === 'number' && kanji.strokes > 0) {
        const strokesRow = createKanjiReadingRow(
            window._kanjiLabels?.strokes || 'Strokes', String(kanji.strokes));
        if (strokesRow) {
            headMeta.appendChild(strokesRow);
        }
    }
    if (headMeta.children.length > 0) {
        head.appendChild(headMeta);
    }
    card.appendChild(head);

    const onyomiRow = createKanjiReadingRow(window._kanjiLabels?.onyomi || 'On', kanji.onyomi);
    if (onyomiRow) {
        card.appendChild(onyomiRow);
    }
    const kunyomiRow = createKanjiReadingRow(window._kanjiLabels?.kunyomi || 'Kun', kanji.kunyomi);
    if (kunyomiRow) {
        card.appendChild(kunyomiRow);
    }

    const meanings = Array.isArray(kanji.meanings)
        ? kanji.meanings.filter((m) => typeof m === 'string' && m.length > 0)
        : [];
    if (meanings.length > 0) {
        const meaningEl = el('div', { className: 'kanji-card-meanings' });
        meaningEl.textContent = meanings.join(', ');
        card.appendChild(meaningEl);
    }

    if (kanji.dictName) {
        card.appendChild(el('div', { className: 'kanji-card-dict', textContent: kanji.dictName }));
    }

    return card;
}

// Builds the container holding every kanji card for the current lookup, or null
// when there are no kanji results. Each character in a multi-character (rare,
// but the array supports it) result gets its own card.
function buildKanjiCards() {
    const kanji = window.kanjiResults;
    if (!Array.isArray(kanji) || kanji.length === 0) {
        return null;
    }
    const section = el('div', { className: 'kanji-card-section' });
    let appended = 0;
    for (const entry of kanji) {
        const card = createKanjiCard(entry);
        if (card) {
            section.appendChild(card);
            appended++;
        }
    }
    return appended > 0 ? section : null;
}

window._renderGeneration = 0;

// TODO-058 fail-safe: always notify Dart that rendering finished, even when
// buildEntryElement / postProcessRuby throws. Without this a render exception
// would swallow the `popupRendered` signal forever, leaving a cold nested popup
// permanently hidden (pending reveal). Fired exactly once per render.
function _firePopupRendered() {
    try {
        window.flutter_inappwebview.callHandler('popupRendered',
            document.body.scrollHeight);
    } catch (e) {
        console.error('[popup] popupRendered callHandler failed', e);
    }
}

window.renderPopup = function() {
    const t0 = performance.now();
    const container = document.getElementById('entries-container');
    if (!container) { _firePopupRendered(); return; }

    const entries = window.lookupEntries;
    // TODO-094 S5: a kanji-dictionary card may be present even with NO term
    // entries (a single kanji that is only in a kanji dictionary, not a term
    // headword). Build it first so it sits above the terms, and so a kanji-only
    // result still renders instead of falling through to "No results".
    let kanjiSection = null;
    try {
        kanjiSection = buildKanjiCards();
    } catch (e) {
        console.error('[popup] renderPopup kanji card render failed', e);
        kanjiSection = null;
    }

    if ((!entries || !entries.length) && !kanjiSection) {
        container.innerHTML = '<div class="no-results">'
            + '<div class="no-results-icon">&#x1F50D;</div>'
            + '<div>' + (window._noResultsMessage || 'No results found.') + '</div>'
            + '</div>';
        window._renderedGlossaryCounts = [];
        _firePopupRendered();
        return;
    }

    const gen = ++window._renderGeneration;

    // Kanji-only result (no term entries): render just the kanji card(s).
    if (!entries || !entries.length) {
        container.innerHTML = '';
        if (kanjiSection) {
            container.appendChild(kanjiSection);
        }
        applyCustomCSS();
        window._renderedGlossaryCounts = [];
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=0 kanji=1');
        _firePopupRendered();
        return;
    }

    try {
        container.innerHTML = '';

        if (kanjiSection) {
            container.appendChild(kanjiSection);
        }
        const firstEntry = buildEntryElement(entries[0], 0);
        container.appendChild(firstEntry);
        postProcessRuby(firstEntry);
        applyCustomCSS();
    } catch (e) {
        // 渲染抛错也发信号让 Dart 翻可见（哪怕内容不全），杜绝永久挂起。
        console.error('[popup] renderPopup first-entry render failed', e);
        window._renderedGlossaryCounts = [];
        _firePopupRendered();
        return;
    }

    if (entries.length === 1) {
        window._renderedGlossaryCounts = [entries[0].glossaries.length];
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=1');
        _firePopupRendered();
        return;
    }

    setTimeout(() => {
        if (gen !== window._renderGeneration) return;
        try {
            const fragment = document.createDocumentFragment();
            for (let idx = 1; idx < entries.length; idx++) {
                const entry = entries[idx];
                if (!entry) continue;
                fragment.appendChild(document.createElement('hr'));
                fragment.appendChild(buildEntryElement(entry, idx));
            }
            container.appendChild(fragment);
            postProcessRuby(container);
            window._renderedGlossaryCounts = entries.map(e => e.glossaries.length);
            console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=' + entries.length);
        } catch (e) {
            console.error('[popup] renderPopup rest-entries render failed', e);
        }
        // 无论后续词条渲染成功与否都发信号（首条已在上面渲染好）。
        _firePopupRendered();
    }, 0);
};

window.updatePopupIncremental = function() {
    const container = document.getElementById('entries-container');
    if (!container || !window.lookupEntries?.length) return;

    const entries = window.lookupEntries;
    const prevCounts = window._renderedGlossaryCounts || [];
    const existingEntries = container.querySelectorAll(':scope > .entry');

    for (let idx = 0; idx < entries.length; idx++) {
        const entry = entries[idx];
        const newCount = entry.glossaries.length;

        if (idx < prevCounts.length) {
            if (newCount !== prevCounts[idx]) {
                const entryDiv = existingEntries[idx];
                const body = entryDiv.querySelector('.glossary-section .category-body');
                if (body) {
                    const existingDicts = new Set();
                    body.querySelectorAll(':scope > .glossary-group > [data-dictionary]').forEach(
                        node => existingDicts.add(node.getAttribute('data-dictionary')));
                    const grouped = {};
                    entry.glossaries.forEach(g => {
                        (grouped[g.dictionary] ??= []).push({
                            content: g.content,
                            definitionTags: g.definitionTags,
                            termTags: g.termTags,
                        });
                    });
                    for (const dictName of Object.keys(grouped)) {
                        if (!existingDicts.has(dictName)) {
                            const section = createGlossarySection(dictName, grouped[dictName], false, idx);
                            body.appendChild(section);
                            postProcessRuby(section);
                        }
                    }
                }
            }
        } else {
            if (container.children.length > 0) {
                container.appendChild(document.createElement('hr'));
            }
            const newElement = buildEntryElement(entry, idx);
            container.appendChild(newElement);
            postProcessRuby(newElement);
        }
    }

    window._renderedGlossaryCounts = entries.map(e => e.glossaries.length);
    applyCustomCSS();

    window.flutter_inappwebview.callHandler('popupRendered',
        document.body.scrollHeight);
};


// BUG-260: finer mouse-wheel scroll granularity for the lookup popup.
//
// The popup has no wheel listener of its own, so wheel events fell through to
// the WebView's native page scroll, which steps a fixed, coarse number of CSS
// px per notch. Worse, dictionary_popup_webview injects
// `document.documentElement.style.zoom` (popupContentZoom, follows UI scale +
// dictionary font size): a scroll of D *layout* px moves D*zoom px on screen,
// so any zoom>1 amplifies the already-coarse native step and each notch jumps
// even further. Result: scrolling feels chunky, unlike a normal web page.
//
// Take over 'wheel' (passive:false so preventDefault works), normalize the
// delta across deltaMode (LINE/PAGE report in lines/pages, not px), apply a
// fraction so a single notch travels a small, smooth distance, then divide the
// layout-px scroll amount by the current zoom so the *visual* step is the same
// regardless of zoom (a V-px visual move needs V/zoom layout px). behavior:auto
// keeps it crisp (no smooth-scroll lag stacking up across rapid notches).
//
// Inner vertically-scrollable containers (the description overlay, any glossary
// element with its own y-overflow) keep native scroll until they hit a boundary,
// so nested scroll regions are not stolen — only the main document scroll, which
// is the coarse one, is refined.
const POPUP_WHEEL_PIXEL_FACTOR = 0.35; // fraction of the raw px delta per notch
const POPUP_WHEEL_LINE_HEIGHT = 16;    // px per line for deltaMode === LINE
function popupCurrentZoom() {
    const z = parseFloat(document.documentElement.style.zoom);
    return (Number.isFinite(z) && z > 0) ? z : 1;
}
// Normalize a wheel delta (any axis) to CSS pixels, accounting for deltaMode.
function popupWheelDeltaToPixels(delta, deltaMode, pageExtent) {
    if (deltaMode === 1 /* DOM_DELTA_LINE */) {
        return delta * POPUP_WHEEL_LINE_HEIGHT;
    }
    if (deltaMode === 2 /* DOM_DELTA_PAGE */) {
        return delta * (pageExtent || POPUP_WHEEL_LINE_HEIGHT);
    }
    return delta; // DOM_DELTA_PIXEL
}
// Walk up from the event target looking for an ancestor that can still consume
// this vertical wheel natively (it scrolls on Y and is not yet at the boundary
// in the wheel's direction). If found we leave the event alone.
function popupAncestorAbsorbsVerticalWheel(target, deltaPx) {
    let node = (target && target.nodeType === Node.TEXT_NODE)
        ? target.parentElement : target;
    while (node && node !== document.body && node !== document.documentElement) {
        const style = window.getComputedStyle(node);
        const oy = style.overflowY;
        const canScrollY = (oy === 'auto' || oy === 'scroll') &&
            node.scrollHeight > node.clientHeight + 1;
        if (canScrollY) {
            const atTop = node.scrollTop <= 0;
            const atBottom =
                node.scrollTop + node.clientHeight >= node.scrollHeight - 1;
            if ((deltaPx < 0 && !atTop) || (deltaPx > 0 && !atBottom)) {
                return true;
            }
        }
        node = node.parentElement;
    }
    return false;
}
document.addEventListener('wheel', (e) => {
    // Ignore zoom gestures (ctrl+wheel / pinch) and pure horizontal scroll.
    if (e.ctrlKey) return;
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    const deltaPx = popupWheelDeltaToPixels(e.deltaY, e.deltaMode, window.innerHeight);
    if (deltaPx === 0) return;
    if (popupAncestorAbsorbsVerticalWheel(e.target, deltaPx)) return;
    e.preventDefault();
    // Divide by zoom so the on-screen step is zoom-independent; scale by the
    // fraction so each notch is a small, smooth move.
    const step = (deltaPx * POPUP_WHEEL_PIXEL_FACTOR) / popupCurrentZoom();
    window.scrollBy({ top: step, behavior: 'auto' });
}, { passive: false });


let _popupMouseDownPos = null;
document.addEventListener('mousedown', (e) => {
    _popupMouseDownPos = { x: e.clientX, y: e.clientY };
});

document.addEventListener('click', (e) => {
    if (_popupMouseDownPos) {
        const dx = e.clientX - _popupMouseDownPos.x;
        const dy = e.clientY - _popupMouseDownPos.y;
        _popupMouseDownPos = null;
        if (dx * dx + dy * dy > 25) {
            return;
        }
    }

    const sel = window.getSelection();
    if (sel && sel.toString().length > 0) {
        sel.removeAllRanges();
        return;
    }

    const target = e.target?.nodeType === Node.TEXT_NODE ? e.target.parentElement : e.target;
    if (target?.closest('.mine-button') || target?.closest('.audio-button')) return;
    if (target?.closest('summary')) return;
    if (target?.closest('.glossary-content')) {
        if (target?.closest('a[href]')) return;
        window.hoshiSelection?.selectText(e.clientX, e.clientY, 20);
        return;
    }
    if (!target?.closest('.entry-header') && !target?.closest('.entry-tags') && !target?.closest('.glossary-group') && !target?.closest('.category-section')) {
        window.flutter_inappwebview.callHandler('tapOutside');
    }
});

var _popupShiftLastX = -1, _popupShiftLastY = -1;
document.addEventListener('mousemove', function(e) {
    if (!e.shiftKey) { _popupShiftLastX = -1; _popupShiftLastY = -1; return; }
    var dx = e.clientX - _popupShiftLastX, dy = e.clientY - _popupShiftLastY;
    if (dx * dx + dy * dy < 64) return;
    _popupShiftLastX = e.clientX; _popupShiftLastY = e.clientY;
    if (window.hoshiSelection) {
        window.hoshiSelection.selectText(e.clientX, e.clientY, 20);
    }
}, {passive: true});
