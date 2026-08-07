function normalizeDictMediaPath(raw) {
    return `${raw}`.trim().replace(/\\/g, '/').replace(/^(?:\.\/|\/)+/, '');
}

function rewriteDictionaryMediaPath(rawPath, dictName) {
    const trimmed = `${rawPath}`.trim();
    if (!trimmed || /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(trimmed)) {
        return null;
    }
    const normalized = normalizeDictMediaPath(rawPath);
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
