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

// BUG-435 / BUG-478 / BUG-520 家族根因：词典 structured-content 节点自带的
// inline float / position:absolute|fixed|sticky 会把文本节点推出行内流。
// 上游 Yomitan 按 schema 白名单下发样式，这两族属性从不落地；这里在源头丢弃。
// position:relative 不脱离文档流，保留。与 hibiki/assets/popup/popup.js 同步。
function isFlowEscapingStructuredContentStyle(property, value) {
    if (property === 'float' || property === 'cssFloat') {
        return true;
    }
    if (property === 'position') {
        return /^(absolute|fixed|sticky)$/i.test(String(value).trim());
    }
    return false;
}

function setStructuredContentElementStyle(element, style) {
    for (const [property, value] of Object.entries(style)) {
        if (isFlowEscapingStructuredContentStyle(property, value)) {
            continue;
        }
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

    overlay.addEventListener('click', () => closeImageLightbox());
    image.addEventListener('click', (event) => event.stopPropagation());

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

async function mineEntry(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
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
    
    return await window.flutter_inappwebview.callHandler('mineEntry', {
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
    });
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
    
    const mineButton = el('button', {
        className: 'mine-button',
        textContent: '+',
        disabled: true,
        ontouchstart: () => {
            lastSelection = window.getSelection()?.toString() || '';
        },
        onclick: async () => {
            mineButton.disabled = true;
            const isAnkiConnect = await mineEntry(expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
            const checkDuplicate = async () => {
                const wasAdded = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                mineButton.textContent = wasAdded ? '✓' : '+';
                if (wasAdded) {
                    mineButton.classList.add('duplicate');
                }
                mineButton.disabled = wasAdded && !window.allowDupes;
            };
            
            if (isAnkiConnect) {
                await checkDuplicate();
            } else {
                setTimeout(checkDuplicate, 1000);
            }
        }
    });
    buttonsContainer.appendChild(mineButton);
    window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading }).then(isDuplicate => {
        if (isDuplicate) {
            mineButton.textContent = '✓';
            mineButton.classList.add('duplicate');
        }
        mineButton.disabled = isDuplicate && !window.allowDupes;
    });
    
    header.appendChild(buttonsContainer);
    
    return header;
}

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

window._renderGeneration = 0;

window.renderPopup = function() {
    const t0 = performance.now();
    const container = document.getElementById('entries-container');
    if (!container) return;

    const entries = window.lookupEntries;
    if (!entries || !entries.length) {
        container.innerHTML = '<div class="no-results">'
            + '<div class="no-results-icon">&#x1F50D;</div>'
            + '<div>' + (window._noResultsMessage || 'No results found.') + '</div>'
            + '</div>';
        window._renderedGlossaryCounts = [];
        window.flutter_inappwebview.callHandler('popupRendered',
            document.body.scrollHeight);
        return;
    }

    const gen = ++window._renderGeneration;
    container.innerHTML = '';

    const firstEntry = buildEntryElement(entries[0], 0);
    container.appendChild(firstEntry);
    postProcessRuby(firstEntry);
    applyCustomCSS();

    if (entries.length === 1) {
        window._renderedGlossaryCounts = [entries[0].glossaries.length];
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=1');
        window.flutter_inappwebview.callHandler('popupRendered',
            document.body.scrollHeight);
        return;
    }

    setTimeout(() => {
        if (gen !== window._renderGeneration) return;
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
        window.flutter_inappwebview.callHandler('popupRendered',
            document.body.scrollHeight);
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
