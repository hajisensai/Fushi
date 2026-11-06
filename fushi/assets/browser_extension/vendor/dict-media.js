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

/* rewriteDictLinks 的 DOM 版（BUG-3762）：在已净化的惰性 DOM（<template> 内容）上直接改写，
   调用方再 importNode 挂进文档。不能回到「改字符串 → innerHTML 再解析」：两次解析的上下文
   不同，`<math><mtext><table><mglyph><style><img onerror>` 这类结构会在第二次解析时复活脚本。
   扩展分叉与 rewriteDictLinks 同语义：__fushiDictMedia 已设时一律写无 token 的占位属性
   （TODO-1215 / BUG-1718），由 resolveDictMediaPlaceholders 取字节。 */
function rewriteDictLinksInTree(root, dictName) {
    const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
    const viaServer = !!(media && media.base && media.token);
    root.querySelectorAll('link[href]').forEach((link) => {
        const href = link.getAttribute('href');
        const replacement = link.ownerDocument.createElement('link');
        if (viaServer) {
            replacement.setAttribute('data-fushi-media-dict', encodeURIComponent(dictName));
            replacement.setAttribute('data-fushi-media-path', encodeURIComponent(href));
        } else {
            replacement.setAttribute('rel', 'stylesheet');
            replacement.setAttribute('href',
                `dictmedia://${encodeURIComponent(normalizeDictMediaPath(href))}?dictionary=${encodeURIComponent(dictName)}`);
        }
        link.replaceWith(replacement);
    });
    root.querySelectorAll('img[src]').forEach((img) => {
        const src = img.getAttribute('src');
        const rewritten = rewriteDictionaryMediaPath(src, dictName);
        if (rewritten === null) return;
        if (viaServer) {
            img.removeAttribute('src');
            img.setAttribute('data-fushi-media-dict', encodeURIComponent(dictName));
            img.setAttribute('data-fushi-media-path', encodeURIComponent(src));
        } else {
            img.setAttribute('src', rewritten);
        }
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

// 带脚本词条的沙箱文档（popup.js 的 __dictSandboxMountExtensionFrame）：上面那套兑现方落的是
// 本源 blob: URL，扩展的沙箱页（dict-sandbox.html）是不透明源，加载不了别的源建的 blob:；
// 沙箱 CSP 也只认 data: / blob:（connect-src 'none'，沙箱里不能自己取）。所以在父侧把占位
// 一次性兑现成 data:（<img>）或内联 <style>（<link>），再整串交给沙箱。token 只在 fetch 参数里，
// 不进文档。在 <template> 里改写后再序列化——这串只在沙箱里重新解析（那边本就允许脚本），
// 主文档从不解析它，没有 mXSS 问题。
async function fushiDictSandboxInlineMedia(html) {
    const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
    const source = `${html}`;
    if (!media || !media.base || !media.token || !source.includes('data-fushi-media-path')) return source;
    const template = document.createElement('template');
    template.innerHTML = source;
    const nodes = [...template.content.querySelectorAll('[data-fushi-media-path]')];
    await Promise.all(nodes.map(async (node) => {
        const encodedDict = node.getAttribute('data-fushi-media-dict') || '';
        const encodedPath = node.getAttribute('data-fushi-media-path') || '';
        node.removeAttribute('data-fushi-media-path');
        node.removeAttribute('data-fushi-media-dict');
        if (!encodedPath) return;
        const isLink = node.tagName === 'LINK';
        try {
            const response = await fetch(fushiDictMediaEndpoint(media, encodedDict, encodedPath));
            if (!response.ok) return;
            if (isLink) {
                const css = await response.text();
                const style = template.ownerDocument.createElement('style');
                style.textContent = (typeof stripDictCssRemoteRefs === 'function')
                    ? stripDictCssRemoteRefs(css) : css;
                node.replaceWith(style);
                return;
            }
            const blob = await response.blob();
            const dataUrl = await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result);
                reader.onerror = () => reject(reader.error);
                reader.readAsDataURL(blob);
            });
            if (typeof dataUrl === 'string' && dataUrl.startsWith('data:')) node.setAttribute('src', dataUrl);
        } catch (_) { /* 取不到就保持裂图/无样式，绝不阻断渲染 */ }
    }));
    return template.innerHTML;
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
    // 词典改名（v95）：popup.js 的 __fushiDictDisplayName 读这张表。缺了不会崩
    // （回落真名），但改名在扩展里就不生效。
    window.dictionaryDisplayNames =
        (data.dictionaryDisplayNames && typeof data.dictionaryDisplayNames === 'object')
            ? data.dictionaryDisplayNames : {};
    // popup.js 的 dictionaryLanguageOf 读这张表给释义区标 lang（app 内由 Dart 注入同名全局）。
    window.__fushiDictionaryLanguages =
        (data.dictionaryLanguages && typeof data.dictionaryLanguages === 'object')
            ? data.dictionaryLanguages : {};
    // 「统一词典样式」：app 内弹窗由 popup_settings_injection 注入同名全局，扩展从查词响应的
    // dictionaryUnifiedStyle 取 app 的同一个偏好。只认 true：字段缺失（旧 app / 未接线）一律关，
    // 与 app 默认值一致。不进 stylesRevision 门控——每次查词都随响应下发，改了下次查词即生效。
    window.__fushiDictUnifiedStyle = data.dictionaryUnifiedStyle === true;
    fushiApplyDictionaryFont(data);
}

// 用户在 app 里设的「词典字体」（设置 · 字体 · 词典），与 app 内弹窗同一份设置：
//   - dictionaryFontCss：按内容语言分流的字体链（用户字体接在每条链首），挂进弹窗根
//     （shadow root / 嵌套层文档），根选择器是 #entries-container；
//   - dictionaryFontFaces：[{family, src, format, weight?}]，src 是 app 端点的相对路径。
// 字体字节与图片同一约定：token 只出现在 fetch 参数里，拿到字节后 new FontFace(family, buffer)
// 注册进 document.fonts——带 token 的 URL 不进任何网页可读的样式表 / DOM。
// @font-face 写进 shadow root 本就不生效（Blink 只认文档级），FontFaceSet 是文档级的，正合适。
// 同一 realm 里每个 (family, src) 只取一次；配置还没到（__fushiDictMedia 未就绪）就留给下次渲染。
const __fushiDictFontFaces = new Map(); // family + '|' + src -> FontFace | Promise | null
let __fushiLastDictFontData = null;
// __fushiDictMedia 是异步拿到的（嵌套层 iframe 尤其常晚于首次渲染）：拿到后补一次字体。
function fushiRetryDictionaryFont() {
    if (__fushiLastDictFontData) fushiApplyDictionaryFont(__fushiLastDictFontData);
}
function fushiApplyDictionaryFont(data) {
    __fushiLastDictFontData = data;
    const css = typeof data.dictionaryFontCss === 'string' ? data.dictionaryFontCss : '';
    // 只挂弹窗根，**绝不**回落到 document.head：页面弹窗的 shadow root 要到首次渲染才建，
    // 那之前落进宿主页 <head> 的 :lang(ja) 规则会改掉整张网页的字体。根建好后由 content.js
    // 调 fushiRetryDictionaryFont 补挂。
    const root = (typeof window !== 'undefined' && window.__fushiRoot) || null;
    if (root && typeof root.getElementById === 'function') {
        let style = root.getElementById('fushi-dict-font');
        if (css) {
            if (!style) {
                style = document.createElement('style');
                style.id = 'fushi-dict-font';
                root.appendChild(style);
            }
            if (style.textContent !== css) style.textContent = css;
        } else if (style && style.parentNode) {
            style.parentNode.removeChild(style);
        }
    }

    const faces = Array.isArray(data.dictionaryFontFaces) ? data.dictionaryFontFaces : [];
    const wanted = new Set();
    for (const face of faces) {
        const family = face && typeof face.family === 'string' ? face.family.trim() : '';
        const src = face && typeof face.src === 'string' ? face.src : '';
        const weight = face && typeof face.weight === 'string' && /^\d{1,4}( \d{1,4})?$/.test(face.weight)
            ? face.weight : '';
        if (!family || !src.startsWith('/api/extension/fonts/dictionary?')) continue;
        const key = family + '|' + src;
        wanted.add(key);
        if (__fushiDictFontFaces.has(key)) continue;
        const media = (typeof window !== 'undefined') ? window.__fushiDictMedia : null;
        if (!media || !media.base || !media.token) continue;
        if (typeof FontFace !== 'function' || typeof document === 'undefined' || !document.fonts) continue;
        const url = media.base + src + '&token=' + encodeURIComponent(media.token);
        const pending = fetch(url).then((r) => (r.ok ? r.arrayBuffer() : null)).then((buffer) => {
            if (!buffer || __fushiDictFontFaces.get(key) !== pending) return null;
            // weight = 文件真实字重（'400' / '100 900'）：同一家族的常规 + 粗体文件各注册
            // 一个字面，粗体请求才会选中粗体文件而不是把常规字面合成加粗。
            const descriptors = { display: 'swap' };
            if (weight) descriptors.weight = weight;
            const fontFace = new FontFace(family, buffer, descriptors);
            document.fonts.add(fontFace);
            __fushiDictFontFaces.set(key, fontFace);
            return fontFace;
        }).catch(() => {
            // 取不到就落回字体链的下一位；记 null 防止每次渲染都重打一遍失败请求。
            if (__fushiDictFontFaces.get(key) === pending) __fushiDictFontFaces.set(key, null);
            return null;
        });
        __fushiDictFontFaces.set(key, pending);
    }
    // 用户换掉 / 停用的字体：从 document.fonts 摘掉，别让旧字体继续命中同名家族。
    for (const [key, value] of Array.from(__fushiDictFontFaces.entries())) {
        if (wanted.has(key)) continue;
        __fushiDictFontFaces.delete(key);
        if (value && typeof value.then !== 'function' && document.fonts) {
            try { document.fonts.delete(value); } catch (_) { /* 已被移除 */ }
        }
    }
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
