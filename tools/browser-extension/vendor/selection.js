const CJK_IDEOGRAPH_RANGES = [
    [0x4e00, 0x9fff], [0x3400, 0x4dbf], [0x20000, 0x2a6df],
    [0x2a700, 0x2b73f], [0x2b740, 0x2b81f], [0x2b820, 0x2ceaf],
    [0x2ceb0, 0x2ebef], [0x30000, 0x3134f], [0x31350, 0x323af],
    [0x2ebf0, 0x2ee5f], [0xf900, 0xfaff], [0x2f800, 0x2fa1f],
];
const JAPANESE_RANGES = [
    [0x3040, 0x309f], [0x30a0, 0x30ff],
    ...CJK_IDEOGRAPH_RANGES,
    [0xff66, 0xff9f], [0x30fb, 0x30fc], [0xff61, 0xff65], [0x3000, 0x303f],
    [0xff10, 0xff19], [0xff21, 0xff3a], [0xff41, 0xff5a],
    [0xff01, 0xff0f], [0xff1a, 0xff1f], [0xff3b, 0xff3f],
    [0xff5b, 0xff60], [0xffe0, 0xffee],
];

window.__fushiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);
window.fushiSelection = {
    selection: null,
    highlightWrappers: [],
    formImposter: null,
    formImposterSource: null,
    formImposterSig: '',
    formImposterUnlisten: null,
    scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r"\'“”‘’«»‹›',
    // BUG-2196：换行不是句子边界（HTML 里它只是空白）。与
    // reader_selection_scripts.dart 的同名表保持一致。
    sentenceDelimiters: '。！？.!?',
    trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
    brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},

    isCodePointJapanese(codePoint) {
        return JAPANESE_RANGES.some(r => codePoint >= r[0] && codePoint <= r[1]);
    },

    // BUG-1773：空白不是「词边界」的同义词，这里必须拆成两个谓词。
    //
    // isScanBoundary 回答的是「这个字符能不能是一个词的一部分」——点击命中判定
    // （点空格不查词）和词首回退用它，空白当然算边界。
    //
    // 但**前向扫描**问的是另一个问题：「查询串该在哪停」。空格分词语言里空格是
    // 词**间连接符**而非终点，把它当终点就等于把 `listen to` / `look forward to`
    // 这类短语词条整类排除在匹配之外。引擎本来就按空格分词生成三级候选
    // （`listen to music` / `listen to` / `listen`，禁止在单词中间切，见
    // native/fushidicts/fushidicts_src/scan/word_scan.cpp），单词自己不会被挤掉。
    //
    // 故：isScanStop = 真正的扫描终点（标点），**不含空白**；空白能否跨过去由
    // selectFromPosition 的桥接规则单独决定。与 reader_selection_scripts.dart
    // 的同名谓词逐条对齐（阅读器版多一条「只扫日文」门控）。
    isScanWhitespace(char) {
        return /^[\s　]$/.test(char);
    },
    isScanStop(char) {
        return this.scanDelimiters.includes(char);
    },
    isScanBoundary(char) {
        return this.isScanWhitespace(char) || this.isScanStop(char);
    },
    // BUG-3664：点词「回退到词首」还要停在词内连字符上——`time-blackened` 点 blackened
    // 不能退回 time（词典没有复合词时只能匹配出前半截 time）。只截回退、不截前向扫描：
    // 点 time 仍把 `time-blackened …` 整串交给引擎，有词条的复合词照样查得到。软连字符
    // U+00AD 不算（不可见的排版断词点）。与 reader_selection_scripts.dart 同名谓词一致。
    wordHyphenPattern: /[\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\uFE63\uFF0D]/,
    isTokenStartBoundary(char) {
        return this.isScanBoundary(char) || this.wordHyphenPattern.test(char || '');
    },

    // BUG-2056：撇号在**词内**时不是词边界。英语的缩合形与所有格（don’t / it’s /
    // John’s / we’ve）在真实 EPUB 里几乎都用排版撇号 U+2019，而它和 ASCII ' 一样躺在
    // scanDelimiters 里，于是前向扫描一撞上就 break：点 "don" 喂给引擎的查询串是
    // "don"，点 "t" 是 "t"，en.json 词形还原表里 don't 这类词条整类匹配不到。
    //
    // 判据只看上下文、不看语言：撇号两侧都是**空格分词类字母**才算词内。字母集与
    // native/fushidicts/fushidicts_src/scan/word_scan.cpp 的 is_space_delimited_letter
    // 逐区间对齐（拉丁/希腊/西里尔/亚美尼亚/希伯来/阿拉伯/格鲁吉亚），全仓一个模型。
    //   don’t / John’s / l’homme → 撇号被跨过，当一个 token 继续扫
    //   ‘hello’ world            → 右侧是空白，仍是终点（引号语义不受影响）
    //   日文/中文正文里的 ’      → 两侧非空格分词脚本，仍是终点
    //
    // **只作用于前向扫描，不动词首回退**：回退跨撇号会把法语/意大利语省音写法
    // （l’homme、dell’arte）的锚点从 homme 拖回 l’，反而查不到 homme。前向跨过是纯
    // 增益——scan_candidates 会生成 don’t / don’ / don 三级前缀，短词不会被挤掉。
    //
    // 撇号集里四个码点的**角色不同**，别当成一视同仁的白名单：
    //   ' U+0027 / ‘ U+2018 / ’ U+2019 —— 都在 scanDelimiters 里，是真正被本判据
    //     救回来的三个（U+2018 是 OCR 把 ’ 认错的常见产物：`don‘t` 原本也被截成 don）；
    //   ʼ U+02BC —— **不在** scanDelimiters 里，本来就不截断，列在这里是为了让
    //     「撇号类字符」在四份实现里是同一个集合；哪天有人把它加进 scanDelimiters，
    //     桥接已经就位。测试用不变式钉住这层耦合，而不是假装它改变了行为。
    //
    // 扫出整词只是**半条链**：查询串 don’t 还要经 native/fushidicts 的
    // text_processor 撇号归一（U+2019/U+2018/U+02BC → ASCII '）才对得上 en.json 的
    // ASCII 还原规则与 ASCII 条目键——U+2019 没有 NFKC 兼容分解，折不掉。
    //     闭环 e2e：native/fushidicts/tests/en_apostrophe_lookup_test.cpp
    intraWordApostrophePattern: /['‘’ʼ]/,
    spaceDelimitedLetterPattern: /[A-Za-z\u00AA\u00B5\u00BA\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02AF\u0370-\u03FF\u0400-\u052F\u0531-\u0556\u0561-\u0587\u05D0-\u05EA\u05EF-\u05F2\u0620-\u063F\u0641-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06EE\u06EF\u06FA-\u06FC\u06FF\u0750-\u077F\u08A0-\u08BD\u10A0-\u10C5\u10D0-\u10FA\u1E00-\u1EFF\u1F00-\u1FFF]/,
    isSpaceDelimitedLetter(char) {
        return char !== undefined && this.spaceDelimitedLetterPattern.test(char);
    },
    isIntraWordApostrophe(text, index) {
        return this.intraWordApostrophePattern.test(text[index] || '') &&
            this.isSpaceDelimitedLetter(text[index - 1]) &&
            this.isSpaceDelimitedLetter(text[index + 1]);
    },

    // BUG-1645：元素是否「同一行内连排」的 inline 盒。块级/列表项/表格单元/flex/grid
    // 在用户眼里就是换行或分栏，两侧文字不可能是同一个词。
    //
    // BUG-1659：判据必须是「inline-level 盒」这个概念本身，不是它的某个枚举
    // 子集。原先写死 `display === 'inline'`，把 inline-block / inline-flex /
    // inline-grid / inline-table 这些同样排在同一行上的盒子一律当成了断点。
    // 而 popup.css 的 `.ruby-unit` 正是 `display: inline-block`（每个振假名单元一
    // 个），于是查词浮窗 glossary 里任何带振假名的词扫到第一个 ruby 单元就断：
    // 「打ち合わせ」只剩下「打」。
    //
    // 拿不到样式（或拿不到 display）时返回 true，保持旧的跨节点续扫行为，
    // 不引入新的失败模式。
    isInlineBox(element) {
        const style = window.getComputedStyle?.(element);
        if (!style) return true;
        const display = style.display;
        if (!display) return true;
        return display.startsWith('inline') || display === 'contents' ||
            display.startsWith('ruby');
    },

    // BUG-1645：元素的 ::before/::after 生成内容是否是真实分隔符。compact 释义模式下
    // `li::after { content: " | " }` 只存在于渲染树，DOM 里没有对应文本节点——不查
    // 伪元素就会把视觉上分开的两条释义当成连排文字。
    hasGeneratedContent(element, pseudo) {
        const content = window.getComputedStyle?.(element, pseudo)?.content;
        return !!content && content !== 'none' && content !== 'normal' &&
            content !== '""' && content !== "''";
    },

    // BUG-1645：跨文本节点续扫时，[from] 与 [to] 之间是否存在「渲染上的断点」。
    //
    // 取词扫描把相邻文本节点直接首尾相接，这对日语无害（CJK 不是空格分词脚本，
    // C++ scan_candidates 可以在任意码点处切分，粘多了自然被切掉），但对拉丁语系
    // 是致命的：scan_candidates 明确禁止「在单词中间切」，于是把两条相邻释义粘成的
    // `acridpungent` 永远还原不出 `acrid` —— 嵌套查词点英文注释里的词必然无结果。
    //
    // 判据是渲染盒边界而不是「两侧都是字母就断」：`<b>ac</b>rid` 这种行内标记拆开的
    // 单词必须继续粘（inline 盒，无断点），`<li>acrid</li><li>pungent</li>` 这种
    // 相邻释义必须断开（list-item 盒 / compact 模式下的 ::after 分隔符）。
    crossesRenderBoundary(from, to) {
        const fromElement = from?.parentElement;
        const toElement = to?.parentElement;
        if (!fromElement || !toElement || fromElement === toElement) return false;

        const fromAncestors = new Set();
        for (let el = fromElement; el; el = el.parentElement) fromAncestors.add(el);
        let common = null;
        for (let el = toElement; el; el = el.parentElement) {
            if (fromAncestors.has(el)) { common = el; break; }
        }

        // 离开 from 一侧：出边界的元素自身是块盒，或它在文字后面吐了生成内容。
        for (let el = fromElement; el && el !== common; el = el.parentElement) {
            if (!this.isInlineBox(el) || this.hasGeneratedContent(el, '::after')) return true;
        }
        // 进入 to 一侧：同理，看的是 ::before。
        for (let el = toElement; el && el !== common; el = el.parentElement) {
            if (!this.isInlineBox(el) || this.hasGeneratedContent(el, '::before')) return true;
        }
        return false;
    },

    isFurigana(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('rt, rp');
    },

    isIgnoredLookupText(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        // postProcessRuby inserts a hidden copy of each reading before its base
        // to reserve inline width. It is layout-only, just like <rt>/<rp>, and
        // must not leak into mixed kanji/kana lookup scans (打ち合わせ, etc.).
        return this.isFurigana(node) || !!el?.closest('.ruby-reserve');
    },

    resolveRubyBase(node) {
        const rubyEl = node.parentElement?.closest('ruby');
        if (!rubyEl) return null;
        const walker = document.createTreeWalker(rubyEl, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => this.isIgnoredLookupText(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
        const base = walker.nextNode();
        return base ? { node: base, offset: 0 } : null;
    },

    // 文本节点所在的 ruby 基字段：{ nodes: 该段基字文本节点（文档序）, reading: 配对的
    // <rt> 文本 }。一个 <ruby> 可有多对基字 / rt；postProcessRuby 之后每个基字被包进
    // .ruby-unit、rt 被包进 .ruby-rt 并多出 .ruby-reserve 读音副本，所以这里递归下降，
    // 并用 isIgnoredLookupText 排除 reserve / rt / rp 文本（与取词串的构造口径一致）。
    // 只用 DOM 里现成的 <rt> 文本，绝不推断读音。cache 是一次取词内 ruby → 段表缓存。
    rubySegmentOf(node, cache) {
        if (!node || this.isIgnoredLookupText(node)) return null;
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        const ruby = el && el.closest ? el.closest('ruby') : null;
        if (!ruby) return null;
        let segments = cache.get(ruby);
        if (!segments) {
            segments = [];
            let pending = [];
            const self = this;
            const collect = (n) => {
                if (n.nodeType === Node.TEXT_NODE) {
                    if (self.isIgnoredLookupText(n)) return;
                    if (!/^[\s　]*$/.test(n.nodeValue || '')) pending.push(n);
                    return;
                }
                if (n.nodeType !== Node.ELEMENT_NODE) return;
                const tag = n.tagName;
                if (tag === 'RT') {
                    segments.push({ nodes: pending, reading: (n.textContent || '').trim() });
                    pending = [];
                    return;
                }
                if (tag === 'RP' || tag === 'RTC') return;
                for (let c = n.firstChild; c; c = c.nextSibling) collect(c);
            };
            for (let c = ruby.firstChild; c; c = c.nextSibling) collect(c);
            cache.set(ruby, segments);
        }
        for (let i = 0; i < segments.length; i++) {
            if (segments[i].nodes.indexOf(node) >= 0) return segments[i];
        }
        return null;
    },

    // 查询串 text（= ranges 各段依次拼接）里**完整**落在选区内的 ruby 基字：
    // [{ s, e, r }]，s/e 为 text 内 UTF-16 区间，r 为来源自带的 <rt> 读音。基字只被
    // 扫到一部分的不报；text 不是各段的精确拼接时整体不报（坐标会错位）。
    rubyReadingSpans(ranges, text) {
        const spans = [];
        const cache = new Map();
        let pos = 0;
        let open = null;
        for (let i = 0; i < ranges.length; i++) {
            const range = ranges[i];
            const length = range.end - range.start;
            if (text.substr(pos, length) !== (range.node.nodeValue || '').slice(range.start, range.end)) {
                return [];
            }
            const seg = this.rubySegmentOf(range.node, cache);
            const full = range.start === 0 && range.end === (range.node.nodeValue || '').length;
            if (!seg || !seg.reading || !full) {
                open = null;
            } else {
                const index = seg.nodes.indexOf(range.node);
                if (index === 0) {
                    open = { seg, start: pos, next: 1 };
                } else if (!open || open.seg !== seg || open.next !== index) {
                    open = null;
                } else {
                    open.next = index + 1;
                }
                if (open && open.next === seg.nodes.length) {
                    spans.push({ s: open.start, e: pos + length, r: seg.reading });
                    open = null;
                }
            }
            pos += length;
        }
        if (pos !== text.length) return [];
        return spans;
    },

    findParagraph(node) {
        let el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        // 表单控件镜像自成一段：句子不越出字段去拼宿主页其它文字。
        return el?.closest('p, .glossary-content, .fushi-form-imposter') || null;
    },

    createWalker(rootNode) {
        const root = rootNode || document.body;
        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => this.isIgnoredLookupText(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
    },

    inCharRange(charRange, x, y) {
        const rects = charRange.getClientRects();
        if (rects.length) {
            for (const rect of rects) {
                if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
                    return true;
                }
            }
            return false;
        }
        const rect = charRange.getBoundingClientRect();
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
    },

    // 穿透 open shadow DOM，返回命中点最深的元素。
    // document.elementFromPoint / caretPositionFromPoint 只在顶层 document 内下钻，
    // 命中 <bili-comments> 这类 Web Component（shadow root 渲染）时只返回宿主
    // 元素而非内部文字节点，取词会失败（Yomitan 能读、旧版 Hibiki 读不了的根因）。
    // 这里沿每一层 element.shadowRoot 逐层 elementFromPoint 下钻到真正承载文字的元素。
    deepElementFromPoint(x, y) {
        let element = document.elementFromPoint(x, y);
        let guard = 0;
        while (element && element.shadowRoot && guard++ < 32) {
            const inner = element.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === element) break;
            element = inner;
        }
        return element;
    },

    // 在给定容器子树内逐字做几何命中，返回坍缩到命中字符的 range；未命中返回 null。
    charRangeInContainer(container, x, y) {
        const walker = this.createWalker(container);
        const range = document.createRange();
        let node;
        while (node = walker.nextNode()) {
            const len = node.textContent.length;
            for (let i = 0; i < len; i++) {
                range.setStart(node, i);
                range.setEnd(node, i + 1);
                if (this.inCharRange(range, x, y)) {
                    range.collapse(true);
                    return range;
                }
            }
        }
        return null;
    },

    // 表单控件取词（asbplayer「Anki Export」对话框的 Sentence / Word 等字段）：<textarea> / 文字类
    // <input> 的内容不是 DOM 文本节点（在 UA shadow 里），caret API 只给回控件或外层元素，下面三步
    // 全部落空。仿 Yomitan TextSourceGenerator 的 imposter：叠一个复刻计算样式、文字 = value 的镜像
    // div，在镜像上取词。镜像要活到下一次取词 / clearSelection——选区 ranges 指向镜像的文本节点，
    // 高亮与锚点都按它量；平时 pointer-events:none，不挡用户点进控件输入。
    // 选区高亮要看得见：镜像本身不透明度为 1，但字、背景、边框、阴影、滚动条全透明，只剩
    // ::highlight(fushi-selection)（或无 Highlight API 时的 .fushi-dict-highlight）的半透明底色叠在
    // 控件真字上——控件的值、焦点、选区一概不碰。控件被输入 / 滚动 / 视口变化后镜像几何就过期了，
    // 当场拆掉（高亮随之消失），不留一块错位的高亮盖在别人的字段上。
    formControlAt(x, y) {
        const el = this.deepElementFromPoint(x, y);
        if (!el || el.nodeType !== Node.ELEMENT_NODE) return null;
        if (el.tagName === 'TEXTAREA') return el;
        if (el.tagName === 'INPUT' && ['text', 'search', 'url', 'email', 'tel'].includes(String(el.type || 'text').toLowerCase())) return el;
        return null;
    },

    removeFormImposter() {
        if (this.formImposterUnlisten) { try { this.formImposterUnlisten(); } catch (_) {} }
        this.formImposterUnlisten = null;
        if (this.formImposter && this.formImposter.parentNode) this.formImposter.parentNode.removeChild(this.formImposter);
        this.formImposter = null;
        this.formImposterSource = null;
        this.formImposterSig = '';
    },

    // 镜像是否还对得上控件：几何（视口坐标）+ 控件内滚动 + 值。
    formControlSig(el) {
        const rect = el.getBoundingClientRect();
        return [rect.left, rect.top, rect.width, rect.height, el.scrollTop, el.scrollLeft, String(el.value || '')].join('|');
    },

    ensureFormImposter(el) {
        const rect = el.getBoundingClientRect();
        const value = String(el.value || '');
        const sig = this.formControlSig(el);
        // 同一控件、几何与内容都没变：复用，选区 ranges 指向的文本节点保持有效。
        if (this.formImposter && this.formImposter.isConnected &&
            this.formImposterSource === el && this.formImposterSig === sig) return this.formImposter;
        this.removeFormImposter();
        if (!value) return null;
        const style = window.getComputedStyle(el);
        const div = document.createElement('div');
        for (let i = 0; i < style.length; i++) {
            const prop = style[i];
            try { div.style.setProperty(prop, style.getPropertyValue(prop)); } catch (_) {}
        }
        const isTextarea = el.tagName === 'TEXTAREA';
        // textarea 末尾换行在 div 里不占行，补一个让最后一行几何对齐。
        div.textContent = isTextarea && value.endsWith('\n') ? value + '\n' : value;
        const set = (prop, v) => div.style.setProperty(prop, v, 'important');
        set('position', 'fixed');
        set('left', rect.left + 'px');
        set('top', rect.top + 'px');
        set('width', rect.width + 'px');
        set('height', rect.height + 'px');
        set('box-sizing', 'border-box');
        set('margin', '0');
        set('transform', 'none');
        set('transition', 'none');
        set('animation', 'none');
        set('display', 'block');
        set('visibility', 'visible');
        set('opacity', '1');
        // 墨水全透明：真字仍由控件自己画，镜像只贡献选区高亮的底色。
        set('color', 'transparent');
        set('-webkit-text-fill-color', 'transparent');
        set('caret-color', 'transparent');
        set('text-shadow', 'none');
        set('text-decoration-color', 'transparent');
        set('background', 'transparent');
        set('border-color', 'transparent');
        set('border-style', 'solid');
        set('outline', 'none');
        set('box-shadow', 'none');
        set('filter', 'none');
        set('backdrop-filter', 'none');
        set('z-index', '2147483647');
        set('pointer-events', 'none');
        set('overflow-x', 'hidden');
        if (isTextarea) {
            set('white-space', 'pre-wrap');
            set('overflow-wrap', 'break-word');
            // 控件有竖滚动条时它占掉内容宽度：镜像不画滚动条（会盖在控件的滚动条上），改用等宽的
            // 右内边距占位，换行位置才一致。
            set('overflow-y', 'hidden');
            const px = (v) => parseFloat(v) || 0;
            const scrollbar = Math.max(0, el.offsetWidth - el.clientWidth -
                px(style.borderLeftWidth) - px(style.borderRightWidth));
            if (scrollbar > 0) set('padding-right', (px(style.paddingRight) + scrollbar) + 'px');
        } else {
            // 单行 input 文字竖直居中：行高 = 内容盒高度。
            const px = (v) => parseFloat(v) || 0;
            const inner = rect.height - px(style.paddingTop) - px(style.paddingBottom) -
                px(style.borderTopWidth) - px(style.borderBottomWidth);
            set('white-space', 'pre');
            set('overflow-y', 'hidden');
            set('line-height', Math.max(0, inner) + 'px');
        }
        div.className = 'fushi-form-imposter';
        div.setAttribute('aria-hidden', 'true');
        (document.body || document.documentElement).appendChild(div);
        div.scrollTop = el.scrollTop;
        div.scrollLeft = el.scrollLeft;
        this.formImposter = div;
        this.formImposterSource = el;
        this.formImposterSig = sig;
        // 几何过期即拆：控件被输入改值、控件或其祖先滚动、视口缩放后，按同一签名复核——真变了才拆
        //（别处滚动、尺寸没变的 resize 不动它）。
        const dropIfStale = () => {
            if (this.formImposterSource === el && this.formControlSig(el) !== this.formImposterSig) this.removeFormImposter();
        };
        el.addEventListener('input', dropIfStale, true);
        window.addEventListener('scroll', dropIfStale, true);
        window.addEventListener('resize', dropIfStale, true);
        this.formImposterUnlisten = () => {
            el.removeEventListener('input', dropIfStale, true);
            window.removeEventListener('scroll', dropIfStale, true);
            window.removeEventListener('resize', dropIfStale, true);
        };
        return div;
    },

    caretRangeInFormControl(el, x, y) {
        const imposter = this.ensureFormImposter(el);
        if (!imposter) return null;
        const inside = (node) => !!node && node.nodeType === Node.TEXT_NODE && imposter.contains(node);
        // 只在测这一下时让镜像可命中（caret API 走命中测试，pointer-events:none 的元素会被跳过）。
        imposter.style.setProperty('pointer-events', 'auto', 'important');
        let range = null;
        try {
            if (document.caretPositionFromPoint) {
                const pos = document.caretPositionFromPoint(x, y);
                if (pos && inside(pos.offsetNode)) {
                    range = document.createRange();
                    range.setStart(pos.offsetNode, pos.offset);
                    range.collapse(true);
                }
            }
            if (!range && document.caretRangeFromPoint) {
                const r = document.caretRangeFromPoint(x, y);
                if (r && inside(r.startContainer)) range = r;
            }
            if (!range) range = this.charRangeInContainer(imposter, x, y);
        } finally {
            imposter.style.setProperty('pointer-events', 'none', 'important');
        }
        return range;
    },

    getCaretRange(x, y) {
        // 0) 命中表单控件：在镜像 div 上取词（见 formControlAt）。不是控件就丢掉上一次的镜像。
        const control = this.formControlAt(x, y);
        if (control) return this.caretRangeInFormControl(control, x, y);
        this.removeFormImposter();
        // 1) 原生 caret 优先：命中普通文本最省事，部分新版浏览器也会自动穿透 shadow DOM。
        //    仅当命中的是真正的文本节点时采纳；命中元素（典型：shadow 宿主）则继续下探。
        if (document.caretPositionFromPoint) {
            const pos = document.caretPositionFromPoint(x, y);
            if (pos && pos.offsetNode && pos.offsetNode.nodeType === Node.TEXT_NODE) {
                const range = document.createRange();
                range.setStart(pos.offsetNode, pos.offset);
                range.collapse(true);
                return range;
            }
        }
        // 2) caret 落在元素上（命中 Web Component 的 shadow 宿主）或浏览器无
        //    caretPositionFromPoint：穿透 shadow DOM 到最深元素，在其内逐字几何命中。
        const element = this.deepElementFromPoint(x, y);
        if (element) {
            const container = element.closest('p, div, span, ruby, a')
                || (element.nodeType === Node.ELEMENT_NODE ? element : document.body);
            const hit = this.charRangeInContainer(container, x, y);
            if (hit) return hit;
        }
        // 3) 兜底：webkit 专有 caretRangeFromPoint（同样不穿 shadow，保留旧行为）。
        return document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    },

    getCharacterAtPoint(x, y) {
        const range = this.getCaretRange(x, y);
        if (!range) return null;

        let node = range.startContainer;
        if (node.nodeType !== Node.TEXT_NODE) return null;
        if (this.isFurigana(node)) {
            const resolved = this.resolveRubyBase(node);
            if (!resolved) return null;
            node = resolved.node;
            const text = node.textContent;
            for (const offset of [resolved.offset, 0]) {
                if (offset >= 0 && offset < text.length && !this.isScanBoundary(text[offset])) {
                    return { node, offset };
                }
            }
            return null;
        }

        const text = node.textContent;
        const caret = range.startOffset;

        for (const offset of [caret, caret - 1, caret + 1]) {
            if (offset < 0 || offset >= text.length) continue;
            const charRange = document.createRange();
            charRange.setStart(node, offset);
            charRange.setEnd(node, offset + 1);
            if (this.inCharRange(charRange, x, y)) {
                if (this.isScanBoundary(text[offset])) return null;
                return { node, offset };
            }
        }

        return null;
    },

    getSentence(startNode, startOffset) {
        const container = this.findParagraph(startNode) || document.body;
        const walker = this.createWalker(container);

        walker.currentNode = startNode;
        const partsBefore = [];
        let node = startNode;
        let limit = startOffset;

        while (node) {
            const text = node.textContent;
            let foundStart = false;
            for (let i = limit - 1; i >= 0; i--) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    partsBefore.push(text.slice(i + 1, limit));
                    foundStart = true;
                    break;
                }
            }
            if (foundStart) break;
            partsBefore.push(text.slice(0, limit));
            node = walker.previousNode();
            if (node) limit = node.textContent.length;
        }

        walker.currentNode = startNode;
        const partsAfter = [];
        node = startNode;
        let start = startOffset;

        while (node) {
            const text = node.textContent;
            let foundEnd = false;
            for (let i = start; i < text.length; i++) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    let end = i + 1;
                    while (end < text.length) {
                        if (!this.trailingSentenceChars.includes(text[end])) break;
                        end += 1;
                    }
                    partsAfter.push(text.slice(start, end));
                    foundEnd = true;
                    break;
                }
            }
            if (foundEnd) break;
            partsAfter.push(text.slice(start));
            node = walker.nextNode();
            start = 0;
        }

        let sentence = (partsBefore.reverse().join('') + partsAfter.join('')).trim();

        const closeBrackets = new Set(Object.values(this.brackets));
        const openBrackets = new Set(Object.keys(this.brackets));
        let stack = [];
        let unmatchedClose = [];

        for (let i = 0; i < sentence.length; i++) {
            const ch = sentence[i];
            if (openBrackets.has(ch)) {
                stack.push(ch);
            } else if (closeBrackets.has(ch)) {
                if (stack.length > 0 && this.brackets[stack[stack.length-1]] === ch) {
                    stack.pop();
                } else {
                    unmatchedClose.push(ch);
                }
            }
        }

        let startSlice = 0;
        while (stack.length > 0 && startSlice < sentence.length - 1) {
            if (stack[0] === sentence[startSlice]) {
                stack.shift();
            } else break;
            startSlice++;
        }

        let endSlice = sentence.length - 1;
        let endIdx = sentence.length - 1;
        while (unmatchedClose.length > 0 && endIdx > startSlice) {
            if (unmatchedClose[unmatchedClose.length - 1] === sentence[endIdx]) {
                unmatchedClose.pop();
                endSlice = endIdx - 1;
            } else if (!this.sentenceDelimiters.includes(sentence[endIdx])) break;
            endIdx--;
        }
        return sentence.slice(startSlice, endSlice + 1).trim();
    },

    selectText(x, y, maxLength) {
        const hit = this.getCharacterAtPoint(x, y);

        if (!hit) {
            this.clearSelection();
            return null;
        }

        if (this.selection &&
            hit.node === this.selection.startNode &&
            hit.offset === this.selection.startOffset) {
            this.clearSelection();
            return null;
        }

        // 保留刚建的表单控件镜像：hit.node 就在它里面。
        this.clearSelection(true);
        return this.selectFromPosition(hit.node, hit.offset, maxLength, x, y);
    },

    // Build the popup word selection starting at (node, offset): expand a
    // non-Japanese hit left to its token start, scan forward up to maxLength
    // chars, and fire textSelected (→ a deeper lookup). Shared by the tap path
    // (selectText) and the keyboard/gamepad caret (window.fushiCaret.lookup).
    // x/y are optional — the caret omits them, so the rect falls back to the
    // first char's bounding box. Caller clears any prior selection first.
    selectFromPosition(node, offset, maxLength, x, y) {
        const startNode = node;
        let startOffset = offset;
        const hitContent = startNode.textContent;
        if (startOffset < hitContent.length && !this.isCodePointJapanese(hitContent.codePointAt(startOffset))) {
            while (startOffset > 0 && !this.isTokenStartBoundary(hitContent[startOffset - 1])) {
                startOffset--;
            }
        }

        const container = this.findParagraph(startNode) || document.body;
        const walker = this.createWalker(container);

        let text = '';
        let scanNode = startNode;
        let scanOffset = startOffset;
        let ranges = [];

        walker.currentNode = scanNode;
        while (text.length < maxLength && scanNode) {
            const content = scanNode.textContent;
            const start = scanOffset;

            while (scanOffset < content.length && text.length < maxLength) {
                const char = content[scanOffset];
                // BUG-2056：词内撇号先于终点判定跨过去（don’t 不被截成 don）。
                if (this.isIntraWordApostrophe(content, scanOffset)) {
                    text += char;
                    scanOffset++;
                    continue;
                }
                if (this.isScanStop(char)) break;
                // BUG-1773：空白只当**同一文本节点内**的词间连接符跨过去，且只跨
                // 一个：左边必须已有本节点扫入的内容（`scanOffset === start` 即本节点
                // 开头，不桥接），右边必须紧跟一个可扫字符。于是本节点开头/末尾的
                // 空白、连续空白、空白后接标点一律终止；跨节点续扫走下面的 walker
                // 分支（那里由 crossesRenderBoundary 判渲染断点），新节点开头的空白
                // 同样不吃。
                if (this.isScanWhitespace(char)) {
                    const nextChar = content[scanOffset + 1];
                    if (scanOffset === start || nextChar === undefined ||
                        this.isScanWhitespace(nextChar) || this.isScanStop(nextChar)) break;
                }
                text += char;
                scanOffset++;
            }

            if (scanOffset > start) {
                ranges.push({ node: scanNode, start, end: scanOffset });
            }

            if (scanOffset < content.length || text.length >= maxLength) break;

            // BUG-1645：只有当下一个文本节点与当前节点在渲染上连排时才继续粘。
            const nextNode = walker.nextNode();
            if (!nextNode || this.crossesRenderBoundary(scanNode, nextNode)) break;
            scanNode = nextNode;
            scanOffset = 0;
        }

        if (!text) return null;

        const rubyReadings = this.rubyReadingSpans(ranges, text);
        this.selection = {
            startNode,
            startOffset,
            ranges,
            text,
            rubyReadings
        };

        const rect = this.getSelectionRect(x, y);
        window.flutter_inappwebview.callHandler('textSelected', text, rect, rubyReadings);

        return text;
    },

    getSelectionRect(x, y) {
        if (!this.selection?.ranges.length) return null;
        const first = this.selection.ranges[0];
        const range = document.createRange();
        range.setStart(first.node, first.start);
        range.setEnd(first.node, first.start + 1);
        const rects = Array.from(range.getClientRects());
        const rect = rects.find(r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom)
            ?? range.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    },

    highlightSelection(charCount) {
        if (!this.selection?.ranges.length) return null;
        const trimmedRanges = [];
        let remaining = charCount;

        for (const r of this.selection.ranges) {
            if (remaining <= 0) break;

            let end = r.start;
            while (end < r.end && remaining > 0) {
                const char = String.fromCodePoint(r.node.textContent.codePointAt(end));
                end += char.length;
                remaining--;
            }
            trimmedRanges.push({ node: r.node, start: r.start, end });
        }

        let bounds = null;
        for (const seg of trimmedRanges) {
            const range = document.createRange();
            range.setStart(seg.node, seg.start);
            range.setEnd(seg.node, seg.end);
            for (const r of range.getClientRects()) {
                if (!bounds) {
                    bounds = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
                } else {
                    if (r.left < bounds.left) bounds.left = r.left;
                    if (r.top < bounds.top) bounds.top = r.top;
                    if (r.right > bounds.right) bounds.right = r.right;
                    if (r.bottom > bounds.bottom) bounds.bottom = r.bottom;
                }
            }
        }

        if (window.__fushiCssHighlightsSupported) {
            const highlights = trimmedRanges.map(seg => {
                const range = document.createRange();
                range.setStart(seg.node, seg.start);
                range.setEnd(seg.node, seg.end);
                return range;
            });
            CSS.highlights.set('fushi-selection', new Highlight(...highlights));
        } else {
            this.clearHighlightWrappers();
            const range = document.createRange();
            for (let i = trimmedRanges.length - 1; i >= 0; i--) {
                const seg = trimmedRanges[i];
                range.setStart(seg.node, seg.start);
                range.setEnd(seg.node, seg.end);
                const wrapper = document.createElement('span');
                wrapper.className = 'fushi-dict-highlight';
                wrapper.appendChild(range.extractContents());
                range.insertNode(wrapper);
                this.highlightWrappers.push(wrapper);
            }
            this.highlightWrappers.reverse();
        }

        return bounds ? { x: bounds.left, y: bounds.top, width: bounds.right - bounds.left, height: bounds.bottom - bounds.top } : null;
    },

    clearHighlightWrappers() {
        for (const wrapper of this.highlightWrappers) {
            const parent = wrapper.parentNode;
            if (!parent) continue;
            while (wrapper.firstChild) {
                parent.insertBefore(wrapper.firstChild, wrapper);
            }
            parent.removeChild(wrapper);
            parent.normalize();
        }
        this.highlightWrappers = [];
    },

    clearSelection(keepFormImposter) {
        if (!keepFormImposter) this.removeFormImposter();
        window.getSelection()?.removeAllRanges();
        if (window.__fushiCssHighlightsSupported) {
            CSS.highlights.delete('fushi-selection');
        } else {
            this.clearHighlightWrappers();
        }
        this.selection = null;
    }
};
