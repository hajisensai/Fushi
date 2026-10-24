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

/* rewriteDictLinks 的 DOM 版（BUG-3762）：在已净化的惰性 DOM（<template> 内容）上直接改写，
   调用方再 importNode 挂进文档。不能回到「改字符串 → innerHTML 再解析」：两次解析的上下文
   不同，`<math><mtext><table><mglyph><style><img onerror>` 这类结构会在第二次解析时复活脚本。 */
function rewriteDictLinksInTree(root, dictName) {
    root.querySelectorAll('link[href]').forEach((link) => {
        const normalized = normalizeDictMediaPath(link.getAttribute('href'));
        const stylesheet = link.ownerDocument.createElement('link');
        stylesheet.setAttribute('rel', 'stylesheet');
        stylesheet.setAttribute('href',
            `dictmedia://${encodeURIComponent(normalized)}?dictionary=${encodeURIComponent(dictName)}`);
        link.replaceWith(stylesheet);
    });
    root.querySelectorAll('img[src]').forEach((img) => {
        const rewritten = rewriteDictionaryMediaPath(img.getAttribute('src'), dictName);
        if (rewritten !== null) img.setAttribute('src', rewritten);
    });
}

/* 词典 CSS 作用域化的结果**只由** (css, dictName, scopePrefix) 决定——纯函数，
   同输入必同输出。但它的调用点是 createGlossarySection，即「每个词条的每个词典块」
   各调一次：N 条词条 × M 本词典就是 N×M 次把同一本词典那份（Yomitan 词典动辄几十 KB
   的）CSS 重新做一遍逐字符扫描（下面的 while 循环对空白字符是一个字符 push 一次数组）。
   查一次词就白烧几十上百遍完全相同的解析。
   这里按三元组做 memo：外层用 css 串本身分桶（内容变了自然落到新桶，无需失效钩子，
   也就不存在「换词典集后拿到旧作用域 CSS」的风险），内层用 dictName+scopePrefix。
   递归分支走未缓存的实现，避免把每个 at-block 的子串都塞进缓存。 */
const __dictCssCache = new Map();
// 桶数上限 = 同时活着的「带 styles.css 的词典」数。一次查词按「词条 × 词典」轮询全部词典的
// css，桶数一旦小于词典数就是逐次全 miss（LRU 对循环访问同样无解），所以上限必须明显
// 大于任何真实词典集；淘汰用 LRU（Map 保持插入序，命中即挪到队尾）只为换词典集时先
// 清最久没用的，而不是把还在用的一起清空。
const __dictCssCacheMaxBuckets = 256;

function constructDictCss(css, dictName, scopePrefix) {
    if (!css) return '';
    let byScope = __dictCssCache.get(css);
    if (byScope === undefined) {
        // 词典集切换/重新导入会带来新的 css 串；给桶数封顶，别让缓存无界增长。
        if (__dictCssCache.size >= __dictCssCacheMaxBuckets) {
            __dictCssCache.delete(__dictCssCache.keys().next().value);
        }
        byScope = new Map();
    } else {
        __dictCssCache.delete(css); // 命中：挪到队尾（最近使用）
    }
    __dictCssCache.set(css, byScope);
    const key = JSON.stringify([dictName || '', scopePrefix || '']);
    let out = byScope.get(key);
    if (out === undefined) {
        out = constructDictCssUncached(css, dictName, scopePrefix);
        byScope.set(key, out);
    }
    return out;
}

function constructDictCssUncached(css, dictName, scopePrefix) {
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
                parts.push(constructDictCssUncached(atBlockContent, dictName, scopePrefix));
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
            if (nestedRules) parts.push(constructDictCssUncached(nestedRules, dictName, scopePrefix));
        } else {
            parts.push(blockContent);
        }
        parts.push('}');
    }
    return parts.join('');
}

/* ---------------------------------------------------------------------------
   词典自带脚本（MDX 的 <script>：NLT 的頻度条形图、OALDPEX 的配置界面……）。

   这些脚本**只在沙箱 iframe 里跑**（popup.js 的 mountDictScriptSandbox，BUG-3762）：
   曾经在主文档里用 Function 构造器执行、window 代理回落真 window，词典脚本因此能直接
   调原生桥改写用户的 Anki 卡片。沙箱里没有桥，外链脚本的源码由父页面经下面的
   fetchDictAsset 取回再内联进 srcdoc；源码按需取并缓存，不随每次查词注入（同样是
   210KB 起步的量，内联进每次弹窗就是 BUG-1868 那条老路）。
--------------------------------------------------------------------------- */

const __dictAssetCache = new Map();      // JSON.stringify([dict, path]) -> 源码字符串 / null

function reportDictScriptError(dictName, label, error) {
    try {
        const bridge = window.flutter_inappwebview;
        if (bridge && typeof bridge.callHandler === 'function') {
            bridge.callHandler('reportJsError', {
                source: 'dictScript',
                message: `[${dictName}] ${label}: ${error && error.message ? error.message : error}`,
                stack: error && error.stack ? String(error.stack) : '',
            });
        }
    } catch (_) { /* 诊断失败不能反过来毁掉渲染 */ }
}

/* 取一份词典资源的文本。native 侧已把 .mdd 里的文件和 .mdx 旁边的散文件收进同一个
   媒体库，所以这里只有一条按名取的通道。词典引用了但根本不存在的脚本（OALDPEX 的
   oaldpex_img.js 等在包里就是缺的）返回 null，与浏览器 404 后继续跑其余脚本一致。 */
async function fetchDictAsset(dictName, path) {
    const key = JSON.stringify([dictName, path]);
    if (__dictAssetCache.has(key)) return __dictAssetCache.get(key);
    let source = null;
    try {
        const bridge = window.flutter_inappwebview;
        if (bridge && typeof bridge.callHandler === 'function') {
            const reply = await bridge.callHandler('getDictAsset', { dictionary: dictName, path });
            if (typeof reply === 'string' && reply.length) source = reply;
        }
    } catch (_) {
        source = null;
    }
    __dictAssetCache.set(key, source);
    return source;
}
