function normalizeDictMediaPath(raw) {
    return `${raw}`.trim().replace(/\\/g, '/').replace(/^(?:\.\/|\/)+/, '');
}

function rewriteDictionaryMediaPath(rawPath, dictName) {
    const trimmed = `${rawPath}`.trim();
    if (!trimmed || /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(trimmed)) {
        return null;
    }
    const normalized = normalizeDictMediaPath(rawPath);
    // TODO-1215: a real browser has no image:// scheme handler, so gaiji /
    // pitch-accent SVG images would break (ERR_UNKNOWN_URL_SCHEME). In the
    // extension, bridge-shim.js pre-fills window.__fushiDictMedia with the
    // running server's base URL + token (from background cfg()); when present,
    // rewrite to the server's http media endpoint. In-app that global is unset
    // -> the original image:// path is kept (the app WebView resolves it).
    const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
    if (media && media.base && media.token) {
        return `${media.base}/api/media/dictionary` +
            `?dictionary=${encodeURIComponent(dictName)}` +
            `&path=${encodeURIComponent(normalized)}` +
            `&token=${encodeURIComponent(media.token)}`;
    }
    return `image://?dictionary=${encodeURIComponent(dictName)}&path=${encodeURIComponent(normalized)}`;
}

function rewriteDictLinks(html, dictName) {
    return html.replace(/<link[^>]*href=['"]([^'"]+)['"][^>]*>/gi, (match, href) => {
        const normalized = normalizeDictMediaPath(href);
        // BUG-1718：真实浏览器同样没有 dictmedia:// scheme handler，词条 HTML 里指向词典包内
        // 样式表的 <link> 在扩展里是死链（app 内由 WebView 自定义 scheme 解析）。与 <img> 同款
        // 处理：扩展环境下降级成无 token 的占位属性，由 resolveDictMediaPlaceholders 取字节后
        // 换成 <style>。app 内（该全局未设）保持 dictmedia:// 原样。
        const linkMedia = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
        if (linkMedia && linkMedia.base && linkMedia.token) {
            return `<link data-fushi-media-dict="${encodeURIComponent(dictName)}" data-fushi-media-path="${encodeURIComponent(href)}">`;
        }
        return `<link rel="stylesheet" href="dictmedia://${encodeURIComponent(normalized)}?dictionary=${encodeURIComponent(dictName)}">`;
    }).replace(/<img\b[^>]*\bsrc=(['"])([^'"]+)\1[^>]*>/gi, (match, quote, src) => {
        const rewritten = rewriteDictionaryMediaPath(src, dictName);
        if (rewritten === null) {
            return match;
        }
        // TODO-1215 安全：扩展环境（window.__fushiDictMedia 已设）下，这段 HTML 会经 innerHTML
        // 直落宿主页 DOM——绝不能把带原始 sync token 的媒体 URL 写进 <img src>（哪怕只存在一帧也会被
        // MutationObserver 截获）。改成无 token 的占位 data-* 属性（去掉 src），popup.js 在 innerHTML
        // 之后据此 fetch→blob 补 src（token 只在 fetch 调用里）。app 内（该全局未设）保持原样。
        const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
        if (media && media.base && media.token) {
            return match.replace(/src=(['"])([^'"]+)\1/i,
                `data-fushi-media-dict="${encodeURIComponent(dictName)}" data-fushi-media-path="${encodeURIComponent(src)}"`);
        }
        return match.replace(/src=(['"])([^'"]+)\1/i, `src=${quote}${rewritten}${quote}`);
    });
}

function constructDictCss(css, dictName, scopePrefix) {
    if (!css) return '';
    const prefix = scopePrefix || `[data-dictionary="${dictName}"]`;
    const parts = [];
    let i = 0;
    while (i < css.length) {
        while (i < css.length && /\s/.test(css[i])) {
            parts.push(css[i++]);
        }
        if (css.slice(i, i + 2) === '/*') {
            const end = css.indexOf('*/', i + 2);
            if (end === -1) break;
            parts.push(css.slice(i, end + 2));
            i = end + 2;
            continue;
        }
        const bracePos = css.indexOf('{', i);
        const semiPos = css.indexOf(';', i);
        // Statement at-rules (`@import`, `@charset`, `@namespace`, `@layer a, b;`)
        // terminate with `;` before any block — pass them through verbatim; they
        // carry no selector that could (or should) be scoped.
        if (semiPos !== -1 && (bracePos === -1 || semiPos < bracePos)) {
            const statement = css.slice(i, semiPos + 1);
            if (statement.trimStart().startsWith('@')) {
                parts.push(statement);
                i = semiPos + 1;
                continue;
            }
        }
        if (bracePos === -1) break;
        const selectorPart = css.slice(i, bracePos);
        const selectorPrelude = selectorPart.trim();
        // Block at-rules need their prelude preserved unscoped. Two families:
        //  - Conditional groups (`@media`/`@supports`/`@container`/`@layer`/`@scope`)
        //    wrap nested STYLE RULES, so their inner rules must still be scoped.
        //  - Other at-rules (`@font-face`/`@keyframes`/`@page`/`@font-feature-values`/...)
        //    contain declarations or keyframe-selectors that must NOT be prefixed.
        const atRuleMatch = selectorPrelude.match(/^@([a-z-]+)/i);
        if (atRuleMatch) {
            const atName = atRuleMatch[1].toLowerCase();
            const isConditionalGroup =
                atName === 'media' ||
                atName === 'supports' ||
                atName === 'container' ||
                atName === 'layer' ||
                atName === 'scope';
            // Capture the at-rule's own block so we can decide per-family.
            i = bracePos + 1;
            let atDepth = 1;
            const atBlockStart = i;
            while (i < css.length && atDepth > 0) {
                if (css[i] === '{') atDepth++;
                else if (css[i] === '}') atDepth--;
                i++;
            }
            const atBlockContent = css.slice(atBlockStart, i - 1);
            parts.push(selectorPart, ' {');
            if (isConditionalGroup) {
                // Recurse so inner style rules get the prefix; the prelude stays raw.
                parts.push(constructDictCss(atBlockContent, dictName, scopePrefix));
            } else {
                // @font-face / @keyframes / @page: body is declarations or
                // keyframe selectors — emit verbatim, never prefixed.
                parts.push(atBlockContent);
            }
            parts.push('}');
            continue;
        }
        const selectors = selectorPart.split(',').map(s => {
            const trimmed = s.trim();
            if (!trimmed) return '';
            if (trimmed.startsWith('&')) return s;
            return `${prefix} ${trimmed}`;
        });
        parts.push(selectors.join(', '), ' {');
        i = bracePos + 1;
        let depth = 1;
        let blockStart = i;
        while (i < css.length && depth > 0) {
            if (css[i] === '{') depth++;
            else if (css[i] === '}') depth--;
            i++;
        }
        const blockContent = css.slice(blockStart, i - 1);
        if (blockContent.includes('{')) {
            let pos = 0;
            let properties = '';
            let nestedRules = '';
            while (pos < blockContent.length) {
                while (pos < blockContent.length && /\s/.test(blockContent[pos])) pos++;
                if (pos >= blockContent.length) break;
                let nextSemi = blockContent.indexOf(';', pos);
                let nextBrace = blockContent.indexOf('{', pos);
                if (nextBrace !== -1 && (nextSemi === -1 || nextBrace < nextSemi)) {
                    let nestedDepth = 1;
                    let nestedEnd = nextBrace + 1;
                    while (nestedEnd < blockContent.length && nestedDepth > 0) {
                        if (blockContent[nestedEnd] === '{') nestedDepth++;
                        else if (blockContent[nestedEnd] === '}') nestedDepth--;
                        nestedEnd++;
                    }
                    nestedRules += blockContent.slice(pos, nestedEnd);
                    pos = nestedEnd;
                } else if (nextSemi !== -1) {
                    properties += blockContent.slice(pos, nextSemi + 1);
                    pos = nextSemi + 1;
                } else {
                    properties += blockContent.slice(pos);
                    break;
                }
            }
            parts.push(properties);
            if (nestedRules) parts.push(constructDictCss(nestedRules, dictName, scopePrefix));
        } else {
            parts.push(blockContent);
        }
        parts.push('}');
    }
    return parts.join('');
}

// BUG-1718：把 rewriteDictLinks 落下的占位属性（data-fushi-media-dict / data-fushi-media-path）
// 解析成真正可显示的资源。TODO-1215 当初为了不把 sync token 写进宿主页 DOM，只把 <img src>
// 换成了占位属性，却**从没有人来兑现这些占位**——扩展里 mdx 词典词条内的图片（gaiji / 插图 /
// 声调图）因此一直是裂图。这里补上兑现方：token 只出现在 fetch 调用参数里，落到 DOM 的是
// blob: URL（<img>）或内联 <style>（<link>），宿主页 MutationObserver 拿不到 token。
function fushiDictMediaEndpoint(media, encodedDict, encodedPath) {
    const path = normalizeDictMediaPath(decodeURIComponent(encodedPath));
    return `${media.base}/api/media/dictionary`
        + `?dictionary=${encodedDict}`
        + `&path=${encodeURIComponent(path)}`
        + `&token=${encodeURIComponent(media.token)}`;
}

function resolveDictMediaPlaceholders(root) {
    const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
    if (!media || !media.base || !media.token || !root || !root.querySelectorAll) return;
    const nodes = root.querySelectorAll('[data-fushi-media-path]');
    for (const node of nodes) {
        const encodedDict = node.getAttribute('data-fushi-media-dict') || '';
        const encodedPath = node.getAttribute('data-fushi-media-path') || '';
        // 先摘属性：解析只做一次。失败也不重试，避免 MutationObserver ↔ 失败 无限打转。
        node.removeAttribute('data-fushi-media-path');
        if (!encodedPath) continue;
        const url = fushiDictMediaEndpoint(media, encodedDict, encodedPath);
        const isLink = node.tagName === 'LINK';
        fetch(url).then((r) => {
            if (!r.ok) return null;
            return isLink ? r.text() : r.blob();
        }).then((payload) => {
            if (payload === null || !node.parentNode) return;
            if (isLink) {
                const style = document.createElement('style');
                style.textContent = payload;
                node.parentNode.replaceChild(style, node);
                return;
            }
            const objectUrl = URL.createObjectURL(payload);
            node.addEventListener('load', () => URL.revokeObjectURL(objectUrl), { once: true });
            node.addEventListener('error', () => URL.revokeObjectURL(objectUrl), { once: true });
            node.src = objectUrl;
        }).catch(() => { /* 取不到就保持裂图/无样式，绝不阻断查词渲染 */ });
    }
}

// 弹窗内容是 popup.js 分批渲染的（懒展开、嵌套查词都会再插 DOM），所以不能只在一次渲染后扫一遍：
// 在弹窗根上装一个 MutationObserver，任何新插入的占位都会被兑现。每个 root 只装一次。
function installDictMediaPlaceholderResolver(root) {
    if (!root || root.__fushiDictMediaObserver) return;
    if (typeof MutationObserver !== 'function') return;
    const observer = new MutationObserver(() => resolveDictMediaPlaceholders(root));
    observer.observe(root, { childList: true, subtree: true });
    root.__fushiDictMediaObserver = observer;
    resolveDictMediaPlaceholders(root);
}

// BUG-1718：把查词响应里的「弹窗 CSS 尾段」落到 popup.js 读取的三个全局上。app 内弹窗由
// popup_settings_injection 注入同名三件套，扩展只能从 /api/lookup/dictionary 响应拿；不落这一步
// 的话 window.dictionaryStyles 恒为 undefined，mdx 词典自带样式在扩展里 100% 失效。
function applyFushiPopupCss(data) {
    if (!data || typeof data !== 'object') return;
    window.dictionaryStyles =
        (data.dictionaryStyles && typeof data.dictionaryStyles === 'object')
            ? data.dictionaryStyles : {};
    window.globalDictCSS =
        typeof data.globalDictCSS === 'string' ? data.globalDictCSS : '';
    window.customDictCSS =
        (data.customDictCSS && typeof data.customDictCSS === 'object')
            ? data.customDictCSS : {};
}
