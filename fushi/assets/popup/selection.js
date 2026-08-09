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
    scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r"\'“”‘’«»‹›',
    sentenceDelimiters: '。！？.!?\n\r',
    trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
    brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},

    isCodePointJapanese(codePoint) {
        return JAPANESE_RANGES.some(r => codePoint >= r[0] && codePoint <= r[1]);
    },

    isScanBoundary(char) {
        return /^[\s　]$/.test(char) || this.scanDelimiters.includes(char);
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

    findParagraph(node) {
        let el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return el?.closest('p, .glossary-content') || null;
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

    getCaretRange(x, y) {
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

        this.clearSelection();
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
            while (startOffset > 0 && !this.isScanBoundary(hitContent[startOffset - 1])) {
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
                if (this.isScanBoundary(char)) break;
                text += char;
                scanOffset++;
            }

            if (scanOffset > start) {
                ranges.push({ node: scanNode, start, end: scanOffset });
            }

            if (scanOffset < content.length || text.length >= maxLength) break;

            scanNode = walker.nextNode();
            scanOffset = 0;
        }

        if (!text) return null;

        this.selection = {
            startNode,
            startOffset,
            ranges,
            text
        };

        const rect = this.getSelectionRect(x, y);
        window.flutter_inappwebview.callHandler('textSelected', text, rect);

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

    clearSelection() {
        window.getSelection()?.removeAllRanges();
        if (window.__fushiCssHighlightsSupported) {
            CSS.highlights.delete('fushi-selection');
        } else {
            this.clearHighlightWrappers();
        }
        this.selection = null;
    }
};
