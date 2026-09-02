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

/* 词典 CSS 作用域化的结果**只由** (css, dictName, scopePrefix) 决定——纯函数，
   同输入必同输出。但它的调用点是 createGlossarySection，即「每个词条的每个词典块」
   各调一次：N 条词条 × M 本词典就是 N×M 次把同一本词典那份（Yomitan 词典动辄几十 KB
   的）CSS 重新做一遍逐字符扫描（下面的 while 循环对空白字符是一个字符 push 一次数组）。
   查一次词就白烧几十上百遍完全相同的解析。
   这里按三元组做 memo：外层用 css 串本身分桶（内容变了自然落到新桶，无需失效钩子，
   也就不存在「换词典集后拿到旧作用域 CSS」的风险），内层用 dictName+scopePrefix。
   递归分支走未缓存的实现，避免把每个 at-block 的子串都塞进缓存。 */
const __dictCssCache = new Map();
const __dictCssCacheMaxBuckets = 64;

function constructDictCss(css, dictName, scopePrefix) {
    if (!css) return '';
    let byScope = __dictCssCache.get(css);
    if (byScope === undefined) {
        // 词典集切换/重新导入会带来新的 css 串；给桶数封顶，别让缓存无界增长。
        if (__dictCssCache.size >= __dictCssCacheMaxBuckets) __dictCssCache.clear();
        byScope = new Map();
        __dictCssCache.set(css, byScope);
    }
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
   词典自带脚本的执行。

   MDX 词典的条目 HTML 是一个完整网页片段：它 <link> 自己的样式表，也 <script>
   自己的脚本（NLT 词频用脚本把「頻度」列画成条形图；OALDPEX 用脚本驱动整套配置
   界面和中文翻译显示开关）。样式表走 styles.css 内联注入，脚本此前则**完全不
   执行**——经 innerHTML 插入的 <script> 按 HTML 规范永远不会跑，所以这些词典在
   我们这里只剩一个没有交互的骨架。

   这里补上执行，但**不是**放回全局作用域就完事。词典脚本是按「一个条目 = 一个
   独立文档」写的：NLT 那份直接 document.querySelectorAll('tr')，在我们这种把多本
   词典塞进同一个弹窗文档的宿主里，它会把别的词典的表格一起改掉。所以每份脚本都
   在一个把查询限制在本词典子树内的 document 代理下运行（见 createScopedDocument）。

   三条实现上的必要选择：
   - 同一个词典块的多段脚本**拼成一段**执行，因为同一文档里的多个 <script> 共享
     全局作用域：前一段的 `var oaldpexConfig = …` 后一段要看得见。每段各自包在
     try 里，一段语法/运行错误不会带走其余段。
   - 编译结果按代码串缓存：一次查词可能渲染多个词条，每个都有该词典的一块，而
     OALDPEX 的脚本有 210KB，重复解析是实打实的开销。
   - 源码经 bridge 按需取并缓存，而不是随每次查词注入——同样是 210KB 起步的量，
     内联进每次弹窗就是 BUG-1868 那条老路。
--------------------------------------------------------------------------- */

const __dictAssetCache = new Map();      // JSON.stringify([dict, path]) -> 源码字符串 / null
const __dictScriptFnCache = new Map();   // 拼接后的代码串 -> 编译好的 Function
const __dictScriptsRan = new WeakSet();  // 已经跑过脚本的词典块

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

/* 一个把「整篇文档」重定向到本词典子树的 document 代理。

   只改写按选择器找元素、以及 body/documentElement/readyState 这几处：其余属性和
   方法一律透传真 document（createElement、createTextNode、cookie……），所以 jQuery
   这类通用库照常工作，只是它的选择器看到的世界缩小到了这本词典。

   DOMContentLoaded / load / readystatechange 是必须特判的一项：弹窗是长驻页面，
   这些事件在词典脚本跑起来之前早就过去了，照原样注册等于永远不触发——而 MDict
   生态里几乎每份脚本都把入口挂在 DOMContentLoaded 上。这里立刻（微任务）回调，
   对应真实宿主里「文档已就绪」的语义。 */
function createScopedDocument(root, dictName) {
    const fireSoon = (handler, type) => {
        Promise.resolve().then(() => {
            try {
                handler.call(proxy, new Event(type));
            } catch (error) {
                reportDictScriptError(dictName, `on${type}`, error);
            }
        });
    };

    const overrides = {
        querySelector: (selector) => root.querySelector(selector),
        querySelectorAll: (selector) => root.querySelectorAll(selector),
        getElementsByClassName: (name) => root.getElementsByClassName(name),
        getElementsByTagName: (name) => root.getElementsByTagName(name),
        getElementsByName: (name) => root.querySelectorAll(`[name="${CSS.escape(name)}"]`),
        getElementById: (id) => {
            try {
                return root.querySelector(`#${CSS.escape(id)}`);
            } catch (_) {
                return null;
            }
        },
        addEventListener: (type, handler, options) => {
            if (type === 'DOMContentLoaded' || type === 'load' || type === 'readystatechange') {
                if (typeof handler === 'function') fireSoon(handler, type);
                else if (handler && typeof handler.handleEvent === 'function') {
                    fireSoon(handler.handleEvent.bind(handler), type);
                }
                return undefined;
            }
            return root.addEventListener(type, handler, options);
        },
        removeEventListener: (type, handler, options) => root.removeEventListener(type, handler, options),
    };

    const proxy = new Proxy(document, {
        get(target, prop) {
            if (Object.prototype.hasOwnProperty.call(overrides, prop)) return overrides[prop];
            if (prop === 'body' || prop === 'documentElement') return root;
            if (prop === 'readyState') return 'complete';
            const value = Reflect.get(target, prop);
            return typeof value === 'function' ? value.bind(target) : value;
        },
        set(target, prop, value) {
            // 词典脚本往 document 上挂自己的字段时，别让它落到真 document 上。
            try {
                root[`__dict_${String(prop)}`] = value;
            } catch (_) { /* 只读属性，忽略 */ }
            return true;
        },
    });
    return proxy;
}

/* 跑完一个词典块里的全部 <script>。root 是该词典的 wrapper（div[data-dictionary]），
   同时充当脚本的作用域根。执行完把 script 节点摘掉：它们已经跑过，留着只会让制卡
   导出等下游再处理一遍。 */
async function runDictScripts(root, dictName) {
    if (!root || __dictScriptsRan.has(root)) return;
    __dictScriptsRan.add(root);

    const nodes = Array.from(root.querySelectorAll('script'));
    if (!nodes.length) return;

    const chunks = [];
    const labels = [];
    for (const node of nodes) {
        const src = node.getAttribute('src');
        let code = null;
        let label = 'inline';
        if (src) {
            label = src;
            code = await fetchDictAsset(dictName, normalizeDictMediaPath(src));
        } else {
            code = node.textContent;
        }
        node.remove();
        if (!code) continue;
        // 只有段序号（数字）被拼进代码，标签本身留在数组里。词典 HTML 里的 src
        // 是外来串，而 JSON.stringify **不转义 U+2028/U+2029**——那两个字符在 JS
        // 源码里是行终结符，插进来会当场把拼接结果劈成语法错误。
        const index = labels.push(label) - 1;
        chunks.push(
            `try{\n${code}\n}catch(__dictScriptError){` +
            `__reportDictScriptError(${index}, __dictScriptError);}`
        );
    }
    if (!chunks.length) return;

    const combined = chunks.join('\n;\n');
    let factory = __dictScriptFnCache.get(combined);
    if (factory === undefined) {
        try {
            factory = new Function('document', 'window', 'self', '__reportDictScriptError', combined);
        } catch (error) {
            factory = null;  // 整段都编译不了（语法错误）；记一次，别每个词条再试一遍
            reportDictScriptError(dictName, 'compile', error);
        }
        __dictScriptFnCache.set(combined, factory);
    }
    if (!factory) return;

    const scopedDocument = createScopedDocument(root, dictName);
    try {
        factory.call(window, scopedDocument, window, window,
            (index, error) => reportDictScriptError(dictName, labels[index] ?? `#${index}`, error));
    } catch (error) {
        reportDictScriptError(dictName, 'run', error);
    }
}
