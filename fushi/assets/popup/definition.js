//
//  definition.js
//  Hibiki - Shared structured content rendering for dictionary definitions
//
//  Extracted from popup.js to unify rendering between popup and main dictionary views.
//  Copyright © 2026 Manhhao.
//  Copyright © 2023-2025 Yomitan Authors.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

const KANJI_RANGE = '一-鿿㐀-䶿豈-﫿々';
const KANJI_PATTERN = new RegExp(`[${KANJI_RANGE}]`);
const KANA_PATTERN = /[぀-ヿｦ-ﾟ]/;
const CJK_PATTERN = new RegExp(`[${KANJI_RANGE}]`);

function toKebabCase(str) {
    return str.replace(/([A-Z])/g, (_, c, i) => (i ? '-' : '') + c.toLowerCase());
}

function isStringPartiallyJapanese(text) {
    if (!text) return false;
    return KANA_PATTERN.test(text) || CJK_PATTERN.test(text);
}

function isStringPartiallyChinese(text) {
    if (!text) return false;
    return CJK_PATTERN.test(text) || /[㄀-ㄯㆠ-ㆿ]/.test(text);
}

function getLanguageFromText(text, language) {
    const partiallyJapanese = isStringPartiallyJapanese(text);
    const partiallyChinese = isStringPartiallyChinese(text);
    if (!['zh', 'yue'].includes(language ?? '')) {
        if (partiallyJapanese) return 'ja';
        if (partiallyChinese) return 'zh';
    }
    return language ?? null;
}

function openExternalLink(url) {
    window.flutter_inappwebview.callHandler('openLink', url);
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


// --- Image handling (from popup.js) ---

function shouldRenderDefinitionImageToCanvas(path, appearance, usedWidth, invAspectRatio) {
    return /\.svg$/i.test(path) && appearance === 'monochrome' && usedWidth <= 4 && (usedWidth * invAspectRatio) <= 4;
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

function createDefinitionImageCanvas(imageUrl, alt, onLoad) {
    const canvas = document.createElement('canvas');
    canvas.classList.add('gloss-image');
    canvas.setAttribute('role', 'img');
    canvas.setAttribute('aria-label', alt);
    const sourceImage = new Image();
    sourceImage.addEventListener('load', () => onLoad(canvas, sourceImage), { once: true });
    sourceImage.src = imageUrl;
    return canvas;
}

function renderDefinitionImageToCanvas(canvas, image, usedWidth, invAspectRatio, appearance) {
    const emSize = Number.parseFloat(getComputedStyle(document.documentElement).fontSize);
    const scaleFactor = Math.ceil(window.devicePixelRatio * 2);
    const pixelWidth = Math.round(usedWidth * emSize * scaleFactor);
    const pixelHeight = Math.round(usedWidth * emSize * invAspectRatio * scaleFactor);
    const maxCanvasSize = 128;
    const scale = Math.min(1, maxCanvasSize / Math.max(pixelWidth, pixelHeight), Math.sqrt((maxCanvasSize * maxCanvasSize) / (pixelWidth * pixelHeight)));
    canvas.style.width = '100%';
    canvas.style.height = '100%';
    canvas.width = Math.round(pixelWidth * scale);
    canvas.height = Math.round(pixelHeight * scale);
    const context = canvas.getContext('2d');
    if (!context) return;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    if (appearance === 'monochrome') {
        context.globalCompositeOperation = 'source-in';
        context.fillStyle = document.documentElement.getAttribute('data-theme') === 'dark' ? '#ffffff' : '#000000';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.globalCompositeOperation = 'source-over';
    }
}

function createDefinitionImage(data, dictionary, exporting) {
    const {
        path, width = 100, height = 100, preferredWidth, preferredHeight,
        title, pixelated, imageRendering, appearance, background,
        collapsed, collapsible, verticalAlign, border, borderRadius,
        sizeUnits, data: nodeData,
    } = data;

    const hasPreferredWidth = (typeof preferredWidth === 'number');
    const hasPreferredHeight = (typeof preferredHeight === 'number');
    const hasDimensions = (hasPreferredWidth || hasPreferredHeight || typeof data.width === 'number' || typeof data.height === 'number');
    const invAspectRatio = (hasPreferredWidth && hasPreferredHeight ? preferredHeight / preferredWidth : height / width);
    const usedWidth = (hasPreferredWidth ? preferredWidth : (hasPreferredHeight ? preferredHeight / invAspectRatio : width));
    const effectiveSizeUnits = (typeof sizeUnits === 'string' ? sizeUnits : null);
    const isSvg = /\.svg$/i.test(path);
    const useEmUnits = effectiveSizeUnits === 'em';

    console.log('[IMG-def]', path, JSON.stringify({
        width, height, preferredWidth, preferredHeight,
        usedWidth, hasDimensions, appearance, sizeUnits: useEmUnits ? effectiveSizeUnits : null
    }));

    const node = document.createElement('a');
    node.classList.add('gloss-image-link');
    node.target = '_blank';
    node.rel = 'noreferrer noopener';

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
    if (typeof verticalAlign === 'string') node.dataset.verticalAlign = verticalAlign;
    if (useEmUnits) node.dataset.sizeUnits = effectiveSizeUnits;

    aspectRatioSizer.style.paddingTop = `${invAspectRatio * 100}%`;
    if (typeof border === 'string') imageContainer.style.border = border;
    if (typeof borderRadius === 'string') imageContainer.style.borderRadius = borderRadius;
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
    if (typeof title === 'string') imageContainer.title = title;

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
        if (!isSvg) {
            img.addEventListener('load', () => {
                if (img.naturalWidth <= 0 || img.naturalHeight <= 0) return;
                if (useEmUnits && !hasMismatchedNaturalAspectRatio(img, invAspectRatio)) return;
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
            }, { once: true });
        }
        img.src = imageUrl;
        imageContainer.appendChild(img);
    }
    if (useEmUnits) {
        node.style.maxWidth = 'none';
        imageContainer.style.maxWidth = 'none';
        const scrollWrapper = document.createElement('div');
        scrollWrapper.className = 'gloss-image-scroll';
        scrollWrapper.appendChild(node);
        return scrollWrapper;
    }
    return node;
}

// --- Core structured content rendering (from popup.js) ---

const INLINE_HTML_RE_DEF = /<(?:ruby|rt|rp|b|i|em|strong|span|sup|sub|br)\b[^>]*>/i;
const URL_RE_DEF = /(?:https?:\/\/|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|org|net|edu|gov|io|dev|app|jp|uk|de|fr|info|me|co)\/)[^\s<>　，、。！））)]+/gi;
const SAFE_TAGS_DEF = new Set(['ruby','rt','rp','b','i','em','strong','span','sup','sub','br','a']);

function sanitizeInlineHtmlDef(html) {
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    tmp.querySelectorAll('script,style,iframe,object,embed,form,input,textarea,link').forEach(el => el.remove());
    tmp.querySelectorAll('*').forEach(el => {
        const tag = el.tagName.toLowerCase();
        if (!SAFE_TAGS_DEF.has(tag)) {
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

function linkifyUrlsDef(html) {
    return html.replace(URL_RE_DEF, url => {
        const href = /^https?:\/\//i.test(url) ? url : 'https://' + url;
        const escapedHref = href.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
        return `<a href="${escapedHref}">${url}</a>`;
    });
}

function appendRichTextLineDef(parent, line) {
    const hasHtml = INLINE_HTML_RE_DEF.test(line);
    const hasUrl = URL_RE_DEF.test(line);
    URL_RE_DEF.lastIndex = 0;
    if (!hasHtml && !hasUrl) {
        parent.appendChild(document.createTextNode(line));
        return;
    }
    let html = hasHtml ? sanitizeInlineHtmlDef(line) : line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    if (hasUrl || URL_RE_DEF.test(html)) {
        URL_RE_DEF.lastIndex = 0;
        const tmp2 = document.createElement('div');
        tmp2.innerHTML = html;
        const walker = document.createTreeWalker(tmp2, NodeFilter.SHOW_TEXT);
        const textNodes = [];
        while (walker.nextNode()) textNodes.push(walker.currentNode);
        textNodes.forEach(tn => {
            if (URL_RE_DEF.test(tn.textContent)) {
                URL_RE_DEF.lastIndex = 0;
                const span = document.createElement('span');
                span.innerHTML = linkifyUrlsDef(tn.textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'));
                tn.replaceWith(...span.childNodes);
            }
        });
        html = tmp2.innerHTML;
    }
    const frag = document.createElement('span');
    frag.innerHTML = html;
    while (frag.firstChild) parent.appendChild(frag.firstChild);
}

// True for a Yomitan "form-of" glossary item: a [term, [tag, ...]] pair (see
// the array branch of renderStructuredContent, BUG-057).
function isTaggedTermPairDef(item) {
    return Array.isArray(item)
        && item.length === 2
        && typeof item[0] === 'string'
        && Array.isArray(item[1])
        && item[1].every(tag => typeof tag === 'string');
}

// Renders an array of [term, [tag, ...]] pairs as a readable list: each pair on
// its own line, the referenced term followed by its tag chips. Replaces the
// generic flattening that produced unspaced "时Hyōgai时alt-of…" mojibake.
function renderTaggedTermPairsDef(parent, pairs) {
    const list = document.createElement('div');
    list.classList.add('form-of-list');
    pairs.forEach(([term, tags]) => {
        const item = document.createElement('div');
        item.classList.add('form-of-item');
        const termEl = document.createElement('span');
        termEl.classList.add('form-of-term');
        termEl.textContent = term;
        termEl.style.marginRight = '4px';
        item.appendChild(termEl);
        if (tags.length) {
            const tagRow = document.createElement('div');
            tagRow.classList.add('glossary-tags', 'form-of-tags');
            tags.forEach(tag => {
                const tagEl = document.createElement('span');
                tagEl.classList.add('glossary-tag');
                tagEl.textContent = tag;
                tagRow.appendChild(tagEl);
            });
            item.appendChild(tagRow);
        }
        list.appendChild(item);
    });
    parent.appendChild(list);
}

function renderStructuredContent(parent, node, language, dictName, exporting) {
    if (typeof node === 'string') {
        node.split(/\r?\n/).forEach((line, i) => {
            if (i > 0) parent.appendChild(document.createElement('br'));
            if (line) {
                if (!language && !parent.hasAttribute('lang')) {
                    const detected = getLanguageFromText(line, language);
                    if (detected) parent.setAttribute('lang', detected);
                }
                appendRichTextLineDef(parent, line);
            }
        });
        return;
    }

    if (Array.isArray(node)) {
        // Yomitan "form-of"/non-lemma glossary: an array of [term, [tag, ...]]
        // pairs (e.g. wty-ja-en alt-of entries). The generic flattening below
        // would emit bare adjacent text nodes with no spacing → mojibake-looking
        // "时Hyōgai时alt-of…" (BUG-057). Render each pair on its own line.
        if (node.length > 0 && node.every(isTaggedTermPairDef)) {
            renderTaggedTermPairsDef(parent, node);
            return;
        }
        const isStringArray = node.every(item => typeof item === 'string');
        const insideSpan = parent.tagName === 'SPAN';
        if (isStringArray && node.length > 1 && !insideSpan) {
            const ul = document.createElement('ul');
            ul.classList.add('glossary-list');
            node.forEach(child => {
                const li = document.createElement('li');
                appendRichTextLineDef(li, child);
                ul.appendChild(li);
            });
            parent.appendChild(ul);
            return;
        }
        const items = node.map(item => item?.type === 'structured-content' ? item.content : item);
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

    if (!node || typeof node !== 'object') return;

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

    if (node.title) element.setAttribute('title', node.title);

    if (node.lang) {
        element.setAttribute('lang', node.lang);
        nextLanguage = node.lang;
    }

    if (node.data) {
        for (const [k, v] of Object.entries(node.data)) {
            const isCJK = /^[　-鿿豈-﫿]/.test(k);
            element.setAttribute(`data-sc${isCJK ? '' : '-'}${toKebabCase(k)}`, v);
        }
    }

    if (node.style) setStructuredContentElementStyle(element, node.style);

    if (node.content) renderStructuredContent(element, node.content, nextLanguage, dictName, exporting);

    if (node.colSpan) element.setAttribute('colspan', node.colSpan);
    if (node.rowSpan) element.setAttribute('rowspan', node.rowSpan);

    if (tagName === 'table') {
        const container = document.createElement('div');
        container.classList.add('gloss-sc-table-container');
        container.appendChild(element);
        parent.appendChild(container);
        return;
    }

    parent.appendChild(element);
}

// --- Entry point for DictionaryHtmlWidget ---

window.renderDefinition = function(contentJson, dictName, dictCss, fontSize, isDark) {
    document.documentElement.setAttribute('data-theme', isDark ? 'dark' : 'light');
    document.documentElement.style.setProperty('--font-size-no-units', fontSize);

    const container = document.getElementById('content');
    container.innerHTML = '';
    container.style.fontSize = fontSize + 'px';
    container.setAttribute('data-dictionary', dictName);

    if (dictCss) {
        const scopedCss = constructDictCss(dictCss, dictName);
        const styleEl = document.createElement('style');
        styleEl.textContent = scopedCss;
        container.appendChild(styleEl);
    }

    let content;
    if (typeof contentJson === 'string') {
        try {
            content = JSON.parse(contentJson);
        } catch {
            if (/<[a-z][\s\S]*>/i.test(contentJson)) {
                const wrapper = document.createElement('div');
                wrapper.innerHTML = rewriteDictLinks(contentJson, dictName);
                container.appendChild(wrapper);
                reportHeight();
                return;
            }
            content = contentJson;
        }
    } else {
        content = contentJson;
    }

    renderStructuredContent(container, content, null, dictName);
    reportHeight();
};

function reportHeight() {
    requestAnimationFrame(() => {
        window.flutter_inappwebview.callHandler('contentHeight', document.body.scrollHeight);
    });
}
