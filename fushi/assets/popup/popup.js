/* BUG-688: Shadow-DOM isolation. content.js renders this popup inside a shadow
   root (window.__fushiRoot) so host-page CSS can't pierce it. Route every DOM
   lookup / overlay append / selection / height read through these helpers so they
   resolve inside the shadow (fall back to document before the shadow exists). */
function __fushiRootNode(){ return window.__fushiRoot || document; }
function __fushiContainer(){ var r = window.__fushiRoot; return r ? r.querySelector('#entries-container') : document.getElementById('entries-container'); }
function __fushiOverlayParent(){ return window.__fushiRoot || document.body; }
function __fushiScrollHeight(){ var c = __fushiContainer(); return c ? c.scrollHeight : document.body.scrollHeight; }
function __fushiSel(){ var r = window.__fushiRoot; try { return (r && r.getSelection) ? r.getSelection() : window.getSelection(); } catch(_){ return window.getSelection(); } }
/* BUG-1078: composedPath() allocates a fresh array on every call and the wheel
   handler used to call it at least twice per event (__fushiEventTarget +
   __fushiWheelScroller). Cache the path on the event object for the duration of
   its dispatch so every helper shares ONE composedPath() result. */
function __fushiComposedPath(e){ if (e.__fushiPathCache !== undefined) return e.__fushiPathCache; var p = null; try { p = (e.composedPath && e.composedPath()) || null; } catch(_){ p = null; } try { e.__fushiPathCache = p; } catch(_){} return p; }
function __fushiEventTarget(e){ var p = __fushiComposedPath(e); if (p && p.length) return p[0]; return e.target; }
// 浏览器扩展把 popup.js 与宿主页面/原生 Side Panel 运行在同一 document。共享的
// document 级鼠标监听必须只消费词典 Shadow DOM 内的事件；否则 click 会清掉字幕区的
// 原生双击选区，mousemove 也会在宿主文本上启动词典取词。app 内没有 __fushiRoot，
// 整份 document 就是词典，保持原行为。
function __fushiEventInsidePopup(e){
    var root = window.__fushiRoot;
    if (!root) {
        var extensionPage = typeof chrome !== 'undefined' && !!(chrome.runtime && chrome.runtime.id);
        return !extensionPage;
    }
    var host = root.host;
    if (!host) return false;
    try {
        var path = __fushiComposedPath(e);
        return !!(path && path.indexOf(host) !== -1);
    } catch (_) {
        return false;
    }
}
/* BUG-688: the extension floating popup scrolls on the SHADOW HOST
   (#hibiki-popup-host has overflow-y:auto + max-height; #entries-container is
   neutralized to overflow:visible inside the shadow), while the in-app popup
   scrolls the document itself. These two resolve the wheel-scroll surface:
   - __fushiShadowHost(): the shadow host element, or null in-app / pre-shadow.
   - __fushiWheelScroller(e): the host ONLY when the wheel event originated
     inside the popup shadow (composedPath crosses it); null means "scroll the
     window" (in-app popup document, or the host page outside the popup). */
function __fushiShadowHost(){ var r = window.__fushiRoot; return (r && r.host) ? r.host : null; }
function __fushiWheelScroller(e){
    var host = __fushiShadowHost();
    if (!host) return null;
    try { var p = __fushiComposedPath(e); if (p && p.indexOf(host) !== -1) return host; } catch(_){}
    return null;
}

/* TODO-1392 观测性根治：查词弹窗 JS 渲染路径（renderPopup / __fushiContainer 等）抛异常，
   此前 caught 的只 console.error → onConsoleMessage → debugPrint（不进错误日志），uncaught
   更彻底静默（本文件此前无 window.onerror）。BUG-706 那类 __fushiRoot 命名冲突致 renderPopup
   TypeError 中止时，用户看到「弹窗空白 + 错误日志为空」无从排查。这里在最顶层装全局错误上报：
   uncaught error / 未处理 Promise rejection 经已有 flutter_inappwebview 桥把 {source,message,
   stack} 回传到 Dart 的 reportJsError handler，落 ErrorLogService（错误日志页可见）。
   window.__fushiReportJsError 也暴露给渲染路径的 deliberate catch 显式上报（见 renderPopup）。
   浏览器扩展镜像里 window.flutter_inappwebview 不存在，callHandler 缺失时静默 no-op（三镜像
   逐字节一致，扩展侧安全）；上报本身失败绝不再抛，杜绝二次错误递归。 */
window.__fushiReportJsError = function(source, message, stack) {
    try {
        var bridge = window.flutter_inappwebview;
        if (bridge && typeof bridge.callHandler === 'function') {
            bridge.callHandler('reportJsError', {
                source: String(source == null ? 'unknown' : source),
                message: String(message == null ? '' : message),
                stack: String(stack == null ? '' : stack)
            });
        }
    } catch (_) { /* 上报失败静默，避免二次错误 */ }
};
// 只在真浏览器 / WebView（window.addEventListener 存在）注册全局监听。Node 行为测试
// harness（vm.runInContext + stub window，无 addEventListener）与任何非浏览器宿主下跳过——
// __fushiReportJsError 仍已定义（渲染 catch 直接调），只是这里不挂 window 事件，故 popup.js
// 在 node 单测里照常加载执行，不因顶层 addEventListener 抛错而整体加载失败。
(function installPopupGlobalErrorListeners() {
    if (typeof window === 'undefined'
        || typeof window.addEventListener !== 'function') {
        return;
    }
    window.addEventListener('error', function(e) {
        /* 只报脚本运行时错误：资源加载错误（img/script 404）的 error 事件不冒泡到 window，
           故 bubbling 阶段这里收到的都是 uncaught 脚本异常。有 error.stack 用它，否则退到
           file:line:col。 */
        var err = e && e.error;
        var message = (e && e.message) ? e.message : (err ? String(err) : 'unknown error');
        var stack = (err && err.stack) ? err.stack
            : ((e && e.filename ? e.filename : '') + ':' + ((e && e.lineno) || 0) + ':' + ((e && e.colno) || 0));
        window.__fushiReportJsError('window.onerror', message, stack);
    });
    window.addEventListener('unhandledrejection', function(e) {
        var reason = e && e.reason;
        var message = (reason && reason.message) ? reason.message : String(reason);
        var stack = (reason && reason.stack) ? reason.stack : '';
        window.__fushiReportJsError('unhandledrejection', message, stack);
    });
})();

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

// TODO-270 D: tri-state mine button — "overwrite the latest mined card".
//
// After a successful mine that returned a backend note id (AnkiConnect only),
// remember WHICH word was the latest card so its ✓ becomes a green
// "editable" ✓⤺: clicking it again UPDATES that same note (repo.updateMinedNote)
// instead of deleting+re-creating. Mining a different word, or re-querying,
// supersedes the previous latest — only the single most-recently-mined word in
// this popup session stays editable; older ones fall back to an ordinary ✓.
//
// `lastMinedNoteId` is the note id to overwrite; `lastMinedEntryKey` identifies
// which expression / reading owns that id. AnkiDroid never returns an id
// (noteId stays null) → the latest state is never entered → graceful degrade to
// the existing two-state behaviour.
let lastMinedNoteId = null;
let lastMinedEntryKey = null;

// Stable identity for a popup entry (expression + reading): the same key the
// Dart side and the lookup-time duplicateCheck use.
function mineEntryKey(expression, reading) {
    return `${expression || ''}\u0000${reading || ''}`;
}

// Normalize the mineEntry/updateEntry handler reply into {ankiConnect, noteId}.
// The Dart handler now returns the structured MinePopupResult JSON; older/edge
// returns (a bare boolean, or null) are tolerated so a handler that has not been
// wired for updates still drives the ✓ refresh exactly as before.
function parseMineResult(reply) {
    if (reply && typeof reply === 'object') {
        const rawId = reply.noteId;
        const noteId = (typeof rawId === 'number' && Number.isFinite(rawId))
            ? rawId
            : null;
        return { ankiConnect: reply.ankiConnect === true, noteId };
    }
    return { ankiConnect: reply === true, noteId: null };
}

// Records the just-mined word as the editable "latest" card when the backend
// returned a note id; clears it otherwise (AnkiDroid / failure) so the button
// never shows a green ✓⤺ it cannot honour.
function rememberLatestMined(expression, reading, noteId) {
    if (typeof noteId === 'number' && Number.isFinite(noteId)) {
        lastMinedNoteId = noteId;
        lastMinedEntryKey = mineEntryKey(expression, reading);
    } else {
        lastMinedNoteId = null;
        lastMinedEntryKey = null;
    }
}

// True when [expression]/[reading] is the single most-recently-mined word whose
// card can still be overwritten in place (a real note id is held for it).
function isLatestEditable(expression, reading) {
    return lastMinedNoteId !== null &&
        lastMinedEntryKey === mineEntryKey(expression, reading);
}

// TODO-393/405「查词窗口句子上下文制卡」(取代 TODO-382 单按钮逐句追加)：弹窗里用「➕➖
// 递增递减步进器」把当前正查句之前/之后的 N 句作上下文纳入这张制卡的 sentence 字段。
//
// 数据流：JS 不持有句子文本/音频区间（都由宿主 Dart 的 MiningSentenceDraft 拥有），只
// 镜像两个标量「上几句 / 下几句」用于驱动步进器计数显示：
//   - 点➕（该方向 n+=1）/ 点➖（该方向 max(0, n-1)）→ callHandler('setSentenceContext',
//     {prev, next}) → 宿主按这两个数解析上下文句**整体替换**草稿 → 回传上下文句总数
//     （上 N + 下 N）。JS 镜像的是「请求几句」，真实合成由宿主按真句边界封顶。
//   - 制卡成功（mineEntry）/ 换词查词 → 宿主清空草稿 → JS 把两个镜像标量归零。
// 上下文是「选多少句」的标量：➕➖只是把这个标量升 1 / 降 1（整体替换草稿），不是把句子
// 越攒越多地累加进 JS。JS 不设硬上限——由宿主的段落/cue 边界天然封顶。
let sentenceCtxPrev = 0;
let sentenceCtxNext = 0;
// 兼容守卫/旧调用：保留镜像总数（上 N + 下 N）。
let sentenceDraftCount = 0;

// 刷新页面上所有句子上下文选择器的视觉态（多词条头共享同一对镜像标量）。
// querySelectorAll 不可用时（极端 fake DOM）静默跳过，不影响制卡主流程。
function refreshAllSentenceContextPickers() {
    sentenceDraftCount = sentenceCtxPrev + sentenceCtxNext;
    if (typeof document.querySelectorAll !== 'function') return;
    __fushiRootNode().querySelectorAll('.sentence-context-picker')
        .forEach(refreshSentenceContextPicker);
    __fushiRootNode().querySelectorAll('.clear-draft-button')
        .forEach(refreshClearDraftButton);
}

// 把一个上下文步进器里两个方向的计数显示同步到镜像标量：更新计数文本、n>0 时给计数加
// .selected（绿色高亮），并在 n<=0 时禁用对应方向的➖（不能再减到负）。
function refreshSentenceContextPicker(picker) {
    if (!picker || typeof picker.querySelectorAll !== 'function') return;
    picker.querySelectorAll('.context-count').forEach(function(count) {
        const dir = count.dataset.dir;
        const n = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
        count.textContent = String(n);
        count.classList.toggle('selected', n > 0);
    });
    picker.querySelectorAll('.context-stepper-btn.minus').forEach(function(btn) {
        const dir = btn.dataset.dir;
        const n = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
        btn.disabled = n <= 0;
    });
}

// TODO-382/393 可撤销：刷新「清空已加句子」按钮可见性。仅在已选上下文（总数>0）时显示，
// 给用户一个明确、可见的「回到只制当前句」入口。
function refreshClearDraftButton(button) {
    if (!button) return;
    // BUG-842：改用 DOM 提示，去掉会在离屏 WebView2 飞走的原生 title（幂等，只挂一次监听）。
    setInlineButtonTip(button, window.i18nClearSentenceDraftTooltip || '清空已加句子');
    button.hidden = (sentenceCtxPrev + sentenceCtxNext) <= 0;
}

// 把当前两个镜像标量发给宿主整体设置上下文，回传上下文句总数。宿主未接入 / 出错时
// 返回当前镜像总数（不漂移）。
async function setSentenceContextOnHost() {
    try {
        const reply = await window.flutter_inappwebview.callHandler(
            'setSentenceContext', { prev: sentenceCtxPrev, next: sentenceCtxNext });
        const n = (typeof reply === 'number' && Number.isFinite(reply)) ? reply : 0;
        return n >= 0 ? n : 0;
    } catch (e) {
        console.error('setSentenceContext failed', e);
        return sentenceCtxPrev + sentenceCtxNext;
    }
}

// 清空宿主草稿（回到只制当前句），回传清空后的句数（恒 0）。
async function clearSentenceDraftOnHost() {
    try {
        const reply = await window.flutter_inappwebview.callHandler('clearSentenceDraft');
        const n = (typeof reply === 'number' && Number.isFinite(reply)) ? reply : 0;
        return n >= 0 ? n : 0;
    } catch (e) {
        console.error('clearSentenceDraft failed', e);
        return sentenceCtxPrev + sentenceCtxNext;
    }
}

// BUG-297 / TODO-393：把句子上下文镜像标量归零（不发宿主信号）。换词复用常驻热槽
// WebView 时宿主只重注入 lookupEntries 再调 renderPopup()（不重载页面），这三个模块级
// 标量不像页面刷新那样自动归零，renderPopup 据残留值会把上一个词的「上 N / 下 N」按钮
// 着色成 selected、清空按钮显示出来，与宿主已清空的草稿不一致。宿主在换词注入脚本里调
// 本函数把镜像与已清的草稿对齐，再 renderPopup() 重建选择器即回到初始 0/0 态。
// 制卡成功(mineEntry)/点×清空两处已各自就地归零（同事件内同步），不依赖本函数。
window.resetSentenceContextMirror = function() {
    sentenceCtxPrev = 0;
    sentenceCtxNext = 0;
    sentenceDraftCount = 0;
};

// TODO-645 / BUG-358: the popup mining dictionary selection (selectedDictionaries[idx],
// which fills the Anki {selected-glossary} field recording which dictionary an entry chose
// as its preferred gloss) must be one-shot, matching the sentence-context mirror lifecycle
// above: cleared for THIS entry after a successful mine, and cleared for ALL entries on a
// word change / re-render. Otherwise, reusing the warm-slot WebView for the next lookup at
// the same entryIdx leaves the stale pick in place and the next mined card silently carries
// the previously selected dictionary.
//
// Two entry points: the mine-success branch calls resetSelectedDictionariesForEntry(idx) to
// clear only the mined entry (per-entry selections are independent — mining one card must not
// wipe a sibling card pick); the host word-change inject calls resetSelectedDictionaries() to
// zero everything (renderPopup rebuilds the DOM, so the stored summary label refs go stale —
// the whole map must reset back to the no-selection state). Clearing also strips the stored
// summary .selected class so state and UI stay consistent while the DOM still exists.
function clearSelectedDictionaryEntry(idx) {
    const selected = selectedDictionaries[idx];
    if (!selected) return;
    selected.label?.classList?.remove('selected');
    delete selectedDictionaries[idx];
}

window.resetSelectedDictionariesForEntry = function(idx) {
    clearSelectedDictionaryEntry(idx || 0);
};

window.resetSelectedDictionaries = function() {
    for (const idx of Object.keys(selectedDictionaries)) {
        clearSelectedDictionaryEntry(idx);
    }
};

// 构造一个句子上下文步进器：两行「上 [➖][N][➕]」+「下 [➖][N][➕]」。点➕该方向 n+=1、点
// ➖该方向 max(0, n-1)，把该方向的上下文句数整组重发宿主。无 JS 硬上限——由宿主的段落/
// cue 边界天然封顶（镜像可继续升、宿主合成时按真句封顶）。
function buildSentenceContextPicker() {
    const picker = el('div', { className: 'sentence-context-picker' });
    const setDirCount = async function(dir, n) {
        if (picker.dataset.busy === '1') return;
        picker.dataset.busy = '1';
        try {
            if (dir === 'prev') sentenceCtxPrev = n;
            else sentenceCtxNext = n;
            sentenceDraftCount = await setSentenceContextOnHost();
            refreshAllSentenceContextPickers();
        } finally {
            picker.dataset.busy = '';
        }
    };
    const makeStepperBtn = function(dir, sign) {
        const btn = el('button', {
            className: 'inline-action-button context-stepper-btn ' + sign,
        });
        setButtonIcon(btn, sign === 'plus' ? 'add' : 'remove');
        btn.dataset.dir = dir;
        btn.onclick = function() {
            const cur = dir === 'prev' ? sentenceCtxPrev : sentenceCtxNext;
            const next = sign === 'plus' ? cur + 1 : Math.max(0, cur - 1);
            // 已到 0 再点➖是空操作（避免无谓重发宿主）。
            if (next === cur) return;
            setDirCount(dir, next);
        };
        return btn;
    };
    const makeRow = function(dir, label) {
        const row = el('div', { className: 'context-row' });
        row.appendChild(el('span', { className: 'context-label', textContent: label }));
        row.appendChild(makeStepperBtn(dir, 'minus'));
        const count = el('span', { className: 'context-count', textContent: '0' });
        count.dataset.dir = dir;
        row.appendChild(count);
        row.appendChild(makeStepperBtn(dir, 'plus'));
        return row;
    };
    picker.appendChild(makeRow('prev', window.i18nContextPrevLabel || '上'));
    picker.appendChild(makeRow('next', window.i18nContextNextLabel || '下'));
    return picker;
}

// BUG-763/766：「制卡·选择句子上下文」模态已改为 app 原生顶层 Flutter 对话框
// （SentenceContextDialog，宿主经 openSentenceContextModal 桥接弹出），不再画在查词
// 弹窗 WebView 内（那受弹窗表面尺寸/半透明限制，句子框重叠、显示不全）。
// 这里只保留词条上「调整上下文」按钮 → callHandler('openSentenceContextModal',
// {entryIndex, matched})，与确认制卡回点用的 fushiPopupMineEntryByIndex（见文件末尾）。


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

// TODO-1325 #4: 顶部动作按钮从纯文字字形（♪ ☆ ★ ✓ ✓↩ + × ➖ ➕）升级为内联
// Material Symbols SVG 矢量图标（Niratan 同款观感，但走 fill:currentColor 而非
// macOS-only 的 -webkit-mask 分支，Android WebView / Windows WebView2 一致渲染）。
// 图标随按钮 color / opacity / 主题走；尺寸由 .inline-action-button > svg 的 CSS
// （width/height:1em）跟随各按钮 font-size 自适应。每个按钮额外记 data-icon 作为
// 当前图标名的可观测状态标记——弹窗跑在 WebView 里没有 headless，测试用 data-icon
// 断言图标切换，不再依赖字形 textContent。
const ICON_PATHS = {
    // volume_up
    audio: 'M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z',
    // volume_off（无音频 / 播放失败）
    audioOff: 'M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z',
    // star_border（未收藏）
    favorite: 'M22 9.24l-7.19-.62L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.63-7.03L22 9.24zM12 15.4l-3.76 2.27 1-4.28-3.32-2.88 4.38-.38L12 6.1l1.71 4.04 4.38.38-3.32 2.88 1 4.28L12 15.4z',
    // star（已收藏）
    favorited: 'M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z',
    // add（制卡按钮已回到 ✓✓↩ 文本标记；add 仅供句子上下文步进器的 + 按钮）
    add: 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z',
    // remove（步进器 ➖）
    remove: 'M19 13H5v-2h14v2z',
    // close（清空草稿 / 标签说明遮罩关闭 ×）
    close: 'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
    // tune（Niratan「调整上下文」按钮：打开制卡前句子上下文调整模态）
    tune: 'M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z',
    // open_in_new（TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮，直接跳去
    // Anki 定位该词的已存在卡；仅 data-mined 时显示）
    openInAnki: 'M19 19H5V5h7V3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z',
};

function iconSvg(name) {
    const d = ICON_PATHS[name] || '';
    return '<svg class="inline-action-icon" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="' + d + '"></path></svg>';
}

// 给一个动作按钮设置图标：记 data-icon（状态可观测），并把内容换成对应内联 SVG。
function setButtonIcon(button, name) {
    if (!button) return;
    button.dataset.icon = name;
    button.innerHTML = iconSvg(name);
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
// 词典名 -> 该词典的内容语言（BCP-47）。映射由 Dart 注入
// （popup_settings_injection 写 window.__fushiDictionaryLanguages，值取自 yomitan
// index.json 的 sourceLanguage/targetLanguage，或用户在词典设置里手动指定）。
// 浏览器扩展没有 Dart 注入 -> 返回 null -> 退回纯字符检测（旧行为）。
//
// 为什么必须传：getLanguageFromText 的 isStringPartiallyJapanese 把**汉字**也算
// 日文（KANA_PATTERN || CJK_PATTERN），所以纯汉字的中文释义会被判成 'ja'。上游
// 本来留了闸门（language 是 zh/yue 时跳过检测），但所有调用处一直传 null，闸门
// 从未生效。传上词典自己声明的语言，中文词典的释义才不会被贴上 lang="ja" 再被
// :lang(ja) 的日文字体链接管。
function dictionaryLanguageOf(dictName) {
    const map = window.__fushiDictionaryLanguages;
    if (!map || !dictName) return null;
    const language = map[dictName];
    return typeof language === 'string' && language ? language : null;
}

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
    const overlay = __fushiRootNode().querySelector('.overlay');
    __fushiRootNode().querySelector('.overlay-content').textContent = description;
    overlay.style.display = 'block';
}

function closeOverlay() {
    __fushiRootNode().querySelector('.overlay').style.display = 'none';
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

function applyImageStyles(node, imageContainer, aspectRatioSizer, imageBackground, image, filename, appearance) {
    // .gloss-image-link
    node.style.cssText += 'display:inline-block;position:relative;line-height:1;max-width:100%;';
    // .gloss-image-container
    imageContainer.style.cssText += `display:inline-block;white-space:nowrap;max-width:100%;max-height:100vh;position:relative;vertical-align:top;line-height:0;overflow:hidden;font-size:1em;`;
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
    // BUG-902：制卡登记的 path 必须与显示路径一样先归一化（trim / \\→/ / 去开头
    // ./ 或 /）。否则 writeDictionaryMediaCache 用生 path 引 FushiDicts.getMediaFile
    // 会 miss（path 带开头 ./ 或 / 的词典），字节不落盘 → 两个 Anki repo 读不到缓存
    // → 卡片里 <img src="fushi_dict_N.ext"> 占位符不被替换成真实文件名，留成坏图。
    // 显示路径（rewriteDictionaryMediaPath）早已归一化，故弹窗里图仍看得见，只有制卡
    // 掉图——这正是 BUG-902 的病症（外字/内容图混排时，脏 path 的词典排在后面就末尾掉图）。
    // 归一化后 payload.path 干净，writer 与三个 Anki repo（AnkiConnect/AnkiDroid/
    // AnkiMobile）都按同一干净 path 的 sha1 命名缓存文件，契约天然一致。
    const normalizedPath = normalizeDictMediaPath(path);
    const key = `${dictionary}\n${normalizedPath}`;
    if (!currentDictionaryMedia.has(key)) {
        const extension = normalizedPath.split('.').pop();
        currentDictionaryMedia.set(key, {
            dictionary,
            path: normalizedPath,
            filename: `fushi_dict_${currentDictionaryMedia.size}.${extension}`,
        });
    }
    return currentDictionaryMedia.get(key).filename;
}

// BUG-435 / BUG-478 / BUG-520 家族根因：词典 structured-content 节点自带的
// inline float / position:absolute|fixed|sticky 会把文本节点推出行内流（明鏡
// 补足◆行开引号被推到行右上角）。上游 Yomitan 按 schema 白名单下发样式，这
// 两族属性从不落地；这里在源头丢弃，而不是事后用一刀切 CSS 兜底——BUG-520
// 就是那种兜底的代价：display:inline 打断了所有词典靠 div block 布局做的分行。
// position:relative（及其 top/left 偏移）不脱离文档流，词典靠它做合法的字形
// 微调，保留。
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
    __fushiRootNode().querySelector('.dict-image-lightbox')?.remove();
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

    // 点灯箱任何位置（含图片本身）都关闭：放大图 max-width/height:100% 几乎铺满
    // 视口，用户必然点图片关闭。早先给图片 stopPropagation 拦掉了遮罩的关闭，导致
    // 只有四周 16px 边距能关＝「关不掉」（BUG-107）。预览无任何图内交互，故让整个
    // 灯箱统一 tap-to-close。
    overlay.addEventListener('click', () => closeImageLightbox());

    __fushiOverlayParent().appendChild(overlay);
}

// TODO-859 症状B：图片预览的 click 监听挂在外层 .gloss-image-link 容器上，但
// .gloss-image-container 被 popup.css 的 `min-width:min(100%,200px)` 撑到 >=200px，
// 横向溢出盖住相邻正文。点正文却命中这个隐形大盒 → 触发全屏黑色灯箱遮罩（误触）。
// 修法：保留外层 click 监听（不动 CSS 布局，避免 TODO-350 Sanseido em-accent 回归），
// 但用 getBoundingClientRect 把命中收敛到真正渲染的图片像素（img.gloss-image 或
// canvas）。点击点不在图片像素矩形内 = 落在容器留白上 = 不开灯箱（让事件继续冒泡，由
// 上面的 tapOutside 正文判定接手）。命中图片像素才 preventDefault + 开灯箱。
function pointHitsRenderedImagePixels(node, clientX, clientY) {
    // 真正画出像素的元素：渲染到 canvas 的走 canvas，否则是 <img class="gloss-image">。
    const pixelEl = (typeof node.querySelector === 'function')
        ? (node.querySelector('img.gloss-image') || node.querySelector('canvas'))
        : null;
    if (!pixelEl || typeof pixelEl.getBoundingClientRect !== 'function') {
        // 无法测量真实像素矩形时退回旧行为（整盒可点），不让预览功能失效。
        return true;
    }
    const rect = pixelEl.getBoundingClientRect();
    if (!rect || (rect.width <= 0 && rect.height <= 0)) {
        return true;
    }
    return clientX >= rect.left && clientX <= rect.right
        && clientY >= rect.top && clientY <= rect.bottom;
}

function enableDefinitionImagePreview(node, imageUrl, alt) {
    node.addEventListener('click', (event) => {
        if (!pointHitsRenderedImagePixels(node, event.clientX, event.clientY)) {
            // 点在容器留白（被 min-width 撑出的横向溢出区）上：不拦截，让外层 click
            // 处理器按正文/背景判定决定选词还是关后代，避免误触全屏黑遮罩。
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        openImageLightbox(imageUrl, alt);
    });
}

const COMPACT_GLOSSARIES_ANKI = `.yomitan-glossary ul[data-sc-content="glossary"] > li:not(:first-child)::before, .yomitan-glossary .glossary-list > li:not(:first-child)::before { white-space: pre-wrap; content: " | "; display: inline; color: rgb(119, 119, 119); }
.yomitan-glossary ul[data-sc-content="glossary"] > li, .yomitan-glossary .glossary-list > li { display: inline; }
.yomitan-glossary ul[data-sc-content="glossary"], .yomitan-glossary .glossary-list { display: inline; list-style: none; padding-left: 0px; }`;

// BUG-1666: exported glossary HTML used to keep the dictionary's raw
// cross-reference anchors (`entry://词` / relative hrefs). Anki desktop and
// AnkiDroid render cards in a WebView whose base URL is their local media
// server (http://127.0.0.1:<random port>), so tapping such a link on a card
// navigated to a dead localhost page. Inside the popup these clicks are
// intercepted and re-looked-up by the anchor's visible headword
// (handleGlossaryAnchorClick, BUG-767); a card has no interceptor, so bake the
// same semantic into the exported bytes: internal cross references become
// fushi://lookup?word=<visible text> deep links (Android :popup dict window /
// Windows single-instance handoff open them as a lookup), real external
// http(s) links are kept, `#` fragments stay (they never leave the card), and
// dictionary media anchors (sound:// etc., whose bytes are not exported) lose
// their href instead of pointing nowhere.
function rewriteExportedGlossaryAnchors(root) {
    root.querySelectorAll('a[href]').forEach((anchor) => {
        const href = (anchor.getAttribute('href') || '').trim();
        if (/^https?:\/\//i.test(href) || href.startsWith('#')) {
            return;
        }
        const word = /^(?:sound|image|dictmedia):/i.test(href)
            ? ''
            : (anchor.textContent || '').trim();
        if (!word) {
            anchor.removeAttribute('href');
            return;
        }
        anchor.setAttribute('href', `fushi://lookup?word=${encodeURIComponent(word)}`);
    });
}

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
    
    // TODO-865 / BUG-419 sibling: hidden term dictionaries stay registered in the
    // FFI engine (see AppModel.bucketDictPaths — filtering happens at render time),
    // so entry.glossaries still carries their definitions. The mining payload path
    // (constructSingleGlossaryHtml / constructGlossaryHtml) must drop them too, the
    // same way createGlossarySectionWrapper does for the lookup popup, so a disabled
    // dictionary's glossary never ends up in an Anki card field.
    const hiddenDictionaryNames = window.hiddenDictionaryNames || [];
    entry.glossaries.forEach(g => {
        if (hiddenDictionaryNames.includes(g.dictionary)) return;
        if (isRedirectGlossary(g)) return;
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
                renderStructuredContent(tempDiv, JSON.parse(g.content), dictionaryLanguageOf(dictName), dictName, true);
            } catch {
                if (/<[a-z][\s\S]*>/i.test(g.content)) {
                    tempDiv.innerHTML = sanitizeHtml(g.content);
                } else {
                    renderStructuredContent(tempDiv, g.content, dictionaryLanguageOf(dictName), dictName, true);
                }
            }
        } else {
            renderStructuredContent(tempDiv, g.content, dictionaryLanguageOf(dictName), dictName, true);
        }

        const parsedTags = parseTags(g.definitionTags).filter(tag => !NUMERIC_TAG.test(tag));
        const posTags = [...new Set(parsedTags.filter(isPartOfSpeech))].sort();
        const currentTags = JSON.stringify(posTags);
        const filteredTags = parsedTags.filter(tag => !isPartOfSpeech(tag) || !(prevTags !== null && prevTags === currentTags));
        const tags = filteredTags.length > 0 ? filteredTags.join(', ') : '';
        rewriteExportedGlossaryAnchors(tempDiv);
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
    
    const hiddenDictionaryNames = window.hiddenDictionaryNames || [];
    entry.glossaries.forEach(g => {
        if (hiddenDictionaryNames.includes(g.dictionary)) return;
        if (isRedirectGlossary(g)) return;
        const dictName = g.dictionary;

        const tempDiv = document.createElement('div');
        if (typeof g.content === 'string') {
            try {
                renderStructuredContent(tempDiv, JSON.parse(g.content), dictionaryLanguageOf(dictName), dictName, true);
            } catch {
                if (/<[a-z][\s\S]*>/i.test(g.content)) {
                    tempDiv.innerHTML = sanitizeHtml(g.content);
                } else {
                    renderStructuredContent(tempDiv, g.content, dictionaryLanguageOf(dictName), dictName, true);
                }
            }
        } else {
            renderStructuredContent(tempDiv, g.content, dictionaryLanguageOf(dictName), dictName, true);
        }

        let label = '';
        const parsedTags = parseTags(g.definitionTags).filter(tag => !NUMERIC_TAG.test(tag));
        const posTags = [...new Set(parsedTags.filter(isPartOfSpeech))].sort();
        const currentTags = JSON.stringify(posTags);
        const filteredTags = parsedTags.filter(tag => !isPartOfSpeech(tag) || !(prevTags !== null && prevTags === currentTags));
        const tags = filteredTags.length > 0 ? filteredTags.join(', ') : '';
        // 标签格式与上游 Yomitan 的 `glossary-single`（`(definitionTags…, dictionaryAlias)`）
        // 以及本文件的 constructSingleGlossaryHtml 保持一致：**不带序号**。此前这里自造了一个
        // 自增序号，卡片上就成了「(1, 词典名)」（BUG-1061）。
        if (dictName !== lastDict) {
            lastDict = dictName;
            label = tags ? `(${tags}, ${dictName})` : `(${dictName})`
        }
        else {
            label = tags ? `(${tags})` : ''
        }
        
        rewriteExportedGlossaryAnchors(tempDiv);
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

function escapePitchText(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// TODO-688 mining side: Yomitan `ipa`-mode dicts (e.g. English) ship phonetic
// transcriptions in the pitch group instead of pitch positions. They are the
// same nature as pitch (phonetic notation), so {pitch-accent-positions} carries
// them too — that is what makes English cards get their transcription with the
// default field mappings, no remap needed. Plain pitch-accent dicts (Japanese)
// have an empty transcriptions array and render byte-identically to before.
function constructPitchPositionHtml(pitches) {
    if (!pitches?.length) {
        return '';
    }

    let items = '';
    pitches.forEach(pitchGroup => {
        pitchGroup.pitchPositions.forEach(pos => {
            items += `<li><span style="display:inline;"><span>[</span><span>${pos}</span><span>]</span></span></li>`;
        });
        (pitchGroup.transcriptions || []).forEach(ipa => {
            items += `<li><span style="display:inline;"><span>[</span><span>${escapePitchText(ipa)}</span><span>]</span></span></li>`;
        });
    });
    // No positions AND no transcriptions: return '' instead of an empty <ol>
    // shell, so the field is treated as empty and skipped.
    return items ? `<ol>${items}</ol>` : '';
}

// Yomitan-named {phonetic-transcriptions}: ONLY the IPA transcriptions, for
// users who map them to a dedicated note field. '' when no dict provides any.
function constructPhoneticTranscriptionsHtml(pitches) {
    if (!pitches?.length) {
        return '';
    }

    let items = '';
    pitches.forEach(pitchGroup => {
        (pitchGroup.transcriptions || []).forEach(ipa => {
            items += `<li><span style="display:inline;"><span>[</span><span>${escapePitchText(ipa)}</span><span>]</span></span></li>`;
        });
    });
    return items ? `<ol>${items}</ol>` : '';
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
        const isGaiji = nodeData?.class === 'gaiji' || Object.prototype.hasOwnProperty.call(nodeData || {}, 'gaiji');
        if (isGaiji) {
            imageContainer.style.setProperty('width', 'auto', 'important');
            imageContainer.style.setProperty('margin-inline-end', '0', 'important');
        }
        imageContainer.style.minWidth = '1.2em';
        imageContainer.style.height = '1.2em';
        imageContainer.style.fontSize = 'inherit';
        imageContainer.style.lineHeight = '0';
        imageContainer.style.overflow = 'visible';
        aspectRatioSizer.style.display = 'none';
    } else {
        // 导出（制卡）与弹窗的尺寸语义不同：Yomitan 的 structured-content-generator 永远写
        // `${usedWidth}em`，弹窗端再由它自己的 CSS
        // (.gloss-image-container{font-size:calc(1em/var(--font-size-no-units))}) 把 1em 压成 1px；
        // Anki 卡片上没有那份 CSS，em 按卡片正文字号解析，所以 Yomitan 的卡片图才是
        // 「宽度数值 x 卡片字号」。这里若把导出也折算成物理 px，卡片图就比 Yomitan 小一个
        // 字号的倍数（BUG-1062）。故导出保留 em 语义，弹窗维持 px。
        imageContainer.style.width = exporting ? `${usedWidth}em` : `${usedWidth}px`;
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
            applyImageStyles(node, imageContainer, aspectRatioSizer, imageBackground, image, filename, appearance);
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
    const emSize = Number.parseFloat(getComputedStyle(__fushiContainer() || document.documentElement).fontSize);
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
        context.fillStyle = (__fushiContainer() || document.documentElement).getAttribute('data-theme') === 'dark' ? '#ffffff' : '#000000';
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

// Builds the Anki field payload for a popup entry. Shared by mineEntry (create)
// and updateEntry (overwrite the latest card) so both carry identical fields,
// media, and audio — no second render path to drift (TODO-270 D).
async function buildMinePayload(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
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
    const phoneticTranscriptions = constructPhoneticTranscriptionsHtml(pitches);

    const audioReading = reading || expression;
    let audio = '';
    if (window.audioSources?.length && window.needsAudio) {
        // TODO-766: mining must NOT reuse the playback cache. A remote host signs
        // the audio file URL with a short-lived token (5 min). Playback resolves
        // and plays it immediately so the token is still fresh, but mining can
        // happen long after — reusing the cached URL hands Anki an expired token
        // that 404s, and the card lands with an empty [sound:]. Force a fresh
        // resolve here (re-signing a new token) and decouple it from the playback
        // cache. If the fresh resolve fails (host has no audio for this word),
        // fall back to whatever the cache holds rather than regressing to empty.
        const fresh = await fetchAudioUrl(expression, audioReading);
        if (fresh) {
            audio = fresh;
            audioUrls[idx] = { key: audioCacheKey(expression, audioReading), url: fresh };
        } else {
            const cached = audioUrls[idx];
            if (cached?.key === audioCacheKey(expression, audioReading)) {
                audio = cached.url;
            }
        }
    } else {
        const cached = audioUrls[idx];
        if (cached?.key === audioCacheKey(expression, audioReading)) {
            audio = cached.url;
        }
    }

    return {
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
        phoneticTranscriptions,
        popupSelectionText,
        audio,
        selectedDictionary: selectedDictionaries[idx]?.name || '',
        dictionaryMedia: JSON.stringify([...dictionaryMedia.values()])
    };
}

async function mineEntry(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const payload = await buildMinePayload(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
    return await window.flutter_inappwebview.callHandler('mineEntry', payload);
}

// TODO-270 D: overwrite an EXISTING card ([noteId]) in place with freshly-built
// fields (same payload as mineEntry). Used by the green ✓⤺ "latest editable"
// state so "I mined the wrong content, fix the last card" truly updates that
// note instead of creating a second one.
async function updateEntry(noteId, expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const fields = await buildMinePayload(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
    return await window.flutter_inappwebview.callHandler('updateEntry', { noteId, fields });
}

// TODO-1007/1008: clicking ✓ (the card already exists) hands the FULL mine
// payload to the host, which finds every matching note in Anki and shows an
// action sheet (overwrite which card / add a new duplicate / view & open in
// Anki). The host returns the post-action {ankiConnect, noteId} so the button
// can refresh. This replaces the old silent "re-verify then return with no
// feedback" path (TODO-1007 root cause: clicking ✓ did nothing).
async function minedCardAction(expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const fields = await buildMinePayload(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
    return await window.flutter_inappwebview.callHandler('minedCardAction', fields);
}

// BUG-1064 —— app 外表面的「卡片已在 Anki 中」操作面板（IN-PAGE 版）。
//
// 宿主分两类：
//   * 有原生对话框（window.__fushiMinedCardActionNative）：app 内的三个
//     dictionary_popup_webview 表面。点 ✓ 照旧交给 `minedCardAction` 宿主 handler，
//     由 Flutter 弹居中对话框（BUG-1040），本段代码完全不参与。
//   * 没有原生对话框：Windows app 外的裸 WebView2 表面（剪贴板面板 / 瞬态查词窗）与
//     浏览器扩展。它们的 `minedCardAction` 只会立刻拿到 null——主窗在别的程序后面，
//     Flutter 对话框呈现不出来。旧代码把这个 null 当作「宿主已处理」，于是点已制卡的
//     ✓ 什么都不发生（用户报「app 外重复制卡点击没反应」）。改为在弹窗自己的 WebView
//     里画同一套选择：覆写哪张 / 在 Anki 中打开 / 新增为重复卡 / 取消。
//
// 数据与副作用仍然全部在宿主：命中列表走 `findMinedMatches`（repo.findMatchingNotes）、
// 打开卡片走 `openMinedNote`（repo.openNoteInAnki），覆写与新增复用既有的
// `updateEntry` / `mineEntry` 两根桥——本面板不新增任何写路径。

const MINED_ACTION_OPEN_CLASS = 'mined-action-open';

// 宿主是否自带原生（Flutter）动作对话框。未注入 = 没有（扩展、以及任何还没接线的
// 表面）→ 走页内面板，绝不静默。
function hasNativeMinedCardAction() {
    return window.__fushiMinedCardActionNative === true;
}

// 反查 Anki 里这个词的全部命中卡。永不抛：拿不到就当没有命中，调用方按「卡已不在」
// 走重新制卡（与 app 内 runAnkiMinedCardAction 的 matches.isEmpty 分支同语义）。
async function findMinedMatches(expression, reading) {
    try {
        const reply = await window.flutter_inappwebview.callHandler(
            'findMinedMatches', { expression, reading });
        if (!Array.isArray(reply)) return [];
        return reply
            .map((row) => ({
                noteId: (row && typeof row.noteId === 'number' && Number.isFinite(row.noteId))
                    ? row.noteId : null,
                preview: (row && typeof row.preview === 'string') ? row.preview : '',
            }))
            .filter((row) => row.noteId !== null);
    } catch (_) {
        return [];
    }
}

// 在 Anki 中打开一张卡（AnkiConnect guiBrowse / AnkiDroid ACTION_VIEW）。返回是否成功，
// 失败时面板就地显示提示而不是假装成功。
async function openMinedNoteInAnki(noteId) {
    try {
        return await window.flutter_inappwebview.callHandler('openMinedNote', { noteId }) === true;
    } catch (_) {
        return false;
    }
}

// 渲染页内操作面板，resolve 用户的选择：
//   {action:'cancel'} / {action:'duplicate'} / {action:'overwrite', noteId}
// 「在 Anki 中打开」就地执行、不结束面板（用户可能只是想先看一眼再决定覆写）。
// 与 app 内对话框一致：点遮罩不关闭（制卡/覆写有副作用，误触不该丢掉整次操作），
// 只有「取消」与 Esc 能取消。
function showMinedCardActionPanel(matches, options) {
    // openOnly（BUG-1064）：↗ 的多卡选择形态——只列卡片 + 打开，不带覆写 /
    // 新增重复卡（那是点 ✓ 的职责），与 app 内 showAnkiOpenNotePicker 单一语义一致。
    const openOnly = !!(options && options.openOnly);
    return new Promise((resolve) => {
        // 弹窗是否拥有整个文档：app 内/app 外都是独立的 popup.html 文档（true）；
        // 浏览器扩展把同一份 popup.js 注入到宿主页面的 shadow root 里（__fushiRoot），
        // 那里的 <html> 是别人的页面，既不该被我们挂 class，也没有窗口高度问题。
        const ownsDocument = !window.__fushiRoot;
        const rootEl = document.documentElement;
        const panel = el('div', { className: 'mined-action-panel' });
        const backdrop = el('div', { className: 'mined-action-backdrop' }, [panel]);
        let settled = false;
        let busy = false;

        const onKey = (e) => {
            if (e.key === 'Escape' || e.key === 'Esc') {
                // 面板自己吃掉 Esc：否则会冒泡到弹窗的关闭处理器，把整个查词窗一起关了。
                e.preventDefault();
                e.stopPropagation();
                if (!busy) finish({ action: 'cancel' });
            }
        };
        // BUG-1269：宿主页面（阅读器/漫画/视频）往弹窗里装了一座 capture 阶段的输入桥，
        // 把绑到「关闭词典」等动作的键与鼠标键交回宿主。那座桥在 onLoadStop 就注册，比
        // 本面板的 capture 监听早得多——不声明「模态开着」它就会抢在上面这个 onKey 前面
        // 吃掉 Esc，于是用户想关面板却把整个查词窗关了（正是上面那行注释要防的事）。
        // 深度计数而非布尔：面板可能叠开（↗ 多卡选择套在 ✓ 操作单之上）。
        window.__fushiPopupModalDepth = (window.__fushiPopupModalDepth || 0) + 1;
        const finish = (result) => {
            if (settled) return;
            settled = true;
            window.__fushiPopupModalDepth =
                Math.max(0, (window.__fushiPopupModalDepth || 1) - 1);
            document.removeEventListener('keydown', onKey, true);
            backdrop.remove();
            if (ownsDocument) rootEl.classList.remove(MINED_ACTION_OPEN_CLASS);
            resolve(result);
        };

        // 面板内的指针事件绝不能冒泡到 document——popup.js 的 document 点击处理器会
        // 把「点空白」理解成关闭弹窗，那样点面板等于关窗。
        ['click', 'mousedown', 'pointerdown', 'touchstart'].forEach((type) => {
            backdrop.addEventListener(type, (e) => { e.stopPropagation(); }, false);
        });

        const buttons = [];
        const setBusy = (value) => {
            busy = value;
            panel.classList.toggle('busy', value);
            buttons.forEach((btn) => { btn.disabled = value; });
        };
        const error = el('div', { className: 'mined-action-error' });
        error.style.display = 'none';
        const showError = (msg) => {
            error.textContent = msg;
            error.style.display = '';
        };

        panel.appendChild(el('div', {
            className: 'mined-action-title',
            textContent: window.i18nMinedCardTitle || '卡片已在 Anki 中',
        }));
        const subtitle = (matches.length > 1 || openOnly)
            ? (window.i18nMinedMultipleMatches || '{count} 张匹配的卡片')
                .replace('{count}', String(matches.length))
            : (window.i18nMinedCardSubtitle || '选择对这张已存在的卡片做什么。');
        panel.appendChild(el('div', { className: 'mined-action-subtitle', textContent: subtitle }));

        const list = el('div', { className: 'mined-action-list' });
        matches.forEach((note) => {
            const row = el('div', { className: 'mined-action-row' });
            row.appendChild(el('div', {
                className: 'mined-action-preview',
                textContent: note.preview || ('#' + note.noteId),
            }));
            const rowButtons = el('div', { className: 'mined-action-row-buttons' });
            const overwriteBtn = openOnly ? null : el('button', {
                className: 'mined-action-btn ghost',
                textContent: window.i18nMinedActionOverwrite || '覆写这张卡',
                onclick: () => {
                    if (busy) return;
                    setBusy(true);
                    finish({ action: 'overwrite', noteId: note.noteId });
                },
            });
            const viewBtn = el('button', {
                className: 'mined-action-btn ghost',
                textContent: window.i18nMinedActionView || '查看 / 在 Anki 中打开',
                onclick: async () => {
                    if (busy) return;
                    setBusy(true);
                    const ok = await openMinedNoteInAnki(note.noteId);
                    setBusy(false);
                    if (ok) {
                        finish({ action: 'cancel' });
                    } else {
                        showError(window.i18nMinedOpenFailed || '无法在 Anki 中打开这张卡片。');
                    }
                },
            });
            buttons.push(viewBtn);
            if (overwriteBtn) {
                buttons.push(overwriteBtn);
                rowButtons.appendChild(overwriteBtn);
            }
            rowButtons.appendChild(viewBtn);
            row.appendChild(rowButtons);
            list.appendChild(row);
        });
        panel.appendChild(list);
        panel.appendChild(error);

        const actions = el('div', { className: 'mined-action-actions' });
        const cancelBtn = el('button', {
            className: 'mined-action-btn ghost',
            textContent: window.i18nMinedActionCancel || '取消',
            onclick: () => { if (!busy) finish({ action: 'cancel' }); },
        });
        const duplicateBtn = el('button', {
            className: 'mined-action-btn filled',
            textContent: window.i18nMinedActionAddDuplicate || '新增为重复卡',
            onclick: () => {
                if (busy) return;
                setBusy(true);
                finish({ action: 'duplicate' });
            },
        });
        buttons.push(cancelBtn);
        actions.appendChild(cancelBtn);
        if (!openOnly) {
            buttons.push(duplicateBtn);
            actions.appendChild(duplicateBtn);
        }
        panel.appendChild(actions);

        // 瞬态查词窗的窗口高度会被收缩到卡片内容高度（host measureAndReport），矮卡片
        // 下面板会被窗口下沿裁掉。开面板时给 <html> 挂 class，popup.css 借它撑出最小
        // 高度，host 的下一次测量就把窗口放大到够放面板（面板关掉即恢复）。
        if (ownsDocument) rootEl.classList.add(MINED_ACTION_OPEN_CLASS);
        __fushiOverlayParent().appendChild(backdrop);
        document.addEventListener('keydown', onKey, true);
        (openOnly ? cancelBtn : duplicateBtn).focus();
    });
}

// BUG-1064：按钮旁的一次性短提示（1.8s 后自渐隐）。app 外没有 Flutter toast 可用，
// 「这个词在 Anki 里已经没有卡了」「打不开 Anki」这类结果必须就地说清楚，绝不静默。
// 定位/样式复用 showNoAudioHint 那套（.inline-hint 与 .audio-hint 同一条 CSS 规则），
// 锚到按钮的屏幕坐标，故窗口被裁到卡片 bbox 的 app 外覆盖窗里同样可见。
function showInlineHint(button, message) {
    const stale = __fushiRootNode().querySelector('.inline-hint');
    if (stale) stale.remove();
    const hint = el('div', { className: 'inline-hint', textContent: message });
    __fushiOverlayParent().appendChild(hint);
    const btnRect = button.getBoundingClientRect();
    const hintRect = hint.getBoundingClientRect();
    let left = btnRect.left + btnRect.width / 2 - hintRect.width / 2;
    left = Math.max(4, Math.min(left, window.innerWidth - hintRect.width - 4));
    let top = btnRect.top - hintRect.height - 6;
    if (top < 4) top = btnRect.bottom + 6;
    hint.style.left = left + 'px';
    hint.style.top = top + 'px';
    requestAnimationFrame(() => hint.classList.add('visible'));
    setTimeout(() => {
        hint.classList.remove('visible');
        setTimeout(() => hint.remove(), 220);
    }, 1800);
}

// BUG-1064：↗「在 Anki 中打开卡片」在 app 外的页内车道。
//
// 与点 ✓ 是**同一个根因的第二个入口**：宿主 handler `openInAnki` 同样没有被 app 外的
// 裸 WebView2 窗口 DEFER（它同样要弹 Flutter 的多卡选择框 / toast），于是同样被立刻
// 解析成 null——按钮转一圈什么都不发生。这里按宿主能力分流后，用与 app 内
// `openMinedCardInAnki` 完全相同的三分支语义就地处理：
//   - 无命中（探测时显示已制卡、现在查不到）→ 提示，不静默。
//   - 命中 1 张 → 直接打开；打不开也提示，绝不假装成功。
//   - 命中多张 → 弹页内面板的 openOnly 形态（只列卡片 + 打开，不带覆写/新增——
//     那是 ✓ 的职责，与 app 内 showAnkiOpenNotePicker 的单一语义一致）。
async function runInPageOpenInAnki(button, expression, reading) {
    const matches = await findMinedMatches(expression, reading);
    if (!matches.length) {
        showInlineHint(button, window.i18nMinedOpenNoCard || '没有找到已制的卡片。');
        return;
    }
    if (matches.length === 1) {
        const ok = await openMinedNoteInAnki(matches[0].noteId);
        if (!ok) {
            showInlineHint(button,
                window.i18nMinedOpenFailed || '无法在 Anki 中打开这张卡片。');
        }
        return;
    }
    await showMinedCardActionPanel(matches, { openOnly: true });
}

// 页内面板的完整编排。返回：
//   'handled'     —— 面板已处理（含用户取消），调用方只需按 Anki 真值刷新按钮态。
//   'fallthrough' —— Anki 里其实已经没有这张卡（别处删了），按普通新卡制卡。
async function runInPageMinedCardAction(
        expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText) {
    const matches = await findMinedMatches(expression, reading);
    if (!matches.length) {
        return { outcome: 'fallthrough', result: { ankiConnect: false, noteId: null } };
    }
    const choice = await showMinedCardActionPanel(matches);
    if (choice.action === 'overwrite') {
        const reply = await updateEntry(
            choice.noteId, expression, reading, frequencies, pitches, rules, matched,
            entryIndex, popupSelectionText);
        return { outcome: 'handled', result: parseMineResult(reply) };
    }
    if (choice.action === 'duplicate') {
        const reply = await mineEntry(
            expression, reading, frequencies, pitches, rules, matched, entryIndex, popupSelectionText);
        return { outcome: 'handled', result: parseMineResult(reply) };
    }
    return { outcome: 'handled', result: { ankiConnect: false, noteId: null } };
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
                // 原判据是 `!language && ...`：传了 language 就干脆不标 lang，
                // 因为上游假设更外层已经标过。本 app 没有那个外层，于是「传了词典
                // 语言」反而比「不传」丢的信息更多。改成只要父节点还没标就标，
                // getLanguageFromText 在 language 已知时直接回传它（不瞎猜）。
                if (!parent.hasAttribute('lang')) {
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
        // Yomitan "form-of"/non-lemma glossary: an array of [term, [tag, ...]]
        // pairs (e.g. wty-ja-en alt-of entries arrive as
        // [["时",["Hyōgai"]],["时",["alt-of"]],...]). The generic flattening
        // below would emit bare adjacent text nodes with no spacing or styling
        // → "时Hyōgai时alt-of时alternative时kanji", which reads as mojibake
        // (BUG-057). Render each pair as its own line: term + tag chips.
        if (node.length > 0 && node.every(isTaggedTermPair)) {
            renderTaggedTermPairs(parent, node);
            return;
        }

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
                markGlobalLookupExtHit(element);
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

// True for a Yomitan "form-of" glossary item: a [term, [tag, ...]] pair where
// the term is a string and the tags are an array of strings. See the array
// branch of renderStructuredContent (BUG-057).
function isTaggedTermPair(item) {
    return Array.isArray(item)
        && item.length === 2
        && typeof item[0] === 'string'
        && Array.isArray(item[1])
        && item[1].every(tag => typeof tag === 'string');
}

// Renders an array of [term, [tag, ...]] pairs as a readable list: each pair on
// its own line with the referenced term followed by its tag chips. Replaces the
// generic flattening that produced unspaced "时Hyōgai时alt-of…" mojibake.
function renderTaggedTermPairs(parent, pairs) {
    const list = el('div', { className: 'form-of-list' });
    pairs.forEach(([term, tags]) => {
        const item = el('div', { className: 'form-of-item' });
        const termEl = el('span', { className: 'form-of-term', textContent: term });
        termEl.style.marginRight = '4px';
        item.appendChild(termEl);
        const tagRow = createGlossaryTags(tags, 'glossary-tags form-of-tags');
        if (tagRow) {
            item.appendChild(tagRow);
        }
        list.appendChild(item);
    });
    parent.appendChild(list);
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

// TODO-688: IPA transcriptions ship in popup JSON per pitch GROUP (alongside
// `pitchPositions`, populated only for Yomitan `ipa`-mode dicts; empty for plain
// pitch-accent dicts). They are phonetic notation — same nature as pitch — so we
// render them inside the pitch group, as small `[ipa]` tags after the accent
// list. An empty/absent transcriptions array renders nothing (plain pitch dicts
// and dicts without IPA are untouched).
function createTranscriptionsHtml(transcriptions) {
    if (!transcriptions?.length) return null;
    const list = el('ul', { className: 'pitch-transcriptions' });
    transcriptions.forEach((ipa) => {
        const li = el('li', { className: 'pitch-transcription' });
        li.appendChild(el('span', { className: 'pitch-transcription-tag', textContent: `[${ipa}]` }));
        list.appendChild(li);
    });
    return list;
}

function createPitchGroup(pitchData, reading) {
    const container = el('div', { className: 'pitch-group', 'data-details': pitchData.dictionary });
    container.appendChild(el('span', { className: 'pitch-dict-label', textContent: pitchData.dictionary }));

    const list = el('ul', { className: 'pitch-entries' });
    (pitchData.pitchPositions || []).forEach((pitch) => {
        const li = el('li');
        li.appendChild(createPitchHtml(reading, pitch));
        li.appendChild(document.createTextNode(` [${pitch}]`));
        list.appendChild(li);
    });
    container.appendChild(list);

    const transcriptions = createTranscriptionsHtml(pitchData.transcriptions);
    if (transcriptions) {
        container.appendChild(transcriptions);
    }

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
            const unique = (pitch.pitchPositions || []).filter(pos => !seen.has(pos));
            // TODO-688: a group with no unique pitch positions but with IPA
            // transcriptions (Yomitan `ipa`-mode dicts have no pitch positions)
            // must still render, or the transcriptions are silently dropped.
            const hasTranscriptions = pitch.transcriptions?.length;
            if (unique.length > 0 || hasTranscriptions) {
                unique.forEach(pos => seen.add(pos));
                pitchContainer.appendChild(createPitchGroup(
                    { dictionary: pitch.dictionary, pitchPositions: unique, transcriptions: pitch.transcriptions },
                    reading));
            }
        });
    } else {
        pitches.forEach(pitch => pitchContainer.appendChild(createPitchGroup(pitch, reading)));
    }
    body.appendChild(pitchContainer);
    section.appendChild(body);
    return section;
}

// Redirect-only dictionary records add no definition: they only point the
// queried spelling at another headword. English dictionaries encode that
// intent in a few equivalent ways (a `redirect`/`redirected` definition or term
// tag, a "Redirected from …" structured-content label, or a `non-lemma` entry
// whose structured content contains the standalone `redirect` chip). Keep the
// predicate data-shaped rather than dictionary-name-shaped so the same rule
// works for LDOCE, OALD, and future imports without per-dictionary branches.
function redirectMarkerKind(content) {
    if (typeof content === 'string') {
        let value = content;
        const trimmed = value.trim();
        if ((trimmed.startsWith('{') || trimmed.startsWith('['))) {
            try {
                return redirectMarkerKind(JSON.parse(trimmed));
            } catch (_) {
                // Not JSON; it may be dictionary HTML, handled as text below.
            }
        }
        value = value
            .replace(/<[^>]*>/g, ' ')
            .replace(/\s+/g, ' ')
            .trim()
            .toLowerCase();
        if (/\bredirected\s+from\b/.test(value)) return 2;
        if (value === 'redirect') return 1;
        return 0;
    }
    if (Array.isArray(content)) {
        return content.reduce(
            (kind, item) => Math.max(kind, redirectMarkerKind(item)), 0);
    }
    if (content && typeof content === 'object') {
        // Yomitan structured-content nodes keep user-visible text below
        // `content` (and legacy text nodes below `text`). Do not scan style/data
        // metadata: a CSS class named "redirect" is not a redirect record.
        if (Object.prototype.hasOwnProperty.call(content, 'content')) {
            return redirectMarkerKind(content.content);
        }
        if (typeof content.text === 'string') {
            return redirectMarkerKind(content.text);
        }
    }
    return 0;
}

function isRedirectGlossary(glossary) {
    if (!glossary) return false;
    const tags = `${glossary.definitionTags || ''} ${glossary.termTags || ''}`
        .trim()
        .toLowerCase();
    if (/(?:^|\s)redirect(?:ed)?(?:\s|$)/.test(tags)) return true;

    const marker = redirectMarkerKind(glossary.content);
    if (marker === 2) return true;
    return marker === 1 && /(?:^|\s)non-lemma(?:\s|$)/.test(tags);
}

function createGlossarySectionWrapper(entry) {
    // TODO-804: a term dictionary disabled in 词典管理 (its show/hide switch off)
    // is added to hiddenDictionaryNames by the host. Term dictionaries are still
    // registered in the native engine (see AppModel.bucketDictPaths — hidden term
    // dicts stay in the bucket because filtering happens at render time), so the
    // FFI lookup still returns their glossaries. Drop them here, the single
    // grouping point shared by every term-glossary render path, so a disabled
    // dictionary's definitions never surface in the lookup popup. Mirrors how
    // collapsedDictionaryNames is consumed in createGlossarySection.
    const hiddenDictionaryNames = window.hiddenDictionaryNames || [];
    const grouped = {};
    entry.glossaries.forEach(g => {
        if (hiddenDictionaryNames.includes(g.dictionary)) return;
        if (isRedirectGlossary(g)) return;
        if (!grouped[g.dictionary]) grouped[g.dictionary] = [];
        grouped[g.dictionary].push({
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

// 单词音频播放：统一走 WebView 自己的 HTML5 <audio>，不再回 Dart 交给 native
// MediaPlayer（Android）或 libmpv（桌面 just_audio）——那条桌面路径每播一次都要
// stop→loadfile→play，比手机的原生同步 prepare 慢。三端（app 内 InAppWebView / app 外
// overlay WebView2 / 浏览器扩展真实浏览器）现在同一路径：resolveWordAudio 已返回可直接
// 播放的 URL（远端 http、本地 base64 data:）。新播放固定先掐上一段（interrupt 行为；
// 宿主从未注入过别的模式），留 window.__fushiWordAudio 句柄。音量取
// window.lookupAudioVolume（0..1，宿主注入；扩展缺省 1）。
// BUG-1204：播放失败的**原因**必须留下痕迹。原实现是 `.catch(() => false)`，把
// `audio.play()` 抛出的 DOMException 整个丢掉，宿主只拿到一个光秃秃的 false —— 于是
// 「app 启动后第一次发音必失败、之后都成功」这种可复现的症状，日志里查不出到底是
// autoplay 策略拦截（NotAllowedError）、解码失败（NotSupportedError）还是被后一次播放
// 掐掉（AbortError），只能靠猜。三种原因的修法完全不同，这正是 BUG-1015 吃过的亏。
//
// 返回值仍是 boolean（`if (!await playWordAudio(url))` 与宿主的 `r === true` 契约一字
// 未动），原因另存到 realm 上的 [__fushiWordAudioLastError]，由注入的 report 包装读走
// 并随 `wordAudioPlayed` 回传。成功时清空，避免下一次失败读到上一次的陈旧原因。
function playWordAudio(audioUrl) {
    const noteError = (e) => {
        window.__fushiWordAudioLastError =
            (e && (e.name || e.message)) || 'UnknownError';
    };
    try {
        if (!audioUrl) {
            window.__fushiWordAudioLastError = 'EmptyUrl';
            return Promise.resolve(false);
        }
        if (window.__fushiWordAudio) {
            try { window.__fushiWordAudio.pause(); } catch (_) { /* no-op */ }
        }
        const audio = new Audio(audioUrl);
        const v = window.lookupAudioVolume;
        if (typeof v === 'number' && isFinite(v)) {
            audio.volume = Math.max(0, Math.min(1, v));
        }
        window.__fushiWordAudio = audio;
        return audio.play().then(() => {
            window.__fushiWordAudioLastError = '';
            return true;
        }).catch((err) => {
            noteError(err);
            return false;
        });
    } catch (e) {
        noteError(e);
        return Promise.resolve(false);
    }
}

// Dart 自动发音（打开词条自动读）驱动入口：宿主解析好 URL 后经 evaluateJavascript
// 调此函数，让弹窗用同一 <audio> 路径播，桌面自动发音同样变快、且与手动 ♪ 一致。
window.__fushiPlayWordAudioUrl = playWordAudio;

function showAudioError(button) {
    setButtonIcon(button, 'audioOff');
    setTimeout(() => {
        setButtonIcon(button, 'audio');
    }, 1500);
}

// BUG-842：Windows 桌面查词弹窗是 WebView2 离屏合成（CompositionController→DirectComposition
// visual→WGC 捕获→Flutter texture，再经 HibikiAppUiScale 的 FittedBox 拉伸）。HTML `title`
// 的原生工具提示是 WebView2 生成的独立 top-level OS 窗口，按「父 HWND 原点 + WebView 内部未
// 拉伸的逻辑坐标」定位，与纹理真正合成的位置（弹窗卡片）错位，于是提示「飞」到窗口角落。
// 同型的原生右键菜单错位已由 dictionary_popup_webview.dart 换 Flutter showMenu 规避，但 title
// 无法拦截/重定位。这里给内联动作按钮改用 DOM 内自绘提示（随纹理正确合成），并去掉原生
// title。复用 .audio-hint 的视觉（popup.css 里 .fushi-btn-tip 与其共用规则）。
let __fushiBtnTipEl = null;
let __fushiBtnTipHideTimer = 0;
function __fushiShowButtonTip(button) {
    const text = button && button.dataset ? button.dataset.fushiTip : '';
    if (!text) return;
    if (__fushiBtnTipHideTimer) {
        clearTimeout(__fushiBtnTipHideTimer);
        __fushiBtnTipHideTimer = 0;
    }
    if (!__fushiBtnTipEl || !__fushiBtnTipEl.isConnected) {
        __fushiBtnTipEl = el('div', { className: 'fushi-btn-tip' });
        __fushiOverlayParent().appendChild(__fushiBtnTipEl);
    }
    __fushiBtnTipEl.textContent = text;
    __fushiBtnTipEl.classList.remove('visible'); // 先复位再量尺寸定位
    // 先量尺寸再定位：按钮行在弹窗顶部，优先置于按钮下方居中；下方放不下再翻到上方，
    // 并夹在视口内。锚定屏幕坐标而非视口边缘，in-app 全窗弹窗与 app 外覆盖窗都可见。
    const btnRect = button.getBoundingClientRect();
    const tipRect = __fushiBtnTipEl.getBoundingClientRect();
    let left = btnRect.left + btnRect.width / 2 - tipRect.width / 2;
    left = Math.max(4, Math.min(left, window.innerWidth - tipRect.width - 4));
    let top = btnRect.bottom + 6;
    if (top + tipRect.height > window.innerHeight - 4) {
        top = btnRect.top - tipRect.height - 6;
    }
    __fushiBtnTipEl.style.left = left + 'px';
    __fushiBtnTipEl.style.top = Math.max(4, top) + 'px';
    requestAnimationFrame(() => {
        if (__fushiBtnTipEl) __fushiBtnTipEl.classList.add('visible');
    });
}
function __fushiHideButtonTip() {
    if (!__fushiBtnTipEl) return;
    __fushiBtnTipEl.classList.remove('visible');
    if (__fushiBtnTipHideTimer) clearTimeout(__fushiBtnTipHideTimer);
    __fushiBtnTipHideTimer = setTimeout(() => {
        if (__fushiBtnTipEl) {
            __fushiBtnTipEl.remove();
            __fushiBtnTipEl = null;
        }
        __fushiBtnTipHideTimer = 0;
    }, 220);
}
// 给内联动作按钮挂 DOM 悬停/聚焦提示（替代会在离屏 WebView2 上飞走的原生 title）。
// 设 aria-label 保留可访问性、显式移除 title（关键：不再依赖原生工具提示）。用
// dataset 标志保证监听器只挂一次——refresh 时可反复调用刷新文案而不叠加监听。
function setInlineButtonTip(button, text) {
    if (!button) return;
    button.removeAttribute('title');
    if (!text) {
        delete button.dataset.fushiTip;
        button.removeAttribute('aria-label');
        return;
    }
    button.dataset.fushiTip = text;
    button.setAttribute('aria-label', text);
    if (button.dataset.fushiTipBound === '1') return;
    button.dataset.fushiTipBound = '1';
    button.addEventListener('pointerenter', function() { __fushiShowButtonTip(button); });
    button.addEventListener('focus', function() { __fushiShowButtonTip(button); });
    button.addEventListener('pointerleave', __fushiHideButtonTip);
    button.addEventListener('blur', __fushiHideButtonTip);
    button.addEventListener('pointerdown', __fushiHideButtonTip);
}

// TODO-1251: 当词条本来就没有配置音频源（resolveWordAudio 返回 null）时，旧行为只瞬间
// 把 ♪ 闪成 ✕ 再静默恢复，读起来像「点了没反应/出错了」，用户不知道是「这个
// 词没有发音」。这里在按钮旁弹一个短暂的本地化提示（i18nNoAudioAvailable，宿主经
// buildPopupSettingsJs 注入），并把按钮暂时切到静音态，明确「暂无发音」而非静默。提示
// 锚定到按钮的屏幕坐标而非视口边缘，保证在 in-app 全窗弹窗和 app 外覆盖窗
// （窗口被裁到卡片 bbox）两种表面都可见。区别于真正的播放失败（showAudioError）。
function showNoAudioHint(button) {
    const message = window.i18nNoAudioAvailable || '暂无发音';
    setButtonIcon(button, 'audioOff');
    button.classList.add('audio-unavailable');
    // BUG-842：原生 title 在离屏 WebView2 上会飞到窗口角落，且这里已有自绘 .audio-hint
    // 提示，故只保留 aria-label（可访问性），不设 title。
    button.setAttribute('aria-label', message);
    // 移除可能残留的旧提示，避免叠加。
    const stale = __fushiRootNode().querySelector('.audio-hint');
    if (stale) stale.remove();
    const hint = el('div', { className: 'audio-hint', textContent: message });
    __fushiOverlayParent().appendChild(hint);
    // 先量尺寸再定位：置于按钮上方居中，空间不足翻到下方，并夹在视口内。
    const btnRect = button.getBoundingClientRect();
    const hintRect = hint.getBoundingClientRect();
    let left = btnRect.left + btnRect.width / 2 - hintRect.width / 2;
    left = Math.max(4, Math.min(left, window.innerWidth - hintRect.width - 4));
    let top = btnRect.top - hintRect.height - 6;
    if (top < 4) top = btnRect.bottom + 6;
    hint.style.left = left + 'px';
    hint.style.top = top + 'px';
    requestAnimationFrame(() => hint.classList.add('visible'));
    setTimeout(() => {
        setButtonIcon(button, 'audio');
        button.classList.remove('audio-unavailable');
        hint.classList.remove('visible');
        setTimeout(() => hint.remove(), 220);
    }, 1800);
}

function createAudioButton(expression, reading, entryIndex) {
    const button = el('button', {
        className: 'inline-action-button audio-button',
        onclick: async () => {
            const audioUrl = await resolveCachedAudioUrl(expression, reading || expression, entryIndex);
            if (!audioUrl) {
                // TODO-1251: 无音频源 → 明确「暂无发音」提示，区别于播放失败。
                showNoAudioHint(button);
                return;
            }
            if (!await playWordAudio(audioUrl)) {
                showAudioError(button);
            }
        }
    });
    setButtonIcon(button, 'audio');
    return button;
}

// 收藏按钮（☆/★）：切换收藏当前词条。书内阅读与视频共用同一套弹窗，故两表面
// 都获得此按钮；落库/计入统计的来源由 Dart 侧 dictionarySourceType 决定。
function createFavoriteButton(expression, reading) {
    const button = el('button', {
        className: 'inline-action-button favorite-button',
        onclick: async () => {
            button.disabled = true;
            try {
                const nowFav = await window.flutter_inappwebview.callHandler(
                    'favoriteEntry', { expression, reading });
                setButtonIcon(button, nowFav ? 'favorited' : 'favorite');
                button.classList.toggle('favorited', !!nowFav);
            } catch (e) {
                // 收藏失败不能让按钮卡死，恢复可点状态并记日志。
                console.error('favorite button: favoriteEntry failed', e);
            } finally {
                button.disabled = false;
            }
        }
    });
    setButtonIcon(button, 'favorite');
    // 初始状态：查询是否已收藏，设收藏图标。
    window.flutter_inappwebview.callHandler('favoriteCheck', { expression, reading })
        .then(isFav => {
            setButtonIcon(button, isFav ? 'favorited' : 'favorite');
            button.classList.toggle('favorited', !!isFav);
        })
        .catch(() => {});
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
            markGlobalLookupExtHit(tag);
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
        markGlobalLookupExtHit(expressionSpan);
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

    buttonsContainer.appendChild(createFavoriteButton(expression, reading));

    // BUG-185 (TODO-084/087): the mine button's "已制卡 ✓ / 可制卡 +" state is
    // DETECTED AT LOOKUP TIME and reflects Anki's REAL card existence.
    //
    // PRIMARY MECHANISM — detection at lookup time:
    //   When the popup renders this word (createEntryHeader runs as part of
    //   renderPopup, which rebuilds the DOM on every lookup), the initial
    //   `duplicateCheck` below queries Anki live (AnkiConnect findNotes /
    //   AnkiDroid findDuplicateNotes — both already real-time) and sets a real
    //   `data-mined` state: card in Anki → 已制卡 ✓; card absent → 可制卡 +.
    //   `data-mined` is the source of truth for what a click does, so the ✓ is
    //   NOT decorative — it means "Anki has this card right now".
    //
    //   TODO-084 (re-look-up the word after deleting its card in Anki) is
    //   satisfied for free: a fresh lookup re-renders → re-runs this detection →
    //   card is gone → 可制卡 → can re-mine.
    //
    // EDGE-CASE FALLBACK — same popup, card deleted in Anki WITHOUT re-looking
    //   up (TODO-087): a click on the 已制卡 ✓ button re-verifies against Anki
    //   first; if the card is genuinely gone it re-mines, if it still exists
    //   (dupes off) it just refreshes ✓ and adds nothing. This is a safety net
    //   for stale state, not the primary path.
    //
    // TODO-270 D — THIRD STATE "latest editable": the single most-recently-mined
    //   word (whose backend returned a real note id, AnkiConnect only) shows a
    //   GREEN ✓ with an undo glyph (✓⤺) instead of an ordinary ✓. Clicking it
    //   OVERWRITES that card (updateEntry → repo.updateMinedNote) so a mistake on
    //   the last card is fixed in place — no delete-then-recreate. Mining another
    //   word, or re-querying, supersedes it back to an ordinary ✓ (only the most
    //   recent card stays editable). AnkiDroid returns no id → never green ✓⤺.
    const setMineState = (isMined) => {
        // Single source of truth for the button's lookup-time-detected state.
        // The optional second flag is the "latest editable" sub-state; it is only
        // meaningful when the word is the current latest-mined card.
        const latest = isMined && isLatestEditable(expression, reading);
        mineButton.dataset.mined = isMined ? '1' : '';
        mineButton.dataset.latest = latest ? '1' : '';
        // TODO-1325 还原：应用户要求，制卡按钮回到 ✓✓↩ 文本标记（+ 可制卡 /
        // ✓ 已制卡 / ✓↩ 最新可改），不再走 SVG 图标（audio/favorite 等其余按钮保留 SVG）。
        // TODO-1338：给 ↩ 追加 VS15(U+FE0E) 强制「文本呈现」，杜绝系统把 U+21A9 走彩色
        // emoji 回退变乱码（字体隔离在 popup.css .mine-button 单色符号栈里，此处是双保险）。
        mineButton.textContent = isMined ? (latest ? '✓↩︎' : '✓') : '+';
        if (isMined) {
            mineButton.classList.add('duplicate');
        } else {
            mineButton.classList.remove('duplicate');
        }
        if (latest) {
            mineButton.classList.add('latest');
        } else {
            mineButton.classList.remove('latest');
        }
        // TODO-1360：「在 Anki 中打开卡片」按钮的可见性跟随真实制卡态——已制卡（✓）时
        // 显示、可制卡（+）时隐藏。与 mineButton 同源于 data-mined，绝不装饰。
        if (openAnkiButton) {
            openAnkiButton.classList.toggle('open-anki-hidden', !isMined);
        }
    };
    const mineButton = el('button', {
        className: 'mine-button',
        textContent: '+',
        ontouchstart: () => {
            lastSelection = __fushiSel()?.toString() || '';
        },
        onclick: async () => {
            // Single-flight guard against double-firing one click. Always cleared
            // in finally — it is the ONLY thing that disables the button, never a
            // permanent lock (BUG-077).
            if (mineButton.dataset.mining === '1') return;
            mineButton.dataset.mining = '1';
            mineButton.disabled = true;
            try {
                if (mineButton.dataset.latest === '1' && isLatestEditable(expression, reading)) {
                    // TODO-270 D green ✓⤺: this is the latest mined card and it
                    // carries a real note id → OVERWRITE that note in place with
                    // the freshly-built fields (does NOT create a second card).
                    const reply = await updateEntry(
                        lastMinedNoteId, expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
                    const result = parseMineResult(reply);
                    // A successful update keeps the same note id (handler echoes it)
                    // → stays the editable latest. A failed update drops the latest
                    //   flag back to a plain ✓ (the card is still mined).
                    rememberLatestMined(expression, reading, result.noteId);
                    setMineState(true);
                    return;
                }

                if (mineButton.dataset.mined === '1') {
                    // TODO-1007/1008: the card already exists (detected at lookup
                    // time, but NOT this session's editable latest). Instead of the
                    // old silent re-verify-then-return (which made ✓ feel dead),
                    // ALWAYS hand off to the host action sheet so the user can
                    // explicitly choose: overwrite a specific matching card, add a
                    // new duplicate, or view / open the card in Anki. Works for
                    // cards created elsewhere / in a previous session.
                    if (typeof window.flutter_inappwebview.callHandler === 'function') {
                        // BUG-1064 两条车道，同一套选择：
                        //   * 宿主有原生对话框（app 内）→ minedCardAction，Flutter 居中
                        //     对话框（BUG-1040），行为逐字不变。
                        //   * 宿主没有（app 外裸窗 / 扩展）→ 在本 WebView 里画页内面板。
                        //     以前这里也调 minedCardAction，但那些宿主只会回 null，
                        //     于是点 ✓ 完全没反应。
                        // 两条车道回同一个 {outcome, result}，收尾只有一份。
                        const action = hasNativeMinedCardAction()
                            ? {
                                outcome: 'handled',
                                result: parseMineResult(await minedCardAction(
                                    expression, reading, frequencies, pitches, rules, matched, idx, lastSelection)),
                            }
                            : await runInPageMinedCardAction(
                                expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
                        if (action.outcome === 'handled') {
                            // The host applied the chosen action (or the user cancelled,
                            // in which case it echoes the unchanged mined state). Refresh
                            // from Anki and update the editable-latest flag.
                            if (window.sentenceDraftEnabled) {
                                sentenceCtxPrev = 0;
                                sentenceCtxNext = 0;
                                sentenceDraftCount = 0;
                                refreshAllSentenceContextPickers();
                            }
                            window.resetSelectedDictionariesForEntry(idx);
                            if (action.result.ankiConnect) {
                                rememberLatestMined(expression, reading, action.result.noteId);
                            }
                            const stillMined = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                            setMineState(stillMined);
                            return;
                        }
                        // outcome === 'fallthrough'：反查发现 Anki 里其实已经没有这张卡
                        // （别处删了）→ 不弹面板，落到下面的新卡制卡路径重制，与 app 内
                        // runAnkiMinedCardAction 的 matches.isEmpty → mineNew 同语义。
                        mineButton.dataset.mined = '';
                    } else {
                        // No bridge (degenerate harness): keep the old behaviour.
                        const stillExists = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                        if (stillExists && !window.allowDupes) {
                            setMineState(true);
                            return;
                        }
                        // Deleted in Anki (or dupes allowed) → fall through and re-mine.
                    }
                }

                const reply = await mineEntry(expression, reading, frequencies, pitches, rules, matched, idx, lastSelection);
                const result = parseMineResult(reply);
                // TODO-393：制卡后宿主清空草稿（合并卡已落地），同步把 JS 两个镜像标量
                // 归零并刷新上下文选择器，使两端状态在同一事件归零、不漂移。仅在启用草稿
                // 的表面才动 DOM（纯查词页未接入时不渲染上下文选择器）。
                if (window.sentenceDraftEnabled) {
                    sentenceCtxPrev = 0;
                    sentenceCtxNext = 0;
                    sentenceDraftCount = 0;
                    refreshAllSentenceContextPickers();
                }
                // TODO-645 / BUG-358: the dictionary pick is one-shot too — drop
                // THIS entry selection so the next card mined from the same
                // (reused warm-slot) entryIdx does not inherit it. Per-entry only:
                // sibling entries keep their own picks.
                window.resetSelectedDictionariesForEntry(idx);
                const refreshFromAnki = async () => {
                    // Re-detect from Anki so the post-mine state is the real one.
                    const wasAdded = await window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading });
                    setMineState(wasAdded);
                };

                if (result.ankiConnect) {
                    // TODO-270 D: a freshly mined card with a real note id becomes
                    // the new "latest editable"; this also supersedes any prior
                    // latest word (only one editable card at a time).
                    rememberLatestMined(expression, reading, result.noteId);
                    await refreshFromAnki();
                }
            } catch (e) {
                // BUG-077: a rejected mineEntry/duplicateCheck (Dart handler threw,
                // or a JS payload-builder error) must never leave the button stuck
                // disabled showing '+' with no feedback. Restore it to a clickable
                // 可制卡 + so the user sees it failed and can retry.
                console.error('mine button: mineEntry failed', e);
                setMineState(false);
            } finally {
                // The single-flight guard is ALWAYS released; the button's
                // long-term enabled/disabled is driven only by data-mined, never
                // stuck disabled.
                mineButton.dataset.mining = '';
                mineButton.disabled = false;
            }
        }
    });
    buttonsContainer.appendChild(mineButton);

    // TODO-1360：「在 Anki 中打开卡片」按钮——仅当该词已制卡（data-mined）时显示。点击
    // 让宿主据 expression/reading 反查 Anki 全部命中卡并直接跳转打开（单卡直开 / 多卡弹
    // 选择 / 无卡提示）。与制卡 ✓ 解耦：✓ 仍走覆写·新增·查看的操作单，本按钮只做「查找并
    // 在 Anki 中打开」这一件事。初始隐藏，由 setMineState 据真实制卡态切换可见性。
    const openAnkiButton = el('button', {
        className: 'inline-action-button open-anki-button open-anki-hidden',
        onclick: async () => {
            // 单飞守卫：跳转是异步（反查 + 打开 Anki），避免连点重复触发。始终在
            // finally 释放，绝不永久禁用（与 mineButton 单飞同源）。
            if (openAnkiButton.dataset.busy === '1') return;
            openAnkiButton.dataset.busy = '1';
            openAnkiButton.disabled = true;
            try {
                // BUG-1064：与点 ✓ 同一分流——宿主有原生对话框（app 内）就交给
                // openInAnki；没有（app 外裸窗 / 扩展）则就地处理，否则那根桥同样
                // 只会回 null，按钮转一圈什么都不发生。
                if (hasNativeMinedCardAction()) {
                    await window.flutter_inappwebview.callHandler(
                        'openInAnki', { expression, reading });
                } else {
                    await runInPageOpenInAnki(openAnkiButton, expression, reading);
                }
            } catch (e) {
                // 跳转失败不能卡死按钮；记日志并恢复可点（宿主侧另有 toast 反馈）。
                console.error('open-anki button: openInAnki failed', e);
            } finally {
                openAnkiButton.dataset.busy = '';
                openAnkiButton.disabled = false;
            }
        }
    });
    setButtonIcon(openAnkiButton, 'openInAnki');
    buttonsContainer.appendChild(openAnkiButton);
    // Lookup-time detection: query Anki's real card existence for THIS word as
    // the popup renders it, and set the accurate 已制卡 ✓ / 可制卡 + state.
    //
    // TODO-614 (overwrite scope = all): when the card already exists but is NOT
    // this session's most-recently-mined word, ask the host for an overwrite
    // target note id. The host only returns a real id when the user set the
    // overwrite range to "all" (AnkiConnect can resolve the id); it returns null
    // for the default "latest" range or AnkiDroid. A real id promotes this
    // earlier card to the editable ✓↩ latest state so a single click overwrites
    // it in place — no need to have mined it in this popup session. A null reply
    // keeps the ordinary two-state behaviour (Never break userspace).
    window.flutter_inappwebview.callHandler('duplicateCheck', { expression, reading }).then(async isDuplicate => {
        if (isDuplicate && !isLatestEditable(expression, reading)) {
            try {
                const noteId = await window.flutter_inappwebview.callHandler(
                    'overwriteTargetNoteId', { expression, reading });
                if (typeof noteId === 'number' && Number.isFinite(noteId)) {
                    rememberLatestMined(expression, reading, noteId);
                }
            } catch (e) {
                // A failed overwrite-target probe must never break the ✓/+ paint;
                // fall back to the ordinary mined state below.
                console.error('overwriteTargetNoteId probe failed', e);
            }
        }
        setMineState(isDuplicate);
    });

    // TODO-393「查词窗口句子上下文制卡」：仅支持草稿的表面（书籍/有声书/视频；宿主接受
    // setSentenceContext）渲染「上 N 句 / 下 N 句」上下文选择器。选「上 N」「下 N」把当前
    // 句前/后 N 句作上下文整体设进宿主草稿；紧挨的「×」清空回到只制当前句。不碰 mineEntry
    // 字段契约——只发上下文信号。
    if (window.sentenceDraftEnabled) {
        const picker = buildSentenceContextPicker();
        refreshSentenceContextPicker(picker);
        buttonsContainer.appendChild(picker);

        // TODO-382/393 可撤销：「清空已加句子」按钮（仅已选上下文时显示）。点一次把上下文
        // 句数归零（回到只制当前句），所有选择器同步——明确、可见的撤销入口。
        const clearButton = el('button', {
            className: 'inline-action-button clear-draft-button',
            onclick: async () => {
                if (clearButton.dataset.busy === '1') return;
                clearButton.dataset.busy = '1';
                clearButton.disabled = true;
                try {
                    sentenceCtxPrev = 0;
                    sentenceCtxNext = 0;
                    sentenceDraftCount = await clearSentenceDraftOnHost();
                    refreshAllSentenceContextPickers();
                } finally {
                    clearButton.dataset.busy = '';
                    clearButton.disabled = false;
                }
            },
        });
        setButtonIcon(clearButton, 'close');
        refreshClearDraftButton(clearButton);
        buttonsContainer.appendChild(clearButton);
    }

    // Niratan「制卡前调整·选择句子上下文」：独立于上面被砍掉的内联步进器
    // （kSentenceContextPickerEnabled 恒 false）。支持草稿且宿主接入了预览回调的表面
    // （reader/有声书/视频，window.sentenceContextPreviewEnabled 为真）渲染一个「调整
    // 上下文」按钮，点开模态在里面看前/当前/后真实句并增减上下文、确认制卡。一键「+」
    // 制卡不受影响。
    if (window.sentenceContextPreviewEnabled) {
        const adjustBtn = el('button', {
            className: 'inline-action-button ctx-adjust-button',
            onclick: function() {
                // BUG-763/766：改弹 app 原生顶层对话框（不再画在查词弹窗 WebView 内）。
                // entryIndex 用点击时的稳定 DOM 序（:scope > .entry），与确认制卡回点的
                // fushiPopupMineEntryByIndex 同一套索引。
                var entryEl = adjustBtn.closest('.entry');
                var idx = 0;
                if (entryEl && entryEl.parentNode) {
                    var siblings = entryEl.parentNode.querySelectorAll(':scope > .entry');
                    idx = Array.prototype.indexOf.call(siblings, entryEl);
                    if (idx < 0) idx = 0;
                }
                // BUG-1326：参数必须原样传**对象**（与本文件其余 callHandler 一致）。
                // 之前这里独一份地 JSON.stringify 了，宿主 handler 只认 Map（args[0] is
                // Map），于是 entryIndex 恒退化成 0、matched 恒为空——「确认制卡」永远去
                // 点第一个词条的按钮（用户在第 2+ 个词条上点，看到的就是「没反应」），
                // 当前句里的词也不高亮。
                window.flutter_inappwebview.callHandler(
                    'openSentenceContextModal',
                    { entryIndex: idx, matched: matched });
            },
        });
        setButtonIcon(adjustBtn, 'tune');
        // BUG-842：DOM 提示替代原生 title（离屏 WebView2 上原生 title 会飞到窗口角落）。
        setInlineButtonTip(adjustBtn, (window.i18nCtx && window.i18nCtx.adjust) || '');
        buttonsContainer.appendChild(adjustBtn);
    }

    header.appendChild(buttonsContainer);
    
    return header;
}

window.fushiPopupMineFirstEntry = async function() {
    const mineButton = __fushiRootNode().querySelector('.mine-button');
    if (!mineButton || mineButton.disabled) {
        return false;
    }
    mineButton.click();
    return true;
};

// 查词弹窗的键盘快捷键（用户请求：「点那个加号的动作」要能用键盘触发）。
// 实际覆盖面：app 内弹窗、浏览器扩展、以及 app 外**已获得焦点的剪贴板面板**。app 外的
// 瞬态查词覆盖窗带 WS_EX_NOACTIVATE、永不接收键盘焦点（且 runner 无键盘转发），本监听在
// 那个表面上收不到任何 keydown——不是没接线，是物理上到不了，别把它算进「都能用」。
// 制卡默认 Ctrl+Enter；app 外的裸 WebView2 表面由 popup_settings_injection
// 注入 window.__fushiPopupKeyBindings 覆盖成用户在「快捷键」设置里配的绑定（dictionaryPopup
// scope 的三个动作）。三种取值语义各不相同，别合并：
//   · undefined（浏览器扩展：没有注入通道）→ 用下面的内置默认；
//   · null（app 内宿主：Dart 侧派发）→ 本监听整个关掉，避免同一次按键被 JS 和 Flutter
//     各处理一遍而制出两张卡；
//   · 某个动作是 []（未绑 / 用户清空）→ 该动作关掉，而不是回退默认（否则「清空」等于没清）。
// 表里带上 next/prev 而不只是 mine，是因为 Flutter 侧的通道开关按 scope 生效：设置页会给
// 本 scope 每个动作都渲染键盘入口，只认 mine 会让另两个成为「能配、按了没反应」的死绑定。
// 制卡实现上只调 fushiPopupMineFirstEntry() 去点那颗按钮，**绝不另起第二条制卡桥调用**：
// 三态（＋/✓/✓↩︎）、单飞门、查重刷新全在按钮的 onclick 里，另起一条既会绕过它们，也会
// 撞上「本文件里制卡桥有且只有一处调用」的守卫测试（popup_append_sentence_asset_test）。
const FUSHI_POPUP_KEY_DEFAULT_BINDINGS = {
    mine: [{ key: 'enter', mods: ['ctrl'] }],
    next: [],
    prev: [],
};
// 本次 keydown 命中哪个弹窗动作：'mine' / 'next' / 'prev' / null。判据与滚轮那套同构：
// 键名归一后相等，且当前按下的修饰键集合与某条绑定**全等**（故 Ctrl+Enter 绝不会被
// Ctrl+Shift+Enter 误触）。
function fushiPopupKeyAction(e) {
    const raw = window.__fushiPopupKeyBindings;
    if (raw === null) return null;
    const cfg = (raw && typeof raw === 'object') ? raw : FUSHI_POPUP_KEY_DEFAULT_BINDINGS;
    // Flutter 侧 _webKeyName 的同款归一：全小写 + 去空格，空格键特判成 'space'。
    const name = e.key === ' ' ? 'space' : String(e.key || '').toLowerCase().replace(/ /g, '');
    if (!name) return null;
    const pressed = [];
    if (e.altKey) pressed.push('alt');
    if (e.ctrlKey) pressed.push('ctrl');
    if (e.shiftKey) pressed.push('shift');
    if (e.metaKey) pressed.push('meta');
    const matches = (list) => Array.isArray(list) && list.some((b) => b &&
        String(b.key || '').toLowerCase() === name &&
        Array.isArray(b.mods) && b.mods.length === pressed.length &&
        b.mods.every((m) => pressed.indexOf(m) >= 0));
    if (matches(cfg.mine)) return 'mine';
    if (matches(cfg.next)) return 'next';
    if (matches(cfg.prev)) return 'prev';
    return null;
}
// 扩展场景下本监听常驻在**宿主页面**的 document 上（弹窗是注入宿主页的 DOM，不是独立文档），
// 所以每一层放行判据都要写足，绝不能在没有弹窗时吞掉网页自己的按键：
//   · 输入框/可编辑区一律放行（宿主页的搜索框、弹窗自己的句子编辑框都靠这条）；
//   · IME 组词期间放行（e.isComposing）——日语输入法的 Enter 是用来确认候选词的，抢了它
//     就等于把输入法打坏，这在一个日语学习工具里是不可接受的回归；
//   · 只有 fushiPopupMineFirstEntry() 真的点到了按钮（返回 true）才 preventDefault，
//     没弹窗 / 按钮禁用时事件原样交还给页面。
function fushiPopupIsEditableTarget(t) {
    if (!t) return false;
    if (t.isContentEditable) return true;
    const tag = String(t.tagName || '').toUpperCase();
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}
window.__fushiPopupKeyListener = async function(e) {
    if (!e || e.isComposing || e.repeat) return;
    if (fushiPopupIsEditableTarget(e.target)) return;
    const action = fushiPopupKeyAction(e);
    if (!action) return;
    let handled = false;
    try {
        if (action === 'mine') {
            handled = (await window.fushiPopupMineFirstEntry()) === true;
        } else if (typeof window.fushiFocusDictionaryEntryMove === 'function') {
            // 与 Alt+滚轮同一执行体：只有焦点真的移动了才算接管；单词条 / 已到首尾时返回
            // 'blocked'，这一帧交还给页面（不吞按键）。
            handled = window.fushiFocusDictionaryEntryMove(action) === 'moved';
        }
    } catch (_) { handled = false; }
    if (handled) {
        e.preventDefault();
        e.stopPropagation();
    }
};
try {
    document.addEventListener('keydown', window.__fushiPopupKeyListener, true);
} catch (_) { /* 无 document（node 单测直接 require 本文件）：跳过 */ }

// BUG-763/766：确认「制卡前调整」原生对话框时，Dart 回点第 idx 个词条（:scope > .entry
// DOM 序，与打开对话框时的 entryIndex 同源）的制卡按钮，复用其全部制卡/查重/覆写逻辑。
window.fushiPopupMineEntryByIndex = function(idx) {
    const root = __fushiRootNode();
    const first = root && root.querySelector('.entry');
    const container = first && first.parentNode;
    if (!container) return false;
    const entries = container.querySelectorAll(':scope > .entry');
    const entry = entries[idx];
    if (!entry) return false;
    const b = entry.querySelector('.mine-button');
    if (!b || b.disabled) return false;
    b.click();
    return true;
};

// TODO-1325 #5 part1：多词条焦点导航（上/下一条词条跳转）。一次查询可能返回多个词条
// (.entry)，每条自成一栏（读音 + 词典释义）。这里提供纯 JS + CSS 的「当前词条」焦点指示：
// 给每条打 data-fushi-entry-index，给当前条加 .entry-current（popup.css 用
// .entry-current .entry-header::before 画 #1a73e8 蓝三角，零字体依赖，与折叠三角同法），并
// scrollIntoView 进视口。Dart 焦点驱动（阅读器 caret 管线 → DictionaryPopupWebViewState.
// focusEntryMove → 这里）按 next/prev 调用。与逐字光标 fushiCaret 正交：只移动词条级指示与
// 视口，绝不触碰 caret ring；用户决策「咱们没有前进后退·咱们是嵌套查词」，故不做历史栈。
(function() {
    const CONTAINER_ID = 'entries-container';
    const CURRENT_CLASS = 'entry-current';

    // DOM 顺序的全部词条 <div.entry>（container 的直接子节点）。
    function listEntries() {
        const container = __fushiContainer();
        if (!container) return [];
        return Array.prototype.slice.call(
            container.querySelectorAll(':scope > .entry'));
    }

    // 给每条打 data-fushi-entry-index（0-based，DOM 顺序），返回词条数组。每次导航前重建，
    // 兼容增量渲染后词条集合变化。
    function indexEntries() {
        const entries = listEntries();
        for (let i = 0; i < entries.length; i++) {
            entries[i].setAttribute('data-fushi-entry-index', String(i));
        }
        return entries;
    }

    // 当前 .entry-current 的下标；无当前项返回 -1。
    function currentIndex(entries) {
        for (let i = 0; i < entries.length; i++) {
            if (entries[i].classList.contains(CURRENT_CLASS)) return i;
        }
        return -1;
    }

    // 把焦点落到下标 index 的词条：切 .entry-current 并滚入视口。index 越界即无操作交由
    // 调用方（这里只在合法下标调用）。
    function applyCurrent(entries, index) {
        for (let i = 0; i < entries.length; i++) {
            if (i === index) entries[i].classList.add(CURRENT_CLASS);
            else entries[i].classList.remove(CURRENT_CLASS);
        }
        const target = entries[index];
        if (target && target.scrollIntoView) {
            target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        }
    }

    // 聚焦指定下标的词条（越界夹到 [0, n-1]）。返回 'moved'（已聚焦）/ 'blocked'（无词条）。
    function focusEntry(index) {
        const entries = indexEntries();
        if (entries.length === 0) return 'blocked';
        let target = index | 0;
        if (target < 0) target = 0;
        if (target > entries.length - 1) target = entries.length - 1;
        applyCurrent(entries, target);
        return 'moved';
    }

    // 相对移动：'next'/'down'/'forward' → 下一条；其余（'prev'/'up'/'backward'）→ 上一条。
    // 到边界返回 'blocked'（不回绕）。首次无当前项时，next 落第 0 条、prev 落最后一条。
    function moveEntry(direction) {
        const entries = indexEntries();
        if (entries.length === 0) return 'blocked';
        const forward = direction === 'next' || direction === 'down'
            || direction === 'forward';
        const cur = currentIndex(entries);
        let next;
        if (cur < 0) {
            next = forward ? 0 : entries.length - 1;
        } else {
            next = forward ? cur + 1 : cur - 1;
        }
        if (next < 0 || next > entries.length - 1) return 'blocked';
        applyCurrent(entries, next);
        return 'moved';
    }

    // 清除当前词条焦点（保留 data-fushi-entry-index），返回词条数。
    function resetEntry() {
        const entries = indexEntries();
        for (let i = 0; i < entries.length; i++) {
            entries[i].classList.remove(CURRENT_CLASS);
        }
        return entries.length;
    }

    window.fushiFocusDictionaryEntry = focusEntry;
    window.fushiFocusDictionaryEntryMove = moveEntry;
    window.fushiFocusDictionaryEntryReset = resetEntry;
})();

// 「自动展开」的单位是「行」，不是「本」：展开数 = window.autoExpandRows × 该词条有效列数。
// 历史设计里它是绝对本数 N，与 --dict-columns 的 N 列 masonry 毫无关联，于是 N 不是列数的整数倍
// 时顶部就参差——比如 1 本展开 + 2 列，展开卡独占第 0 列变很高，剩下的折叠条因第 1 列还是 0 高
// 全堆到第 1 列，「一张大卡 vs 一摞折叠条」。改成按行计数后展开数天生跟随列数，顶部永远是整行。
//
// cols 与 masonry 的 `cols = Math.min(configured, items.length)`（layoutMasonry）严格同源：
// 都用 dictColumns()（= 视口收敛后的 effectiveDictColumns()）再对该词条实际卡片数封顶，所以
// 词典数 < 列数时不会凭空展开不存在的卡。默认列数 1 时 rows × 1 === 旧的绝对本数，老用户零改变。
function autoExpandCount(totalDicts) {
    const rows = window.autoExpandRows ?? 1;
    if (!(rows > 0)) return 0;
    const total = Number.isFinite(totalDicts) && totalDicts > 0 ? totalDicts : 1;
    const cols = Math.max(1, Math.min(dictColumns(), total));
    return rows * cols;
}

// TODO-845: `dictIdx` is the dictionary's global position within an entry's
// glossary body (0-based); `totalDicts` is that entry's total block count, needed
// to cap the effective column count the same way masonry does. The popup
// auto-expands the leading `autoExpandCount(totalDicts)` blocks even when
// collapseDictionaries is on (default 1 row = the historical "only the first
// dictionary expanded" behaviour at the default single column).
//
// BUG-1264: per-dictionary collapse OUTRANKS auto-expand. `collapsedDictionaryNames`
// is an explicit per-book decision the user made in 词典管理 (one tap per row);
// autoExpandRows is a bulk default for the books that carry no such decision.
// Ranking the bulk default first made the per-book toggle a no-op for the leading
// rows x columns blocks -- at the shipped 3 rows x 3 columns that silently ignored
// the flag on the first NINE dictionaries, i.e. "I collapsed it and it still opens".
// So the per-dict flag short-circuits both auto-expand and the global switch; a
// non-collapsed block still follows the old rule (auto-expanded, or global collapse
// off). Users can still open a collapsed block by hand -- <details> stays clickable.
function createGlossarySection(dictName, contents, dictIdx, entryIdx, totalDicts) {
    const details = el('details', { className: 'glossary-group' });
    const perDictCollapsed = (window.collapsedDictionaryNames || []).includes(dictName);
    const autoExpandN = autoExpandCount(totalDicts);
    const autoExpanded = dictIdx < autoExpandN;
    if (!perDictCollapsed && (autoExpanded || !window.collapseDictionaries)) {
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
    summary.__fushiToggleSelection = toggleSelection;
    window.__fushiDictLongPress = (summaryEl) => {
        const toggle = summaryEl?.__fushiToggleSelection;
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

// TODO-833: predicate shared by every entry-render path (renderPopup first /
// rest entries + updatePopupIncremental). A term entry only earns a card when
// it has at least one *visible* glossary section, i.e. createGlossarySectionWrapper
// returns non-null. The wrapper is the single point that applies the BUG-419
// hidden-dictionary filter, so "glossaryWrapper === null" means every dictionary
// for this entry was hidden (or the entry carried no glossary at all). In that
// case header + frequency/pitch badges would render alone as an empty shell card
// (BUG-419 only stripped the body, never the shell). The frequency badge is
// redundant — the same expression's real card already carries it — so skipping
// the whole entry loses no information. Kanji cards go through buildKanjiCards()
// (a separate path) and never reach buildEntryElement, so this never affects them.
//
// Returns the prebuilt glossary wrapper (object) when the entry is renderable, or
// null when it must be skipped. buildEntryElement reuses the same wrapper so the
// hidden filter runs exactly once per entry.
function entryGlossaryWrapperOrNull(entry) {
    return createGlossarySectionWrapper(entry);
}

function buildEntryElement(entry, idx, maximumDictionaryBlocks = Infinity) {
    // TODO-833: decide first whether this entry has any visible glossary. If the
    // hidden-dictionary filter (BUG-419) removed every dictionary, this term entry
    // would otherwise render as a header-only shell with a redundant frequency
    // badge ("标题+频率徽章但正文空白"). Skip the whole card by returning null.
    const glossaryWrapper = entryGlossaryWrapperOrNull(entry);
    if (!glossaryWrapper) {
        return null;
    }

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

    const { details, body, grouped, dictNames } = glossaryWrapper;
    entryDiv.appendChild(details);
    const dictionaryBlockLimit = Number.isFinite(maximumDictionaryBlocks)
        ? Math.max(0, Math.min(dictNames.length, Math.floor(maximumDictionaryBlocks)))
        : dictNames.length;
    for (let dictIdx = 0; dictIdx < dictionaryBlockLimit; dictIdx++) {
        body.appendChild(createGlossarySection(dictNames[dictIdx], grouped[dictNames[dictIdx]], dictIdx, idx, dictNames.length));
    }

    // renderPopup can ask for only the first visible dictionary block, then append
    // the remainder one block per macrotask. Keep the already-filtered/grouped plan
    // on the detached entry node so deferred work never reruns the visibility filter
    // or loses the original dictionary order. Full-build callers retain no state.
    if (dictionaryBlockLimit < dictNames.length) {
        entryDiv.__fushiDeferredGlossaryState = {
            body,
            grouped,
            dictNames,
            entryIdx: idx,
            nextDictionaryIndex: dictionaryBlockLimit,
        };
    }

    return entryDiv;
}

function appendNextDeferredGlossaryBlock(entryDiv) {
    const state = entryDiv && entryDiv.__fushiDeferredGlossaryState;
    if (!state || state.nextDictionaryIndex >= state.dictNames.length) return false;
    const dictIdx = state.nextDictionaryIndex;
    const dictName = state.dictNames[dictIdx];
    const section = createGlossarySection(
        dictName,
        state.grouped[dictName],
        dictIdx,
        state.entryIdx,
        state.dictNames.length,
    );
    state.body.appendChild(section);
    postProcessRuby(section);
    state.nextDictionaryIndex++;
    if (state.nextDictionaryIndex >= state.dictNames.length) {
        delete entryDiv.__fushiDeferredGlossaryState;
    }
    return true;
}

function postProcessRuby(container) {
    // BUG-1098: `.expression ruby` (the entry HEADWORD's furigana, built as a
    // bare <ruby>/<rt> by buildFuriganaEl) joins the glossary bodies here. It
    // used to be skipped entirely, so it never got the per-base unit and never
    // got popup.css's em padding-top reserve; the reading then overflowed the
    // header line box and .expression-scroll (a scroll container whose TOP
    // overflow is unreachable) clipped it. Same wrap, same reserve, no new
    // mechanism.
    container.querySelectorAll('.glossary-content ruby, .expression ruby').forEach(ruby => {
        // Wrap each base — a bare text node OR an element base like <rb>/<span>
        // (monolingual dicts such as 明鏡 emit element bases, not bare text) — in
        // a <span class="ruby-unit"> and pull that base's OWN <rt> into the span.
        // popup.css positions the rt absolutely (left:0/right:0/top:0) against its
        // nearest positioned ancestor AND reserves vertical room via the unit's
        // padding-top; making the per-base unit that ancestor keeps each rt
        // sized/centred over — and lifted above — its own kanji.
        //   - Multi-kanji word (one <ruby>, several base+<rt> pairs, e.g.
        //     将<rt>しょう</rt>棋<rt>ぎ</rt>): without per-base units every rt
        //     stretched to the full <ruby> width and superimposed (BUG-722).
        //   - Element base (<ruby><rb>未然形</rb><rt>みぜんけい</rt></ruby>): the
        //     old text-node-only wrap skipped the <rb>, so no .ruby-unit was made;
        //     the rt kept position:absolute;top:0 but anchored to the bare <ruby>
        //     (line-height:1, no padding-top reserve) and the reading collapsed
        //     onto the base (BUG-733). Wrapping ANY base restores the reserve.
        // Keeping the base as a live text node (bare, in place) or a live element
        // (moved whole, not flattened) preserves ruby lookup selection
        // (BUG-110/123/125/129 must not regress).
        const isEl = (n, tag) =>
            n.nodeType === Node.ELEMENT_NODE && n.tagName === tag;
        const isBlankText = (n) =>
            n.nodeType === Node.TEXT_NODE && !n.textContent.trim();
        const children = Array.from(ruby.childNodes);
        for (const node of children) {
            // A base is anything that is not a reading (<rt>), a fallback paren
            // (<rp>), or inter-token whitespace.
            if (isEl(node, 'RT') || isEl(node, 'RP') || isBlankText(node)) {
                continue;
            }
            // BUG-1098: idempotence. renderPopup calls postProcessRuby(firstEntry)
            // and then postProcessRuby(container) for the tail entries, and the
            // container CONTAINS the first entry — so entry 0's ruby is walked
            // twice. Without this guard the second pass wraps the existing
            // .ruby-unit in ANOTHER .ruby-unit, stacking a second padding-top and
            // pushing entry 0's base text down relative to every other entry.
            // An already-wrapped base is done; leave it alone.
            if (node.nodeType === Node.ELEMENT_NODE &&
                node.classList.contains('ruby-unit')) {
                continue;
            }
            const unit = document.createElement('span');
            unit.className = 'ruby-unit';
            if (node.nodeType === Node.TEXT_NODE) {
                // Bare text base: keep the text live inside the unit.
                unit.textContent = node.textContent;
                node.replaceWith(unit);
            } else {
                // Element base (<rb>/<span>/nested structured-content): move the
                // element itself into the unit so its inner text stays a live,
                // selectable node while the unit becomes the positioned per-base
                // box.
                node.replaceWith(unit);
                unit.appendChild(node);
            }
            // Move this base's own <rt> into the unit, stepping over <rp> fallback
            // parens and whitespace text nodes that sit between a base and its
            // reading.
            let sib = unit.nextSibling;
            while (sib && (isBlankText(sib) || isEl(sib, 'RP'))) {
                sib = sib.nextSibling;
            }
            if (sib && isEl(sib, 'RT')) {
                // BUG-1487: the positioned annotation box is a NEUTRAL span, not
                // the <rt>. WebKit (iOS/macOS WKWebView) force-resets `position`
                // to static on <rt> at the renderer level — measured on a real
                // WKWebView: getComputedStyle(rt).position === 'static' even
                // with display:block forced — so the whole absolute-anchor
                // scheme silently collapsed there and the reading rendered
                // inline to the RIGHT of its kanji (将しょう棋ぎ) while the
                // padding-top reserve stayed empty. Blink honoured it, which is
                // why this only ever showed up on iOS. No engine special-cases a
                // bare <span>, so .ruby-rt carries the position and the <rt>
                // survives as a semantic in-flow child — keeping ruby lookup
                // selection (selection.js closest('rt, rp'),
                // BUG-110/123/125/129) and dictionary `rt {}` custom CSS intact.
                const rtBox = document.createElement('span');
                rtBox.className = 'ruby-rt';
                unit.appendChild(rtBox);
                rtBox.appendChild(sib);
                // BUG-850: reserve horizontal room equal to the reading. The
                // reading box (.ruby-rt) is position:absolute (no inline width),
                // so a reading wider than
                // its kanji would overhang and collide with the next base's
                // reading. This zero-height, in-flow twin of the reading text
                // grows the per-base unit's shrink-to-fit width to the reading
                // width (popup.css .ruby-reserve), while the base stays on its
                // own baseline. aria-hidden + user-select:none keep it out of
                // accessibility and ruby lookup selection (BUG-110/123/125/129).
                const reserve = document.createElement('span');
                reserve.className = 'ruby-reserve';
                reserve.setAttribute('aria-hidden', 'true');
                reserve.textContent = sib.textContent;
                unit.insertBefore(reserve, unit.firstChild);
            }
        }
    });
}

function applyCustomCSS() {
    __fushiOverlayParent().querySelectorAll('style.fushi-custom-css').forEach(el => el.remove());
    if (window.globalDictCSS) {
        const style = document.createElement('style');
        style.className = 'fushi-custom-css';
        style.textContent = window.globalDictCSS;
        __fushiOverlayParent().appendChild(style);
    }
    if (window.customDictCSS && typeof window.customDictCSS === 'object') {
        for (const [dictName, css] of Object.entries(window.customDictCSS)) {
            if (!css) continue;
            const style = document.createElement('style');
            style.className = 'fushi-custom-css';
            style.textContent = constructDictCss(css, dictName);
            __fushiOverlayParent().appendChild(style);
        }
    }
}

// TODO-094 S5: kanji dictionary card. A single-character lookup carries
// per-character kanji results (onyomi / kunyomi / radical / strokes / meanings)
// on window.kanjiResults, injected alongside window.lookupEntries by
// dictionary_popup_webview.dart. Rendered as its own card ABOVE the term
// entries so the reading/meaning of the character itself is visible even when
// the same character is also a term headword. Field names mirror
// FushiKanjiResult.toMap (Dart). Empty / missing -> nothing rendered, so
// multi-char / kana / latin lookups are unaffected.
function createKanjiReadingRow(label, value) {
    if (!value) {
        return null;
    }
    const row = el('div', { className: 'kanji-card-row' });
    row.appendChild(el('span', { className: 'kanji-card-label', textContent: label }));
    row.appendChild(el('span', { className: 'kanji-card-value', textContent: value }));
    return row;
}

function createKanjiCard(kanji) {
    if (!kanji || !kanji.character) {
        return null;
    }
    const card = el('div', { className: 'kanji-card' });

    const head = el('div', { className: 'kanji-card-head' });
    const charEl = el('div', { className: 'kanji-card-char', textContent: kanji.character });
    // Tapping the big character re-looks it up (consistent with the term
    // headword + kanji-breakdown tags), so a kanji card is also a jump-off
    // point for a fresh lookup.
    charEl.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const rect = charEl.getBoundingClientRect();
        markGlobalLookupExtHit(charEl);
        window.flutter_inappwebview.callHandler('onLinkClick', kanji.character, {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height
        });
    });
    head.appendChild(charEl);

    const headMeta = el('div', { className: 'kanji-card-meta' });
    const radicalRow = createKanjiReadingRow(window._kanjiLabels?.radical || 'Radical', kanji.radical);
    if (radicalRow) {
        headMeta.appendChild(radicalRow);
    }
    if (typeof kanji.strokes === 'number' && kanji.strokes > 0) {
        const strokesRow = createKanjiReadingRow(
            window._kanjiLabels?.strokes || 'Strokes', String(kanji.strokes));
        if (strokesRow) {
            headMeta.appendChild(strokesRow);
        }
    }
    if (headMeta.children.length > 0) {
        head.appendChild(headMeta);
    }
    card.appendChild(head);

    const onyomiRow = createKanjiReadingRow(window._kanjiLabels?.onyomi || 'On', kanji.onyomi);
    if (onyomiRow) {
        card.appendChild(onyomiRow);
    }
    const kunyomiRow = createKanjiReadingRow(window._kanjiLabels?.kunyomi || 'Kun', kanji.kunyomi);
    if (kunyomiRow) {
        card.appendChild(kunyomiRow);
    }

    const meanings = Array.isArray(kanji.meanings)
        ? kanji.meanings.filter((m) => typeof m === 'string' && m.length > 0)
        : [];
    if (meanings.length > 0) {
        const meaningEl = el('div', { className: 'kanji-card-meanings' });
        meaningEl.textContent = meanings.join(', ');
        card.appendChild(meaningEl);
    }

    if (kanji.dictName) {
        card.appendChild(el('div', { className: 'kanji-card-dict', textContent: kanji.dictName }));
    }

    return card;
}

// Builds the container holding every kanji card for the current lookup, or null
// when there are no kanji results. Each character in a multi-character (rare,
// but the array supports it) result gets its own card.
function buildKanjiCards() {
    const kanji = window.kanjiResults;
    if (!Array.isArray(kanji) || kanji.length === 0) {
        return null;
    }
    const section = el('div', { className: 'kanji-card-section' });
    let appended = 0;
    for (const entry of kanji) {
        const card = createKanjiCard(entry);
        if (card) {
            section.appendChild(card);
            appended++;
        }
    }
    return appended > 0 ? section : null;
}

window._renderGeneration = 0;

// 浏览器扩展性能诊断钩子。app 内 WebView 没有注入该函数时是零成本 no-op；Side Panel/
// content script 注入后，把首卡同步 DOM 与尾批完成耗时关联到同一个 lookup id。
function _emitPopupRenderPerf(phase, startedAt, entryCount, extra) {
    const callback = window.__fushiOnPopupPerf;
    if (typeof callback !== 'function') return;
    const payload = {
        phase,
        renderMs: Number((performance.now() - startedAt).toFixed(1)),
        entryCount: Number(entryCount) || 0,
        ...(extra || {}),
    };
    // callback 会发 chrome.runtime IPC；推到下一个宏任务，绝不把日志调用塞进
    // 首词条 DOM 构建/宿主 reveal 的同步关键路径。callback 在此处捕获，换词后
    // 仍归属于发起本轮 render 的 lookup context。
    setTimeout(() => {
        try { callback(payload); } catch (_) { /* 诊断绝不阻断词典渲染 */ }
    }, 0);
}

// TODO-058 fail-safe: always notify Dart that rendering finished, even when
// buildEntryElement / postProcessRuby throws. Without this a render exception
// would swallow the `popupRendered` signal forever, leaving a cold nested popup
// permanently hidden (pending reveal). Fired exactly once per render.
function _reportPopupHeight() {
    // 把当前内容高度报给宿主（宿主据此给弹窗窗口/浮层定尺、并驱动 reveal 门）。
    // 抽成独立函数是因为 masonry 铺完后容器高度会变（紧密堆比行对齐 grid 更矮），必须
    // 复报一次，否则宿主拿的是 masonry 前的旧高度、弹窗底部会留空白。只报高度、不触发
    // relayout，避免 _firePopupRendered→relayout→report→relayout 的死循环。
    try {
        window.flutter_inappwebview.callHandler('popupRendered',
            __fushiScrollHeight(),
            window.__fushiRenderToken || 0);
    } catch (e) {
        console.error('[popup] popupRendered callHandler failed', e);
    }
}

// 性能（查词时延）：多词条渲染现在**双发**同一 token 的 popupRendered——首词条
// 同步渲染完（build + 局部 postProcessRuby + applyCustomCSS）立即发第一次，宿主
// 据此撤盖板/翻可见（首屏可见性只依赖首词条，Dart 侧全部消费方幂等）；尾批词条
// 在宏任务里补建完成后发第二次（Windows global-lookup host 依赖第二发把窗口量到
// 全高）。[stillRendering]=true 表示尾批仍在途：置 _renderInProgress 让
// updatePopupIncremental 在此窗口内回退全量 renderPopup（临时 counts/domIndex
// 不可做增量 diff）。
function _firePopupRendered(stillRendering) {
    window._renderInProgress = !!stillRendering;
    const generation = window._renderGeneration;
    const finish = () => {
        // A newer lookup replaced this DOM while the cold font was decoding.
        // Its own render signal owns the reveal gate; never let this stale
        // callback reveal the new card early.
        if (generation !== window._renderGeneration) return;
        _reportPopupHeight();
        // 词典方框排列：渲染完成后（含首条 + 其余条两次调用）铺 masonry。masonry 在下一帧
        // RAF 里跑，跑完会自行 _reportPopupHeight() 复报修正后的高度。
        window.fushiRelayoutDictionaries();
    };

    // Custom file fonts are injected immediately before renderPopup(), but
    // FontFace decoding is asynchronous. popupRendered is the host's reveal
    // gate, so reporting before `document.fonts.ready` exposes one fallback-font
    // frame in every cold/nested popup. Force style/layout discovery, then keep
    // the already-hidden layer parked until the configured font is ready. Warm
    // slots hit an already-resolved promise and only pay one microtask.
    if (window.__fushiDictionaryFontsConfigured &&
        document.fonts && document.fonts.ready) {
        try { void document.body.offsetWidth; } catch (_) { /* no-op */ }
        Promise.resolve(document.fonts.ready).then(finish, finish);
    } else {
        finish();
    }
}

// ===== N 列 masonry 词典方框排列（照抄 Niratan Features/Popup/popup.js layoutMasonry，
//        一般化到 Hibiki 的 --dict-columns N 列）=====
// develop 原本用 CSS grid `.glossary-section > .category-body`(repeat(--dict-columns,1fr))
// 行对齐排列：同一行的词典卡片被该行最高者顶到同一水平线，矮卡片下方留空隙（Niratan 的
// 紧密堆则无此空隙）。这里在 grid 之上叠一层运行时 masonry——cols>1 且多卡时用 inline-style
// 把每张卡片绝对定位进「当前最矮的那一列」（最短列打包，无空隙，Pinterest 式），cols<=1 或
// 单卡时清掉 inline 回落到 CSS grid/block。CSS 规则原样保留作「无 JS 兜底」，故所有现有 grid
// 守卫测试不受影响。高度变化（<details> 展开/收起、图片异步加载、ruby、字体替换）由挂在每张
// 卡片上的 ResizeObserver 捕捉重排（不依赖 toggle 事件跨 shadow 边界）；宽度变化走 resize。
const HAS_NATIVE_MASONRY = (() => {
    try { return CSS.supports('display', 'grid-lanes'); } catch (e) { return false; }
})();
let masonryRaf = null;
let masonryObserver = null;

// masonry 是叠在 CSS grid 之上的渐进增强：需要 ResizeObserver（捕捉卡片高度变化重排）
// 与 requestAnimationFrame（合帧）。环境不具备（老 WebView / 非浏览器测试壳）时整体不做
// masonry，静默回落到 CSS grid 行对齐布局——不崩、不报错，只是没有紧密堆。
function masonrySupported() {
    return typeof requestAnimationFrame === 'function'
        && typeof ResizeObserver === 'function';
}

function dictColumns() {
    // --dict-columns 由宿主注入到 documentElement（app_model / dictionary_popup_webview /
    // popup_settings_injection 三面同源），即使弹窗挂在 shadow root 也从此处读。
    // 与 CSS grid 的 --dict-columns-effective 同源：masonry 用「视口收敛后的有效列数」
    //（min(用户设置, 每列 ≥DICT_COLUMN_MIN_WIDTH px 装得下的列数)）。历史 bug：masonry
    // 直接读 --dict-columns 原始值，无视窄面板收敛 → 用户「最多列数（自动填充）」的自动
    // 调整对词典方框布局不生效（窄面板照塞满列、卡片互相挤压）。effectiveDictColumns() 是
    // grid 与 masonry 的单一真值来源，二者不再分叉。
    return effectiveDictColumns();
}

function masonryGap() {
    // 与 popup.css `.glossary-section > .category-body { column-gap: 6px }` 同源。
    return 6;
}

function masonryBodies() {
    const root = __fushiContainer();
    if (!root || typeof root.querySelectorAll !== 'function') return [];
    // 只抓词典义项容器；frequency-section / pitch-section 也用 .category-body，不能误抓。
    return [...root.querySelectorAll('.glossary-section > .category-body')];
}

function resetMasonryBody(body) {
    body.style.position = '';
    body.style.display = '';
    body.style.height = '';
    delete body.dataset.masonryCols; // 清粘着列记录：回落单列/CSS 后再进 masonry 会重新最短列打包
    [...body.children].forEach(item => {
        item.style.position = '';
        item.style.left = '';
        item.style.top = '';
        item.style.width = '';
        item.style.marginTop = '';
        item.style.transform = '';
        delete item.dataset.masonryCol;
    });
}

function layoutMasonry() {
    if (HAS_NATIVE_MASONRY) return; // 浏览器原生 masonry 时交给 CSS（未来分支）
    const configured = dictColumns();
    const gap = masonryGap();
    masonryBodies().forEach(body => {
        const items = [...body.children].filter(c => c.classList.contains('glossary-group'));
        // 经典单列（设置=1）或该词条无词典卡：不做 masonry，清 inline 回落 CSS
        //（block 纵向堆叠 + CSS margin-top / 空容器）。
        if (configured <= 1 || items.length === 0) {
            resetMasonryBody(body);
            return;
        }
        // 有效列数封顶到该词条实际的词典卡片数：词典数 < 设置列数时（如上限 2 但只有 1 本），
        // 现有卡片平分整行宽度——单卡走 cols=1 满宽、2 卡 3 列走 cols=2 各半，不再让右侧空出
        // 没有卡片的列。cols 每 body 独立计算（不同词条词典数不同）；masonry 仍绝对定位、按
        // 最短列打包。cols=1 时 columnWidth=整宽、单卡 translate(0,0) 即满宽（取代旧「单卡回落
        // 半宽 grid」——grid 用全局 --dict-columns 无法感知本词条只有 1 本词典）。
        const cols = Math.min(configured, items.length);
        body.style.position = 'relative';
        body.style.display = 'block';
        const columnWidth = (body.clientWidth - (cols - 1) * gap) / cols;

        // 粘着列分配（修用户「开关方框时按上下高度左右重排，实际只应上下动」）：只要列数没变、
        // 且每张卡片都已记录合法列号，就复用既有列分配——展开/收起改高度时只在各自列内重算纵向
        // 位置，卡片只上下动、绝不换列左右跳。仅列数变（窗口宽/设置）或有新卡片（增量加载，某卡
        // 无记录）时，才用「最短列」从头打包并记录列号。
        const prevCols = Number.parseInt(body.dataset.masonryCols, 10);
        const canReuse = prevCols === cols &&
            items.every(item => {
                const c = Number.parseInt(item.dataset.masonryCol, 10);
                return Number.isFinite(c) && c >= 0 && c < cols;
            });

        const heights = new Array(cols).fill(0);
        items.forEach(item => {
            let c;
            if (canReuse) {
                c = Number.parseInt(item.dataset.masonryCol, 10); // 复用粘着列，不重新分列
            } else {
                c = 0;
                for (let i = 1; i < cols; i++) {
                    if (heights[i] < heights[c]) c = i; // 首次：最短列打包
                }
                item.dataset.masonryCol = String(c); // 记住列号，之后开关都粘着此列
            }
            item.style.position = 'absolute';
            item.style.left = '0';
            item.style.top = '0';
            item.style.marginTop = '0';
            item.style.width = `${columnWidth}px`;
            item.style.transform = `translate(${c * (columnWidth + gap)}px, ${heights[c]}px)`;
            // 读 offsetHeight 前已设 width，浏览器按目标列宽回流后再量高。
            heights[c] += item.offsetHeight + gap;
        });
        body.dataset.masonryCols = String(cols);
        body.style.height = `${Math.max(...heights) - gap}px`;
    });
}

function observeMasonryTargets() {
    if (HAS_NATIVE_MASONRY || !masonrySupported()) return;
    if (!masonryObserver) {
        masonryObserver = new ResizeObserver(scheduleMasonry);
    }
    // 只观察卡片本身（内容高度变化），不观察容器（避免 body.style.height 自触发死循环）；
    // 容器宽度变化由 window resize 覆盖。observe 同一元素幂等，增量新增卡片可安全重观察。
    masonryBodies().forEach(body => {
        [...body.children].forEach(item => {
            if (item.classList.contains('glossary-group')) masonryObserver.observe(item);
        });
    });
}

function scheduleMasonry() {
    if (HAS_NATIVE_MASONRY || !masonrySupported() || masonryRaf) return;
    masonryRaf = requestAnimationFrame(() => {
        masonryRaf = null;
        layoutMasonry();
        // 铺完复报高度（容器高度已由 masonry 改写），让宿主给弹窗重新定尺。
        _reportPopupHeight();
    });
}

// 宿主改列数 / 外部触发时可调；渲染钩子已在 _firePopupRendered / updatePopupIncremental 里调。
window.fushiRelayoutDictionaries = () => {
    observeMasonryTargets();
    scheduleMasonry();
};

// 顶层注册用 typeof 守卫：真实浏览器一定有 addEventListener；非浏览器测试壳缺此 API 时
// 跳过注册即可（masonry 本就会被 masonrySupported 门控掉）。
if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('resize', scheduleMasonry);
}
// <details> 展开/收起改高度：capture 阶段兜底（ResizeObserver 已是主路，故 shadow 边界不影响正确性）。
if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
    document.addEventListener('toggle', scheduleMasonry, true);
}

// TODO-1030 M0 — the app-external global-lookup capture (Windows UIA) hands the
// popup the sentence the selected word sits in via window.__globalLookupSentence
// (set per-render by buildFrameSettingsJs; empty for in-app popups and for
// nested child cards). Build a small context banner shown above the entries so
// the user sees the word IN CONTEXT (Yomitan {sentence}-style). Returns null
// when there is no captured sentence, so the in-app / no-context paths render
// exactly as before.
function buildGlobalLookupSentenceBanner() {
    const sentence = window.__globalLookupSentence;
    if (typeof sentence !== 'string' || sentence.length === 0) {
        return null;
    }
    const banner = el('div', { className: 'global-lookup-sentence' });
    // spec 2026-07-10 — per-character spans: clicking any character looks up
    // the "char to sentence end" suffix (the same semantics as the in-app
    // ClipboardLookupTextPanel; the engine prefix/deinflection-matches from
    // the clicked char). textContent per span (never innerHTML) — the sentence
    // is untrusted foreground-app/clipboard text, never interpreted as markup.
    //
    // 真机第 4 轮 — 面板 root（window.__globalLookupPanelRoot，settingsJs 注入）
    // 的句子条是「选词区」：点字走 panelSentenceLookup 桥，Dart 换根结果=底部
    // 原地更新，不再嵌套压卡；引擎匹配到的词以 __globalLookupSentenceHit
    // {start,length}（码点下标）整词高亮——分词由词典引擎给出，视觉上是连续
    // 正常文本（面板无逐字 hover 框，见 popup.css 的 :not() 作用域）。
    // 瞬态覆盖窗保持原语义：点字=onLinkClick 嵌套子卡。
    const chars = Array.from(sentence);
    const isPanelRoot = window.__globalLookupPanelRoot === true;
    const hit = isPanelRoot ? window.__globalLookupSentenceHit : null;
    const hitStart = hit && typeof hit.start === 'number' ? hit.start : -1;
    const hitEnd = hitStart >= 0 && hit && typeof hit.length === 'number'
        ? hitStart + hit.length
        : -1;
    if (isPanelRoot) {
        banner.classList.add('global-lookup-sentence-panel');
    }
    chars.forEach((ch, i) => {
        const span = el('span', {
            className: 'global-lookup-sentence-char'
                + (i >= hitStart && i < hitEnd
                    ? ' global-lookup-sentence-hit'
                    : ''),
            textContent: ch,
        });
        span.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const suffix = chars.slice(i).join('');
            if (isPanelRoot) {
                // i = 码点下标（chars 是 Array.from 的码点数组），Dart 侧原样
                // 作为高亮起点回注——两端同一单位，无 UTF-16 代理对错位。
                window.flutter_inappwebview.callHandler(
                    'panelSentenceLookup', suffix, i);
                return;
            }
            const rect = span.getBoundingClientRect();
            window.flutter_inappwebview.callHandler(
                'onLinkClick', suffix, {
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height
            });
        });
        banner.appendChild(span);
    });
    return banner;
}

// 真机第 5 轮 — 面板 root：点释义/见出语/汉字标签弹**外部**瞬态窗时，被点元素
// 加 .global-lookup-ext-hit 高亮（外部窗不在本文档里，没有嵌套卡的父卡反馈；
// 高亮在下次点击时被替换、重渲时随 DOM 重建自然清除）。瞬态窗/in-app 弹窗
// 不启用（__globalLookupPanelRoot 仅面板 root 注入，那边嵌套卡自有视觉反馈）。
function markGlobalLookupExtHit(target) {
    if (window.__globalLookupPanelRoot !== true || !target || !target.classList) {
        return;
    }
    try {
        document.querySelectorAll('.global-lookup-ext-hit').forEach((n) => {
            n.classList.remove('global-lookup-ext-hit');
        });
    } catch (e) {
        // querySelectorAll 失败也不阻断查词本身。
    }
    target.classList.add('global-lookup-ext-hit');
}

// 真机第 5 轮 — 视口感知的词典列数收敛：TODO-1357 只按平台定默认（桌面 2 列
// Niratan 双栏、移动 1 列「不硬塞多列避免窄屏挤爆」），但面板窗可被拖到很窄，
// 固定多列会让底下的词典玻璃卡互相挤压重叠。这里把同一「窄了就收」判断按真实
// 视口宽度动态化：每列至少 DICT_COLUMN_MIN_WIDTH px（可读下限），有效列数 =
// min(用户设置, 装得下的列数)，写 --dict-columns-effective 供 grid 消费；
// resize 只改 CSS 变量（grid 自动 reflow，零重渲）。in-app 弹窗同规则受益。
const DICT_COLUMN_MIN_WIDTH = 170;
// 视口感知的有效列数（单一真值来源）：min(用户设置 --dict-columns, 每列 ≥DICT_COLUMN_MIN_WIDTH
// px 装得下的列数)。CSS grid 经 --dict-columns-effective 消费、masonry 经 dictColumns() 消费，
// 两者都走此函数——绝不再分叉（历史上 masonry 漏了视口收敛，自动调整对方框布局不生效）。
function effectiveDictColumns() {
    let configured = 1;
    try {
        configured = parseInt(
            getComputedStyle(document.documentElement)
                .getPropertyValue('--dict-columns'), 10) || 1;
    } catch (e) {
        configured = 1;
    }
    if (!(configured > 0)) configured = 1;
    const width = window.innerWidth || 0;
    const fit = width > 0
        ? Math.max(1, Math.floor(width / DICT_COLUMN_MIN_WIDTH))
        : configured;
    return Math.min(configured, fit);
}
function updateEffectiveDictColumns() {
    const doc = document.documentElement;
    if (!doc || !doc.style || typeof doc.style.setProperty !== 'function') {
        return;
    }
    doc.style.setProperty(
        '--dict-columns-effective', String(effectiveDictColumns()));
}
if (typeof window.addEventListener === 'function'
    && !window.__fushiDictColsResizeHooked) {
    window.__fushiDictColsResizeHooked = true;
    window.addEventListener('resize', updateEffectiveDictColumns);
}

// Inserts the sentence-context banner (if any) as the FIRST child of the popup
// entries container, above the kanji card / entries / no-results placeholder.
// No-op when there is no captured sentence (in-app popups, nested cards).
function prependSentenceBanner(container) {
    const banner = buildGlobalLookupSentenceBanner();
    if (!banner || !container) return;
    if (container.firstChild) {
        container.insertBefore(banner, container.firstChild);
    } else {
        container.appendChild(banner);
    }
}

window.renderPopup = function() {
    const t0 = performance.now();
    // 真机第 5 轮 — settingsJs 可能刚更新了 --dict-columns；渲染前按当前视口
    // 重算有效列数（resize 监听兜住渲染后的窗口拖拽）。
    updateEffectiveDictColumns();
    const container = __fushiContainer();
    if (!container) { _firePopupRendered(); return; }

    const entries = window.lookupEntries;
    // TODO-094 S5: a kanji-dictionary card may be present even with NO term
    // entries (a single kanji that is only in a kanji dictionary, not a term
    // headword). Build it first so it sits above the terms, and so a kanji-only
    // result still renders instead of falling through to "No results".
    let kanjiSection = null;
    try {
        kanjiSection = buildKanjiCards();
    } catch (e) {
        console.error('[popup] renderPopup kanji card render failed', e);
        window.__fushiReportJsError('renderPopup.kanjiCard', (e && e.message) || String(e), e && e.stack);
        kanjiSection = null;
    }

    if ((!entries || !entries.length) && !kanjiSection) {
        container.innerHTML = '<div class="no-results">'
            + '<div class="no-results-icon">&#x1F50D;</div>'
            + '<div>' + (window._noResultsMessage || 'No results found.') + '</div>'
            + '</div>';
        prependSentenceBanner(container);
        window._renderedGlossaryCounts = [];
        _firePopupRendered();
        _emitPopupRenderPerf('complete', t0, 0, { noResults: true });
        return;
    }

    const gen = ++window._renderGeneration;

    // TODO-833: entries that the hidden-dictionary filter leaves with no visible
    // glossary are skipped (buildEntryElement returns null), so the rendered DOM
    // `.entry` nodes are no longer 1:1 with `entries`. _entryDomIndex maps each
    // entries index to its `.entry` DOM index (or -1 when skipped). _renderedGlossaryCounts
    // stays length=entries.length (the per-entry glossary count we last rendered).
    // updatePopupIncremental relies on this map to locate an entry's node — a bare
    // existingEntries[idx] would otherwise pour entry A's definitions into entry B's
    // card once any earlier entry was skipped.
    let renderedDomCount = 0;
    const entryDomIndex = new Array(entries.length).fill(-1);

    // Kanji-only result (no term entries): render just the kanji card(s).
    if (!entries || !entries.length) {
        container.innerHTML = '';
        prependSentenceBanner(container);
        if (kanjiSection) {
            container.appendChild(kanjiSection);
        }
        applyCustomCSS();
        window._renderedGlossaryCounts = [];
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=0 kanji=1');
        _firePopupRendered();
        _emitPopupRenderPerf('complete', t0, 0, { kanjiOnly: true });
        return;
    }

    let firstEntry = null;
    try {
        container.innerHTML = '';
        prependSentenceBanner(container);

        if (kanjiSection) {
            container.appendChild(kanjiSection);
        }
        // Only the first visible dictionary block belongs to the synchronous
        // reveal path. One entry can still contain many expensive blocks.
        firstEntry = buildEntryElement(entries[0], 0, 1);
        if (firstEntry) {
            container.appendChild(firstEntry);
            postProcessRuby(firstEntry);
            entryDomIndex[0] = renderedDomCount++;
        }
        applyCustomCSS();
    } catch (e) {
        // 渲染抛错也发信号让 Dart 翻可见（哪怕内容不全），杜绝永久挂起。
        console.error('[popup] renderPopup first-entry render failed', e);
        window.__fushiReportJsError('renderPopup.firstEntry', (e && e.message) || String(e), e && e.stack);
        try { firstEntry?.remove(); } catch (_) { /* partially appended first card */ }
        window._renderedGlossaryCounts = [];
        window._entryDomIndex = [];
        _firePopupRendered();
        _emitPopupRenderPerf('error', t0, entries.length, { where: 'first-entry' });
        return;
    }

    const firstEntryHasDeferredBlocks =
        !!firstEntry?.__fushiDeferredGlossaryState;
    const hasDeferredWork = firstEntryHasDeferredBlocks || entries.length > 1;
    if (!hasDeferredWork) {
        window._renderedGlossaryCounts = entries.map(
            e => (e && Array.isArray(e.glossaries)) ? e.glossaries.length : 0);
        window._entryDomIndex = entryDomIndex;
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) + 'ms entries=1');
        _firePopupRendered();
        _emitPopupRenderPerf('complete', t0, 1, { firstVisible: true });
        return;
    }

    // 首词条的 header + 第一个可见词典块已经就绪，先让宿主撤盖板；剩余词典块
    // （包括 entries.length === 1 的情况）和后续词条都留给下面的宏任务队列。
    // counts/domIndex 在途值只作占位，最终值由 finishRemainingEntries 写齐。
    window._renderedGlossaryCounts = [entries[0].glossaries.length];
    window._entryDomIndex = [entryDomIndex[0]];
    console.log('[popup-perf] renderPopup first-entry: ' + (performance.now() - t0).toFixed(1) + 'ms entries=' + entries.length);
    _firePopupRendered(true);
    _emitPopupRenderPerf('first-entry-dom', t0, entries.length);

    // 每个宏任务最多创建一个词典块。新词条的 header 与它的首块同任务建立；
    // 同词条余块逐任务追加。generation 变化立即取消旧队列。
    let nextEntryIndex = 1;
    let activeEntryElement = firstEntryHasDeferredBlocks ? firstEntry : null;
    let activeEntryIndex = activeEntryElement ? 0 : -1;
    let activeEntrySeparator = null;
    const finishRemainingEntries = (
        completedCount = entries.length,
        terminalPhase = 'complete',
        terminalExtra = {},
    ) => {
        const completed = entries.slice(0, completedCount);
        window._renderedGlossaryCounts = completed.map(
            e => (e && Array.isArray(e.glossaries)) ? e.glossaries.length : 0);
        window._entryDomIndex = entryDomIndex.slice(0, completedCount);
        console.log('[popup-perf] renderPopup: ' + (performance.now() - t0).toFixed(1) +
            'ms entries=' + completedCount + '/' + entries.length);
        _firePopupRendered();
        _emitPopupRenderPerf(terminalPhase, t0, completedCount, {
            expectedEntryCount: entries.length,
            ...terminalExtra,
        });
    };
    const activeEntryHasDeferredBlocks = () =>
        !!activeEntryElement?.__fushiDeferredGlossaryState;
    const releaseCompletedActiveEntry = () => {
        if (!activeEntryElement || activeEntryHasDeferredBlocks()) return;
        activeEntryElement = null;
        activeEntryIndex = -1;
        activeEntrySeparator = null;
    };
    const rollbackActiveEntry = () => {
        if (!activeEntryElement || activeEntryIndex < 0) return;
        try { activeEntryElement.remove(); } catch (_) {}
        try { activeEntrySeparator?.remove(); } catch (_) {}
        if (entryDomIndex[activeEntryIndex] >= 0) {
            entryDomIndex[activeEntryIndex] = -1;
            renderedDomCount = Math.max(0, renderedDomCount - 1);
        }
        activeEntryElement = null;
        activeEntryIndex = -1;
        activeEntrySeparator = null;
    };
    const renderNextDictionaryBlock = () => {
        if (gen !== window._renderGeneration) {
            const completedCount = activeEntryElement
                ? Math.max(0, activeEntryIndex)
                : nextEntryIndex;
            _emitPopupRenderPerf('cancelled', t0, completedCount, {
                expectedEntryCount: entries.length,
                reason: 'superseded',
            });
            return;
        }
        let taskEntryIndex = activeEntryIndex >= 0
            ? activeEntryIndex
            : nextEntryIndex;
        try {
            if (activeEntryElement) {
                appendNextDeferredGlossaryBlock(activeEntryElement);
            } else if (nextEntryIndex < entries.length) {
                const idx = nextEntryIndex++;
                taskEntryIndex = idx;
                const entry = entries[idx];
                const element = entry ? buildEntryElement(entry, idx, 1) : null;
                if (element) {
                    const fragment = document.createDocumentFragment();
                    let separator = null;
                    // Only add a separator when a card precedes this one; hidden
                    // entries never create either a card or a separator.
                    if (renderedDomCount > 0 || kanjiSection) {
                        separator = document.createElement('hr');
                        fragment.appendChild(separator);
                    }
                    fragment.appendChild(element);
                    entryDomIndex[idx] = renderedDomCount++;
                    container.appendChild(fragment);
                    activeEntryElement = element;
                    activeEntryIndex = idx;
                    activeEntrySeparator = separator;
                    postProcessRuby(element);
                }
            }
        } catch (e) {
            console.error('[popup] renderPopup rest-entries render failed', e);
            window.__fushiReportJsError('renderPopup.restEntries', (e && e.message) || String(e), e && e.stack);
            // Partial cards cannot satisfy the count/map contract. Remove the
            // current card and publish only the trustworthy completed prefix.
            rollbackActiveEntry();
            finishRemainingEntries(
                Math.max(0, taskEntryIndex),
                'error',
                { where: 'dictionary-block' },
            );
            return;
        }
        releaseCompletedActiveEntry();
        if (activeEntryElement || nextEntryIndex < entries.length) {
            setTimeout(renderNextDictionaryBlock, 0);
            return;
        }
        // Second signal with the same token measures the final all-block height.
        finishRemainingEntries();
    };
    setTimeout(renderNextDictionaryBlock, 0);
};

window.updatePopupIncremental = function() {
    const container = __fushiContainer();
    if (!container || !window.lookupEntries?.length) return;

    // 首发 popupRendered 后、尾批完成前的窗口：counts/domIndex 是仅含首词条的
    // 临时值，增量 diff 不可靠（else 分支会把尾批在建的词条当新增追加成重复
    // 卡片）。全量重建：renderPopup 换代自动取消 pending 尾批。
    if (window._renderInProgress) {
        window.renderPopup();
        return;
    }

    const entries = window.lookupEntries;
    const prevCounts = window._renderedGlossaryCounts || [];
    // TODO-833: existing `.entry` DOM nodes are NOT 1:1 with `entries` — skipped
    // (empty after hidden-dictionary filter) entries have no node. _entryDomIndex
    // maps each entries index to its `.entry` DOM index (-1 = no node). Index the
    // live NodeList through this map, never by raw entries idx, or A's definitions
    // land in B's card. Fall back to a full renderPopup() if the map is absent
    // (e.g. a render path that predates it) or its length disagrees with prevCounts.
    const domIndex = window._entryDomIndex;
    const existingEntries = container.querySelectorAll(':scope > .entry');
    const mapUsable = Array.isArray(domIndex) && domIndex.length === prevCounts.length;

    for (let idx = 0; idx < entries.length; idx++) {
        const entry = entries[idx];
        const newCount = entry.glossaries.length;

        if (idx < prevCounts.length) {
            if (newCount === prevCounts[idx]) {
                continue;
            }
            // TODO-833: the entry's visible-glossary status may flip when the load
            // attaches a glossary from a non-hidden dictionary to a previously empty
            // (skipped) entry, or removes the last visible one. The incremental
            // in-place update can only patch an existing card; a skipped→visible (or
            // the reverse) transition changes the card count and ordering, so rebuild
            // the whole popup — correct over clever, and rare.
            const nowRenderable = entryGlossaryWrapperOrNull(entry) !== null;
            const domIdx = mapUsable ? domIndex[idx] : idx;
            const hadCard = mapUsable ? domIdx >= 0 : true;
            if (!mapUsable || nowRenderable !== hadCard) {
                window.renderPopup();
                return;
            }
            if (!nowRenderable) {
                continue;
            }
            const entryDiv = existingEntries[domIdx];
            if (!entryDiv) {
                window.renderPopup();
                return;
            }
            const body = entryDiv.querySelector('.glossary-section .category-body');
            if (body) {
                const existingDicts = new Set();
                body.querySelectorAll(':scope > .glossary-group > [data-dictionary]').forEach(
                    node => existingDicts.add(node.getAttribute('data-dictionary')));
                const grouped = {};
                const hiddenDictionaryNames = window.hiddenDictionaryNames || [];
                entry.glossaries.forEach(g => {
                    if (hiddenDictionaryNames.includes(g.dictionary)) return;
                    if (isRedirectGlossary(g)) return;
                    if (!grouped[g.dictionary]) grouped[g.dictionary] = [];
                    grouped[g.dictionary].push({
                        content: g.content,
                        definitionTags: g.definitionTags,
                        termTags: g.termTags,
                    });
                });
                // TODO-845: the auto-expand threshold keys off each block's global
                // index within the entry's glossary body. New blocks land *after*
                // the already-rendered ones, so seed appendIndex with the live count
                // of visible `.glossary-group` children and bump it per appended
                // block — same `dictIdx < autoExpandN` rule as the first-paint loop,
                // never a bare `false` (which would forbid any incremental expand).
                // totalDicts must be the entry's POST-append block count: the row-based
                // threshold caps columns at the real card count, so counting only the
                // already-rendered blocks would under-report columns and collapse cards
                // that the finished layout does have room to expand.
                let appendIndex =
                    body.querySelectorAll(':scope > .glossary-group').length;
                const appendDictNames = Object.keys(grouped)
                    .filter(dictName => !existingDicts.has(dictName));
                const totalDicts = appendIndex + appendDictNames.length;
                for (const dictName of appendDictNames) {
                    const section = createGlossarySection(dictName, grouped[dictName], appendIndex, idx, totalDicts);
                    appendIndex++;
                    body.appendChild(section);
                    postProcessRuby(section);
                }
            }
        } else {
            // TODO-833: newly appended entry — skip it entirely (no card, no hr) when
            // the hidden-dictionary filter leaves it with no visible glossary.
            const newElement = buildEntryElement(entry, idx);
            if (!newElement) {
                continue;
            }
            if (container.children.length > 0) {
                container.appendChild(document.createElement('hr'));
            }
            container.appendChild(newElement);
            postProcessRuby(newElement);
        }
    }

    // TODO-833: rebuild the dom-index map so a subsequent incremental call still
    // locates nodes correctly (tail entries may have been skipped above).
    const rebuiltDomIndex = new Array(entries.length).fill(-1);
    const finalEntries = container.querySelectorAll(':scope > .entry');
    let domCursor = 0;
    for (let idx = 0; idx < entries.length; idx++) {
        if (entryGlossaryWrapperOrNull(entries[idx]) !== null) {
            rebuiltDomIndex[idx] = domCursor < finalEntries.length ? domCursor : -1;
            domCursor++;
        }
    }
    window._renderedGlossaryCounts = entries.map(e => e.glossaries.length);
    window._entryDomIndex = rebuiltDomIndex;
    applyCustomCSS();

    // 增量追加了新的词典方框，重排 masonry 并观察新卡片。
    window.fushiRelayoutDictionaries();

    window.flutter_inappwebview.callHandler('popupRendered',
        __fushiScrollHeight(),
        window.__fushiRenderToken || 0);
};


// BUG-260: finer mouse-wheel scroll granularity for the lookup popup.
//
// The popup has no wheel listener of its own, so wheel events fell through to
// the WebView's native page scroll, which steps a fixed, coarse number of CSS
// px per notch. Worse, dictionary_popup_webview injects
// `document.documentElement.style.zoom` (popupContentZoom, follows UI scale +
// dictionary font size): a scroll of D *layout* px moves D*zoom px on screen,
// so any zoom>1 amplifies the already-coarse native step and each notch jumps
// even further. Result: scrolling feels chunky, unlike a normal web page.
//
// Take over 'wheel' (passive:false so preventDefault works), normalize the
// delta across deltaMode (LINE/PAGE report in lines/pages, not px), apply a
// smaller fraction so a single notch travels a browser-like distance, cap one
// unusually large device delta in visual pixels, then divide the layout-px
// scroll amount by the current zoom so the *visual* step is the same regardless
// of zoom (a V-px visual move needs V/zoom layout px). behavior:auto keeps it
// crisp (no smooth-scroll lag stacking up across rapid notches).
//
// Inner vertically-scrollable containers (the description overlay, any glossary
// element with its own y-overflow) keep native scroll until they hit a boundary,
// so nested scroll regions are not stolen — only the main document scroll, which
// is the coarse one, is refined.
const POPUP_WHEEL_PIXEL_FACTOR = 0.48;      // fraction of the raw px delta (coarse mouse notch)
const POPUP_WHEEL_MAX_VISUAL_STEP = 120;    // px cap after scaling, before zoom
const POPUP_WHEEL_LINE_HEIGHT = 16;         // px per line for deltaMode === LINE
// BUG-870: a precision touchpad / high-resolution wheel reports deltaMode=PIXEL
// with small per-frame deltas; the coarse-mouse downscale (tuned for a notch,
// deltaY≈100-120) makes those devices too slow — the "very hard to scroll"
// symptom. A pixel-mode frame whose |deltaY| is below this many px is treated as a
// fine device and scrolls ~1:1 (factor 1.0, still zoom-corrected); at/above it is a
// coarse mouse notch and keeps the 0.48 taming. A mouse notch on WebView2/Chromium
// is ≈100px, well above this; slow touchpad frames are well below.
const POPUP_WHEEL_MOUSE_NOTCH_PX = 60;
const POPUP_WHEEL_TRACKPAD_FACTOR = 1.0;    // fine devices: natural 1:1, no downscale
// TODO-1387: a wheel frame counts as "horizontal" (left to native) only when the
// horizontal delta leads the vertical delta by MORE than this many px. A touchpad
// two-finger *vertical* scroll carries horizontal jitter that momentarily exceeds
// deltaY; without this slack those frames were dropped and the scroll felt choppy.
const POPUP_WHEEL_HORIZONTAL_MARGIN = 6;
// TODO-1387: sub-pixel wheel remainder carried across events (see the wheel
// handler for the full rationale). Keyed to the surface being scrolled and reset
// after an idle gap so a stale carry can never trigger a delayed jump.
const POPUP_WHEEL_RESIDUAL_IDLE_MS = 200;
let _popupWheelResidual = 0;
let _popupWheelResidualSurface = null;
let _popupWheelResidualAt = 0;
// BUG-870: device-class latch for the current gesture. A small pixel-mode frame
// marks the stream as a fine device (touchpad / hi-res wheel); it stays latched
// until the idle/surface reset so one occasional large mid-fling frame is not
// mis-classified as a coarse mouse notch and momentarily over-tamed.
let _popupWheelFineDevice = false;
function popupCurrentZoom(scroller) {
    // BUG-688: read the zoom of the surface we are about to scroll. The in-app
    // popup zooms document.documentElement (popup_settings_injection.dart sets
    // documentElement.style.zoom); the extension floating popup zooms the shadow
    // host instead (content.js fushiRender sets host.style.zoom).
    const z = parseFloat(scroller
        ? (scroller.style && scroller.style.zoom)
        : document.documentElement.style.zoom);
    return (Number.isFinite(z) && z > 0) ? z : 1;
}
// Normalize a wheel delta (any axis) to CSS pixels, accounting for deltaMode.
function popupWheelDeltaToPixels(delta, deltaMode, pageExtent) {
    if (deltaMode === 1 /* DOM_DELTA_LINE */) {
        return delta * POPUP_WHEEL_LINE_HEIGHT;
    }
    if (deltaMode === 2 /* DOM_DELTA_PAGE */) {
        return delta * (pageExtent || POPUP_WHEEL_LINE_HEIGHT);
    }
    return delta; // DOM_DELTA_PIXEL
}
function popupClampWheelVisualStep(step) {
    if (!Number.isFinite(step) || step === 0) {
        return 0;
    }
    if (Math.abs(step) <= POPUP_WHEEL_MAX_VISUAL_STEP) {
        return step;
    }
    return Math.sign(step) * POPUP_WHEEL_MAX_VISUAL_STEP;
}
// Walk up from the event target looking for an ancestor that can still consume
// this vertical wheel natively (it scrolls on Y and is not yet at the boundary
// in the wheel's direction). If found we leave the event alone.
function popupAncestorAbsorbsVerticalWheel(target, deltaPx) {
    let node = (target && target.nodeType === Node.TEXT_NODE)
        ? target.parentElement : target;
    while (node && node !== document.body && node !== document.documentElement) {
        const style = window.getComputedStyle(node);
        const oy = style.overflowY;
        const canScrollY = (oy === 'auto' || oy === 'scroll') &&
            node.scrollHeight > node.clientHeight + 1;
        if (canScrollY) {
            const atTop = node.scrollTop <= 0;
            const atBottom =
                node.scrollTop + node.clientHeight >= node.scrollHeight - 1;
            if ((deltaPx < 0 && !atTop) || (deltaPx > 0 && !atBottom)) {
                return true;
            }
        }
        node = node.parentElement;
    }
    return false;
}
// 查词弹窗「上/下一个词条」的滚轮绑定（Yomitan 的 Next/Previous entry）。默认
// Alt+滚轮下 = 下一条、Alt+滚轮上 = 上一条；in-app 由 popup_settings_injection 注入
// window.__fushiEntryWheelBindings 覆盖成用户在「快捷键」设置里配的绑定（动作
// ShortcutAction.popupNextEntry / popupPrevEntry）。浏览器扩展没有那条注入通道，
// 就吃这里的默认值。
const FUSHI_ENTRY_WHEEL_DEFAULT_BINDINGS = {
    next: [{ dir: 'down', mods: ['alt'] }],
    prev: [{ dir: 'up', mods: ['alt'] }],
};
// 本次 wheel 事件命中哪个词条导航动作：'next' / 'prev' / null。
// 判据：deltaY 的符号给方向，当前按下的修饰键集合必须与某条绑定**全等**（故
// Alt+滚轮绝不会被 Ctrl+Alt+滚轮误触）。裸滚轮永远留给内容滚动，绝不劫持。
function popupEntryWheelAction(e) {
    const raw = window.__fushiEntryWheelBindings;
    const cfg = (raw && typeof raw === 'object')
        ? raw
        : FUSHI_ENTRY_WHEEL_DEFAULT_BINDINGS;
    const dir = e.deltaY > 0 ? 'down' : (e.deltaY < 0 ? 'up' : null);
    if (!dir) return null;
    const pressed = [];
    if (e.altKey) pressed.push('alt');
    if (e.ctrlKey) pressed.push('ctrl');
    if (e.shiftKey) pressed.push('shift');
    if (e.metaKey) pressed.push('meta');
    if (pressed.length === 0) return null;
    const matches = (list) => Array.isArray(list) && list.some((b) => b &&
        b.dir === dir && Array.isArray(b.mods) &&
        b.mods.length === pressed.length &&
        b.mods.every((m) => pressed.indexOf(m) >= 0));
    if (matches(cfg.next)) return 'next';
    if (matches(cfg.prev)) return 'prev';
    return null;
}
/* BUG-1078: this listener is non-passive by necessity (it preventDefault()s to
   re-implement popup scrolling), but a RESIDENT non-passive document wheel
   listener forces the browser off the compositor fast-scroll path on every page
   the extension content script touches. Two-part fix:
   - in-app popup WebView (no chrome.runtime): the document IS the popup — keep
     the resident document listener exactly as before (BUG-1026 wheel speed,
     BUG-1065 DPR parity and the Alt+wheel entry navigation all live here);
   - extension content script: never attach to document. The handler is exposed
     as window.__fushiPopupWheelListener and content.js mounts it on the popup
     shadow host ({passive:false}) when the popup is created, unmounting it in
     fushiRemoveContainer — host pages carry ZERO non-passive wheel listeners
     while no popup is open. */
const __fushiPopupWheelListener = (e) => {
    // BUG-1078 前置早退：先用最廉价的判定（一次 composedPath + indexOf）解析滚轮
    // 表面。扩展 content script 里滚轮不在弹窗 shadow 内 ⇒ 与弹窗无关，立即放行
    // 原生滚动——昂贵的祖先 getComputedStyle/scrollHeight 遍历和词条导航判定都不再
    // 为宿主页滚轮买单。（BUG-732 的放行守卫从 preventDefault 前挪到最前；挂载本身
    // 已随 BUG-1078 懒装到 shadow host，此守卫是纵深防御 + in-app/扩展共用判据。）
    const scroller = __fushiWheelScroller(e);
    const inExtensionContentScript =
        typeof chrome !== 'undefined' && !!(chrome.runtime && chrome.runtime.id);
    if (!scroller && inExtensionContentScript) return;
    // 词条导航先于一切滚动处理判定（否则 ctrlKey 早退会吃掉 Ctrl 系绑定）。只有
    // 焦点真的移动了（返回 'moved'）才吞掉事件：单词条 / 已到首尾时返回 'blocked'，
    // 这一帧继续走下面的正常滚动，弹窗不会「按住 Alt 就滚不动」。作用域判据由上面
    // 的前置早退保证：走到这里的滚轮要么在弹窗 shadow 内（扩展），要么整份文档就是
    // 弹窗（in-app）。
    const entryAction = popupEntryWheelAction(e);
    if (entryAction && typeof window.fushiFocusDictionaryEntryMove === 'function') {
        if (window.fushiFocusDictionaryEntryMove(entryAction) === 'moved') {
            e.preventDefault();
            return;
        }
    }
    // Ignore zoom gestures (ctrl+wheel / pinch) and predominantly-horizontal wheels.
    if (e.ctrlKey) return;
    // TODO-1387: treat a frame as horizontal (leave it to native) only when the
    // horizontal delta clearly leads the vertical one. Strict '>' (was '<=') keeps
    // 45deg / equal-magnitude frames scrolling vertically instead of dropping them;
    // the HORIZONTAL_MARGIN slack stops touchpad horizontal jitter from shredding a
    // genuine vertical two-finger scroll frame-by-frame. A pure horizontal wheel
    // (deltaY 0) or shift+wheel still falls through to native scrolling.
    const absY = Math.abs(e.deltaY);
    const absX = Math.abs(e.deltaX);
    if (absY === 0) return;
    if (absX > absY + POPUP_WHEEL_HORIZONTAL_MARGIN) return;
    const deltaPx = popupWheelDeltaToPixels(e.deltaY, e.deltaMode, window.innerHeight);
    if (deltaPx === 0) return;
    if (popupAncestorAbsorbsVerticalWheel(__fushiEventTarget(e), deltaPx)) return;
    // BUG-732: 这段缩放平滑滚动只服务查词弹窗。扩展里弹窗是宿主页上的 shadow 覆盖层，
    // __fushiWheelScroller 仅当滚轮 composedPath 穿过弹窗 shadow 才返回 host（scroller
    // 已在本监听最顶部解析并早退）；返回 null 时唯一合法「滚 window」的表面是 in-app
    // 弹窗文档（整份文档即弹窗，且无 chrome.runtime）。普通网页上扩展 content script 有
    // chrome.runtime.id，滚轮不在弹窗内已在顶部放行原生滚动：否则整页会被
    // POPUP_WHEEL_PIXEL_FACTOR(0.48) 降速 + preventDefault 抢走原生滚动。
    e.preventDefault();
    // TODO-1387: carry the sub-pixel remainder across events; BUG-870: also reset
    // the device-class latch here so each new gesture is classified fresh. A
    // precision touchpad reports deltaMode=PIXEL with small fractional deltaY;
    // after the zoom divide each frame can be a fraction of a layout pixel.
    // scrollBy only moves whole (sub)pixels, so without the accumulator the
    // fraction was discarded every frame — preventDefault killed native scroll
    // while the popup advanced ~0px. Accumulate the fraction and emit only the
    // whole part, keeping the remainder for the next event. Reset the carry (and
    // the latch) on a surface switch or after an idle gap so a stale remainder can
    // never cause a delayed jump.
    const nowMs = performance.now();
    if (scroller !== _popupWheelResidualSurface ||
        (nowMs - _popupWheelResidualAt) > POPUP_WHEEL_RESIDUAL_IDLE_MS) {
        _popupWheelResidual = 0;
        _popupWheelResidualSurface = scroller;
        _popupWheelFineDevice = false;
    }
    _popupWheelResidualAt = nowMs;
    // BUG-870: the 0.48 downscale is tuned for a COARSE mouse notch (deltaMode
    // PIXEL, deltaY≈100-120 → visualStep≈48) so a notch does not jump a huge
    // chunk. A precision touchpad / hi-res wheel reports small pixel deltas;
    // applying the coarse-mouse factor to them makes scrolling unnaturally slow.
    // Classify per gesture: a small pixel-mode frame latches the stream as a fine
    // device (kept until the idle reset above, so an occasional large mid-fling
    // frame is not mis-tamed); fine devices scroll ~1:1 (factor 1.0, still divided
    // by zoom below). LINE/PAGE mode is always a classic mouse.
    const fineFrame = e.deltaMode === 0 && absY < POPUP_WHEEL_MOUSE_NOTCH_PX;
    if (fineFrame) { _popupWheelFineDevice = true; }
    const coarseMouseNotch = !_popupWheelFineDevice &&
        (e.deltaMode !== 0 || absY >= POPUP_WHEEL_MOUSE_NOTCH_PX);
    // BUG-1026: 用户可调「滚轮速度」倍率。in-app 由 popup_settings_injection 注入
    // window.__fushiPopupWheelSpeed；浏览器扩展经查词响应 theme 的 --fushi-wheel-speed
    // 由 content.js 设同名全局（content/popup 同隔离世界共享 window）。缺省/非法 → 1.0，
    // 与改前逐帧一致。倍率同乘粗鼠标(0.24)与触控板(1.0)，作为统一滚轮速度旋钮。
    const wheelSpeed = (typeof window.__fushiPopupWheelSpeed === 'number' &&
        isFinite(window.__fushiPopupWheelSpeed) && window.__fushiPopupWheelSpeed > 0)
        ? window.__fushiPopupWheelSpeed
        : 1;
    const factor = (coarseMouseNotch
        ? POPUP_WHEEL_PIXEL_FACTOR
        : POPUP_WHEEL_TRACKPAD_FACTOR) * wheelSpeed;
    // Scale the notch, cap unusually large visual deltas, then divide by zoom so
    // the on-screen step is zoom-independent.
    const visualStep = popupClampWheelVisualStep(deltaPx * factor);
    // BUG-688: scroll the surface the wheel is actually over. Extension popup:
    // the shadow host is the scroll container (the ancestor walk above cannot
    // cross the shadow boundary, so it never absorbs there). In-app popup and
    // wheels over the host page: the window, exactly as before the shadow move.
    const layoutStep = visualStep / popupCurrentZoom(scroller);
    _popupWheelResidual += layoutStep;
    const step = Math.trunc(_popupWheelResidual);
    _popupWheelResidual -= step;
    if (step === 0) return; // sub-pixel this frame — carried to the next event
    if (scroller) { scroller.scrollBy({ top: step, behavior: 'auto' }); }
    else { window.scrollBy({ top: step, behavior: 'auto' }); }
};
if (typeof chrome !== 'undefined' && !!(chrome.runtime && chrome.runtime.id)) {
    // BUG-1078: 扩展 content script——绝不常驻 document。content.js 在弹窗 shadow host
    // 创建时把这个监听挂上去（{passive:false} 只作用于弹窗内滚轮）、销毁时卸载；弹窗
    // 不在场时宿主页 document 上没有任何非 passive wheel 监听，浏览器保留合成器快速
    // 滚动路径。
    window.__fushiPopupWheelListener = __fushiPopupWheelListener;
} else {
    // in-app 弹窗 WebView：整份文档就是弹窗，常驻 document 监听是正确行为（不变）。
    document.addEventListener('wheel', __fushiPopupWheelListener, { passive: false });
}


let _popupMouseDownPos = null;
document.addEventListener('mousedown', (e) => {
    if (!__fushiEventInsidePopup(e)) return;
    _popupMouseDownPos = { x: e.clientX, y: e.clientY };
});

// BUG-767：MDX 词典条目里的交叉引用（類義語 等）是原始 HTML
// `<a href="entry://词（読み）">词</a>`，经 innerHTML 注入到 .glossary-content
// （renderContent → rewriteDictLinks，dict-media.js 只重写 <link>/<img>，不碰 <a>）。
// 它既没有结构化内容链接那套 onclick（preventDefault + onLinkClick 重查，见
// renderStructuredContent），结果 WebView 也没有装 shouldOverrideUrlLoading 导航拦截、
// 未注册 entry:// scheme。裸点击 → 浏览器对结果框架发起默认导航到无法解析的 entry:// URL →
// 主框架离开 popup.html、已渲染词条 DOM 全被销毁 → 内容区空白（只剩 Flutter 画的页头）。
// 统一在此拦下 glossary 内锚点：先 preventDefault（根因——绝不让结果框架被导走），外链交给
// openExternalLink，发音媒体节点忽略，其余内部交叉引用用可见词头 textContent 作查询词转成
// onLinkClick 重查（与结构化内容链接、app 的干净词头索引一致）。抽成具名函数便于 test/js
// jsdom 行为测试直接执行判据。
function handleGlossaryAnchorClick(event, anchor) {
    event.preventDefault();
    const href = (anchor.getAttribute('href') || '').trim();
    if (/^https?:\/\//i.test(href)) {
        openExternalLink(href);
        return;
    }
    if (/^sound:/i.test(href)) {
        // BUG-1261：词典发音媒体节点（sound://xxx）。不是查词目标；导航已被阻止，
        // 改走与 <img>/gaiji 完全相同的词典媒体字节通道播放：剥掉 sound: 前缀后交给
        // rewriteDictionaryMediaPath（app 内 → image:// 自定义 scheme，四个宿主表面
        // 均已注册；浏览器扩展 → 带 token 的 /api/media/dictionary HTTP 端点），
        // 再用 playWordAudio 播（与单词 ♪ 同一 <audio> 路径：音量/interrupt 语义一致）。
        // dictName 取最近的 [data-dictionary] 容器（MDX 释义 wrapper 3052 行必设）。
        const dictNode = anchor.closest('[data-dictionary]');
        const soundDict = dictNode ? dictNode.getAttribute('data-dictionary') : '';
        const soundPath = href.replace(/^sound:\/*/i, '');
        if (soundDict && soundPath) {
            const soundUrl = rewriteDictionaryMediaPath(soundPath, soundDict);
            if (soundUrl) playWordAudio(soundUrl);
        }
        return;
    }
    const query = (anchor.textContent || '').trim();
    if (!query) return;
    const rect = anchor.getBoundingClientRect();
    markGlobalLookupExtHit(anchor);
    window.flutter_inappwebview.callHandler('onLinkClick', query, {
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
    });
}

document.addEventListener('click', (e) => {
    if (!__fushiEventInsidePopup(e)) return;
    if (_popupMouseDownPos) {
        const dx = e.clientX - _popupMouseDownPos.x;
        const dy = e.clientY - _popupMouseDownPos.y;
        _popupMouseDownPos = null;
        if (dx * dx + dy * dy > 25) {
            return;
        }
    }

    const sel = __fushiSel();
    if (sel && sel.toString().length > 0) {
        sel.removeAllRanges();
        return;
    }

    const _t0 = __fushiEventTarget(e); const target = _t0?.nodeType === Node.TEXT_NODE ? _t0.parentElement : _t0;
    // 弹窗尺寸拖拽把手（浏览器扩展 Phase D）是宿主页 body 顶层兄弟 #fushi-popup-resize-grip，
    // 不在任何弹窗内部选择器内，点/拖它会落到本函数末尾的 tapOutside 关窗（用户报「拖动关窗」）。
    // 这里显式豁免：点/拖把手绝不关窗。app 内弹窗文档里无此元素，closest 永不命中 → no-op。
    if (target?.closest?.('#fushi-popup-resize-grip')) return;
    // TODO-1189 — audio/mine/favorite are per-entry action buttons; a click on any
    // of them must NEVER reach the document dismiss path. .favorite-button was
    // missing here, so tapping ☆ on a PARENT card fell through to the .entry
    // branch below: with __hasChildPopup true it posted tapOutside ->
    // dismissDescendantsOf(parent), wrongly closing the child sub-popup (app-in).
    // It also hardens the app-OUT global overlay path (host frameIdAtPoint).
    if (target?.closest('.mine-button') || target?.closest('.audio-button') ||
        target?.closest('.favorite-button')) return;
    if (target?.closest('summary')) return;
    if (target?.closest('.glossary-content')) {
        // BUG-767：glossary 内的锚点（MDX 原始 HTML 交叉引用/外链/发音）统一走
        // handleGlossaryAnchorClick——preventDefault 阻止默认导航（否则结果框架被导走→白屏），
        // 内部引用转 onLinkClick 重查。结构化内容链接自带 onclick + stopPropagation，永不冒泡到此。
        const glossaryAnchor = target?.closest('a[href]');
        if (glossaryAnchor) {
            handleGlossaryAnchorClick(e, glossaryAnchor);
            return;
        }
        // TODO-869 收尾：词典释义正文（.glossary-content）是父卡片占面积最大的可点
        // 区，也是用户说的「词典部分」。若本层有子弹窗（__hasChildPopup，宿主据
        // index < entries.length-1 注入），点正文应先关掉后代层（dismissDescendantsOf），
        // 与点卡片留白/背景同语义——否则点父窗正文只选词、子窗永远关不掉（用户原始
        // 症状）。叶子层（__hasChildPopup falsy）仍选词，TODO-859 不回归。
        if (window.__hasChildPopup) {
            window.flutter_inappwebview.callHandler('tapOutside');
            return;
        }
        window.fushiSelection?.selectText(e.clientX, e.clientY, 20);
        return;
    }
    // TODO-859 方案1：用「点击是否落在某张词条卡片内」的正向判定取代旧黑名单。旧逻辑
    // 列举 .entry-header/.entry-tags/.glossary-group/.category-section「之外才发
    // tapOutside」，但词条卡片(.entry)内还有这些选择器都覆盖不到的留白——li 外边距、
    // category-body padding、词条之间、kanji-card-section、单义项的无 class wrapper——
    // 点这些留白既不选词(上面 .glossary-content 分支只命中文字本体)也不发 tapOutside，
    // 成了「关不掉子弹窗」的死区，用户得往父弹窗上面的真空白带才能关。
    //
    // 方案1语义：词条卡片区域(卡片本体文字+其留白)一律保留本层(点文字走上面的选词
    // 分支)，只有点到所有卡片之外的纯弹窗背景(body/no-results 占位)才发 tapOutside 关
    // 后代。卡片根=.entry(词条卡片) 或 .kanji-card-section(汉字卡片容器)。汉字卡片真正
    // 的顶层根是 buildKanjiCards 建的 .kanji-card-section，.kanji-card 只是它的子节点；
    // 用 .kanji-card 会漏掉「两张 kanji-card 之间的 4px 间隙」和「section 自身的上下外
    // 边距」——点这些留白两个 closest 都不命中→落 tapOutside 关子窗=死区对汉字卡复发。
    // 改判 .kanji-card-section 才能覆盖卡间留白 + section 外边距。
    if (target?.closest('.entry') || target?.closest('.kanji-card-section')) {
        // TODO-869：点卡片本体留白本应保留本层（TODO-859 语义）。但若本层有子弹窗
        // （__hasChildPopup，宿主据 index < entries.length-1 注入），点卡片区也得发
        // tapOutside 让宿主关掉后代层（dismissDescendantsOf）——否则父窗点卡片关不掉子
        // 窗（卡片占父弹窗绝大面积）。叶子层 __hasChildPopup falsy → 仍裸 return 保持
        // 859 不回归。点文字本体走上面 .glossary-content 选词分支，不经这里。
        if (window.__hasChildPopup) {
            window.flutter_inappwebview.callHandler('tapOutside');
        }
        return;
    }
    window.flutter_inappwebview.callHandler('tapOutside');
});

var _popupShiftLastX = -1, _popupShiftLastY = -1;
document.addEventListener('mousemove', function(e) {
    if (!__fushiEventInsidePopup(e)) return;
    if (!e.shiftKey) { _popupShiftLastX = -1; _popupShiftLastY = -1; return; }
    var dx = e.clientX - _popupShiftLastX, dy = e.clientY - _popupShiftLastY;
    if (dx * dx + dy * dy < 64) return;
    _popupShiftLastX = e.clientX; _popupShiftLastY = e.clientY;
    if (window.fushiSelection) {
        window.fushiSelection.selectText(e.clientX, e.clientY, 20);
    }
}, {passive: true});
