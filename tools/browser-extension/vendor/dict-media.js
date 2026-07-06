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
    // extension, bridge-shim.js pre-fills window.__hibikiDictMedia with the
    // running server's base URL + token (from background cfg()); when present,
    // rewrite to the server's http media endpoint. In-app that global is unset
    // -> the original image:// path is kept (the app WebView resolves it).
    const media = (typeof window !== 'undefined') ? window.__hibikiDictMedia : null;
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
        return `<link rel="stylesheet" href="dictmedia://${encodeURIComponent(normalized)}?dictionary=${encodeURIComponent(dictName)}">`;
    }).replace(/<img\b[^>]*\bsrc=(['"])([^'"]+)\1[^>]*>/gi, (match, quote, src) => {
        const rewritten = rewriteDictionaryMediaPath(src, dictName);
        if (rewritten === null) {
            return match;
        }
        return match.replace(/\bsrc=(['"])([^'"]+)\1/i, `src=${quote}${rewritten}${quote}`);
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
        if (bracePos === -1) break;
        const selectorPart = css.slice(i, bracePos);
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
