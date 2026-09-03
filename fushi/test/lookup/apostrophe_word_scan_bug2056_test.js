// BUG-2056 行为守卫：词内撇号必须被前向扫描跨过去，英语的缩合形/所有格才查得到。
//
// 症状：英文正文里点 "don’t" 的 don，喂给引擎的查询串是 "don"；点 t 是 "t"。
// en.json 词形还原表里 don't / it's / John's 这类整类匹配不到。真实 EPUB 几乎都用
// 排版撇号 U+2019，而它和 ASCII ' 一样在 scanDelimiters 里，前向扫描一撞上就 break。
//
// 根因修复：撇号是否词边界取决于**上下文**，不是字符本身。两侧都是空格分词类字母
// （字母集与 native/fushidicts/fushidicts_src/scan/word_scan.cpp 的
// is_space_delimited_letter 逐区间对齐）时它是词内字符，前向扫描跨过去。
//
// 刻意**不改词首回退**：回退跨撇号会把 l’homme / dell’arte 的锚点从 homme 拖回 l’，
// 反而查不到 homme。前向跨过是纯增益（scan_candidates 生成 don’t / don’ / don
// 三级前缀，短词不会被挤掉），回退跨过是零和的锚点搬家。⑥⑦ 两条把这个取舍钉死。
//
// 本 harness 用 node:vm 在最小 fake DOM 里真执行两份实现的 selectFromPosition
// （fake DOM 与 phrase_lookup_whitespace_bridge_bug1773_test.js 同构）：
//   ① assets/popup/selection.js（浮窗 / 浏览器扩展，三镜像逐字节 parity 另有测试守）
//   ② 阅读器注入脚本 ReaderSelectionScripts.source()——由 .dart wrapper 落到临时
//      文件，路径经环境变量 FUSHI_READER_SELECTION_JS 传入；没传就只测 ①。
//
// 运行：node fushi/test/lookup/apostrophe_word_scan_bug2056_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// ---- 最小 fake DOM -------------------------------------------------------

function makeText(content, parent) {
  return { nodeType: 3, textContent: content, nodeValue: content, parentElement: parent };
}

function selectorTags(selector) {
  return selector
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0 && !s.startsWith('.') && !s.startsWith('['));
}

function makeElement(tagName) {
  const el = {
    nodeType: 1,
    tagName,
    className: '',
    parentElement: null,
    childNodes: [],
    get textContent() {
      return this.childNodes.map((c) => c.textContent).join('');
    },
    closest(selector) {
      const tags = selectorTags(selector);
      let node = this;
      while (node && node.nodeType === 1) {
        if (tags.includes((node.tagName || '').toLowerCase())) return node;
        node = node.parentElement;
      }
      return null;
    },
  };
  return el;
}

function makeRange() {
  return {
    startContainer: null,
    startOffset: 0,
    endContainer: null,
    endOffset: 0,
    setStart(node, offset) {
      this.startContainer = node;
      this.startOffset = offset;
    },
    setEnd(node, offset) {
      this.endContainer = node;
      this.endOffset = offset;
    },
    collapse() {},
    getClientRects() {
      return [{ left: 0, right: 10, top: 0, bottom: 10, x: 0, y: 0, width: 10, height: 10 }];
    },
    getBoundingClientRect() {
      return { left: 0, right: 10, top: 0, bottom: 10, x: 0, y: 0, width: 10, height: 10 };
    },
  };
}

// TreeWalker：尊重 acceptNode 的 FILTER_REJECT（阅读器版据此跳过纯空白节点）。
function makeTreeWalker(root, filter) {
  const out = [];
  (function walk(node) {
    for (const child of node.childNodes || []) {
      if (child.nodeType === 3) {
        if (!filter || filter.acceptNode(child) === 1) out.push(child);
      } else if (child.nodeType === 1) {
        walk(child);
      }
    }
  })(root);
  return {
    currentNode: root,
    nextNode() {
      const from = out.indexOf(this.currentNode);
      const next = out[from + 1] || null;
      if (next) this.currentNode = next;
      return next;
    },
  };
}

/// 建一个 <p>，其中每段文字是一个 <span> 里的文本节点（segments 长度 > 1 时用来
/// 覆盖「跨文本节点续扫」）。返回 { sandbox, textNodes }。
function buildContext(src, segments) {
  const body = makeElement('body');
  const p = makeElement('p');
  p.parentElement = body;
  body.childNodes = [p];

  const textNodes = [];
  for (const seg of segments) {
    const span = makeElement('span');
    span.parentElement = p;
    const t = makeText(seg, span);
    span.childNodes = [t];
    p.childNodes.push(span);
    textNodes.push(t);
  }

  const document = {
    body,
    createRange: makeRange,
    createTreeWalker: (root, _whatToShow, filter) => makeTreeWalker(root, filter),
    caretPositionFromPoint: () => null,
    caretRangeFromPoint: () => null,
    elementFromPoint: () => null,
  };

  const window = {
    // 所有 span 都是行内盒 → crossesRenderBoundary 判「同一行连排」，跨节点续扫放行
    // （popup 版的 BUG-1645 路径；阅读器版没有这个函数，行为一致）。
    getComputedStyle: () => ({ display: 'inline', content: 'none' }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler: () => {} },
    scanNonJapaneseText: true,
  };
  const sandbox = {
    window,
    document,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: undefined,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);

  // 阅读器版的收尾走 fireTextSelected → buildSelectionPayload（依赖整套
  // window.fushiReader 归一化偏移）。本测试只关心扫描产出的查询串，stub 掉收尾。
  sandbox.window.fushiSelection.fireTextSelected = function () {
    return this.selection ? this.selection.text : null;
  };
  return { sandbox, textNodes };
}

/// 跑一次取词，返回喂给引擎的查询串（没选到返回 null）。
function scan(src, segments, nodeIndex, offset, maxLength) {
  const { sandbox, textNodes } = buildContext(src, segments);
  const sel = sandbox.window.fushiSelection;
  sel.selection = null;
  sel.selectFromPosition(textNodes[nodeIndex], offset, maxLength === undefined ? 24 : maxLength);
  return sel.selection ? sel.selection.text : null;
}

// ---- 断言 ----------------------------------------------------------------

// ---- 断言 ----------------------------------------------------------------

const RSQUO = '\u2019'; // ’ 排版撇号：真实 EPUB 里的主流写法
const MODAP = '\u02BC'; // ʼ MODIFIER LETTER APOSTROPHE
const LSQUO = '\u2018'; // ‘ 左单引号：OCR 常把 ’ 认成它


// 代表码点常量：用 \uXXXX 转义写死，避免编辑器/终端在搬运时把这些字符改掉。
const CP_00AA = '\u00AA';
const CP_00B5 = '\u00B5';
const CP_00BA = '\u00BA';
const CP_00C0 = '\u00C0';
const CP_00D6 = '\u00D6';
const CP_00D8 = '\u00D8';
const CP_00E9 = '\u00E9';
const CP_00F6 = '\u00F6';
const CP_00F8 = '\u00F8';
const CP_0101 = '\u0101';
const CP_0161 = '\u0161';
const CP_028C = '\u028C';
const CP_03B1 = '\u03B1';
const CP_03B2 = '\u03B2';
const CP_043F = '\u043F';
const CP_044F = '\u044F';
const CP_0442 = '\u0442';
const CP_044C = '\u044C';
const CP_04A5 = '\u04A5';
const CP_0531 = '\u0531';
const CP_0561 = '\u0561';
const CP_05D0 = '\u05D0';
const CP_05D1 = '\u05D1';
const CP_05F2 = '\u05F2';
const CP_0628 = '\u0628';
const CP_0641 = '\u0641';
const CP_066E = '\u066E';
const CP_0671 = '\u0671';
const CP_06D5 = '\u06D5';
const CP_06EE = '\u06EE';
const CP_06FA = '\u06FA';
const CP_06FF = '\u06FF';
const CP_0750 = '\u0750';
const CP_08A0 = '\u08A0';
const CP_10A0 = '\u10A0';
const CP_10D0 = '\u10D0';
const CP_1E00 = '\u1E00';
const CP_1EC7 = '\u1EC7';
const CP_1F00 = '\u1F00';
const CP_00D7 = '\u00D7';
const CP_00F7 = '\u00F7';
const CP_0530 = '\u0530';
const CP_0640 = '\u0640';
const CP_0660 = '\u0660';
const CP_10FB = '\u10FB';
const CP_0E01 = '\u0E01';

// 空格分词类字母集的**代表码点**：每条对应 spaceDelimitedLetterPattern 里的一个区间
// （字母集与 native/fushidicts/fushidicts_src/scan/word_scan.cpp 的
// is_space_delimited_letter 逐区间对齐，改一处必须改两处）。
const LETTER_RANGE_SAMPLES = [
  ['a', 'ASCII 小写 A-Za-z'],
  [CP_00AA, '序数指示符 ª (\\u00AA)'],
  [CP_00B5, '微符 µ (\\u00B5)'],
  [CP_00BA, '序数指示符 º (\\u00BA)'],
  [CP_00C0, '拉丁-1 大写段起点 À (\\u00C0-\\u00D6)'],
  [CP_00D6, '拉丁-1 大写段终点 Ö (\\u00C0-\\u00D6)'],
  [CP_00D8, '拉丁-1 段二起点 Ø (\\u00D8-\\u00F6)'],
  [CP_00E9, '法语 é (\\u00D8-\\u00F6)'],
  [CP_00F6, '德语 ö，段二终点 (\\u00D8-\\u00F6)'],
  [CP_00F8, '挪威语 ø，段三起点 (\\u00F8-\\u02AF)'],
  [CP_0101, '拉丁扩展-A ā (\\u00F8-\\u02AF)'],
  [CP_0161, '捷克语 š (\\u00F8-\\u02AF)'],
  [CP_028C, 'IPA 扩展 ʌ，段三终段 (\\u00F8-\\u02AF)'],
  [CP_03B1, '希腊 α (\\u0370-\\u03FF)'],
  [CP_043F, '西里尔 п (\\u0400-\\u052F)'],
  [CP_04A5, '西里尔扩展 ҥ (\\u0400-\\u052F)'],
  [CP_0531, '亚美尼亚大写 Ա (\\u0531-\\u0556)'],
  [CP_0561, '亚美尼亚小写 ա (\\u0561-\\u0587)'],
  [CP_05D0, '希伯来 א (\\u05D0-\\u05EA)'],
  [CP_05F2, '希伯来 ײ (\\u05EF-\\u05F2)'],
  [CP_0628, '阿拉伯 ب (\\u0620-\\u063F)'],
  [CP_0641, '阿拉伯 ف (\\u0641-\\u064A)'],
  [CP_066E, '阿拉伯无点 ba ٮ (\\u066E\\u066F)'],
  [CP_0671, '阿拉伯 ٱ (\\u0671-\\u06D3)'],
  [CP_06D5, '阿拉伯 ە (\\u06D5)'],
  [CP_06EE, '阿拉伯 ۮ (\\u06EE\\u06EF)'],
  [CP_06FA, '阿拉伯 ۺ (\\u06FA-\\u06FC)'],
  [CP_06FF, '阿拉伯 ۿ (\\u06FF)'],
  [CP_0750, '阿拉伯补充 ݐ (\\u0750-\\u077F)'],
  [CP_08A0, '阿拉伯扩展-A ࢠ (\\u08A0-\\u08BD)'],
  [CP_10A0, '格鲁吉亚 Asomtavruli Ⴀ (\\u10A0-\\u10C5)'],
  [CP_10D0, '格鲁吉亚 Mkhedruli ა (\\u10D0-\\u10FA)'],
  [CP_1E00, '拉丁扩展附加 Ḁ (\\u1E00-\\u1EFF)'],
  [CP_1EC7, '越南语 ệ (\\u1E00-\\u1EFF)'],
  [CP_1F00, '希腊扩展 ἀ (\\u1F00-\\u1FFF)'],
];

// 字母集的**空隙**：这些码点夹在上面的区间之间，必须仍然不算字母。
const LETTER_GAP_SAMPLES = [
  ['5', 'ASCII 数字'],
  [CP_00D7, '乘号 × —— \\u00D6 与 \\u00D8 之间那个洞'],
  [CP_00F7, '除号 ÷ —— \\u00F6 与 \\u00F8 之间那个洞'],
  [CP_0530, '亚美尼亚段前的未分配位 —— \\u052F 与 \\u0531 之间'],
  [CP_0640, '阿拉伯 tatweel ـ —— \\u063F 与 \\u0641 之间被刻意排除'],
  [CP_0660, '阿拉伯-印度数字 ٠'],
  [CP_10FB, '格鲁吉亚段分隔符 ჻'],
  [CP_0E01, '泰文 ก —— 无空格分词脚本，整段不在字母集里'],
];

// 真实语料形状：跨多个区间的缩合形/所有格，撇号两侧分属不同区间。
const REAL_WORLD_SAMPLES = [
  [`caf${CP_00E9}${RSQUO}s`, '法/英混排所有格 café’s（拉丁-1 段二 + ASCII）'],
  [`${CP_043F}${RSQUO}${CP_044F}${CP_0442}${CP_044C}`, '乌克兰语 п’ять（西里尔两侧）'],
  [`${CP_03B1}${RSQUO}${CP_03B2}`, '希腊 α’β（希腊两侧）'],
  [`${CP_05D0}${RSQUO}${CP_05D1}`, '希伯来 א’ב（希伯来两侧）'],
];

function runSuite(label, src) {
  // ① 根因回归：排版撇号必须被跨过，don’t 整体进查询串。
  //    修复前 offset 0/1/2 都只得到 "don"。
  for (const offset of [0, 1, 2]) {
    assert.strictEqual(
      scan(src, [`I don${RSQUO}t.`], 0, 2 + offset),
      `don${RSQUO}t`,
      `[${label}] 点 don 的第 ${offset} 位必须扫出跨撇号的 don’t（'.' 处终止）`,
    );
  }

  // ② ASCII 撇号同样处理（纯文本字幕/OCR 里常见）。
  assert.strictEqual(
    scan(src, ["don't."], 0, 0),
    "don't",
    `[${label}] ASCII 撇号也必须被跨过`,
  );

  // ③ U+02BC 是**另一回事**，别把它算成本修复的战果：它不在 scanDelimiters 里，
  //    修复前后 `canʼt` 都是整词扫出来的（旧版本这里写「也必须被跨过」，属于把一条
  //    恒真断言当成了修复证据）。留着它只作**结果**护栏：不管 ʼ 走哪条路（不截断，
  //    还是将来进了 scanDelimiters 再被桥接救回来），canʼt 都必须整词扫出。
  //    实测：单独把 ʼ 加进 scanDelimiters 这条仍然绿——因为桥接接住了它。所以
  //    「ʼ 在 pattern 里、且不在 scanDelimiters 里」这层事实由 Dart 侧的
  //    apostropheClassInvariant 用耦合不变式钉（去掉 pattern 里的 ʼ 或把它加进
  //    scanDelimiters，那条守卫红），不靠本断言冒充。
  assert.strictEqual(
    scan(src, [`can${MODAP}t.`], 0, 0),
    `can${MODAP}t`,
    `[${label}] canʼt（U+02BC）必须整词扫出`,
  );

  // ③b OCR 常把 ’ 认成 ‘（U+2018）。它**在** scanDelimiters 里，所以修复前
  //     `don‘t` 和 `don’t` 一样被截成 don——这条是真的 before/after 有别。
  assert.strictEqual(
    scan(src, [`don${LSQUO}t.`], 0, 0),
    `don${LSQUO}t`,
    `[${label}] U+2018（OCR 误识的 ’）也必须被跨过`,
  );

  // ④ 所有格 + 空格桥接叠加：撇号跨过后，BUG-1773 的空格桥接照常接上下一个词。
  assert.strictEqual(
    scan(src, [`John${RSQUO}s book.`], 0, 0),
    `John${RSQUO}s book`,
    `[${label}] 所有格与空格桥接必须叠加生效`,
  );

  // ⑤ 引号语义不受影响：右侧是空白 → 撇号仍是扫描终点。
  assert.strictEqual(
    scan(src, [`${RSQUO}hello${RSQUO} world`], 0, 1),
    'hello',
    `[${label}] 收尾引号（右侧空白）必须仍是终点`,
  );

  // ⑥ **词首回退不得跨撇号**：法语省音 l’homme 点 homme 仍锚在 homme。
  //    若把桥接也加进回退，这里会退回 l’homme，反而查不到 homme。
  assert.strictEqual(
    scan(src, [`l${RSQUO}homme.`], 0, 3),
    'homme',
    `[${label}] 词首回退必须仍在撇号处停住（法/意省音不得被拖回前缀）`,
  );

  // ⑦ 同理，点 don’t 的 t 仍只得到 t——这是 ⑥ 的同一条规则，刻意保留。
  assert.strictEqual(
    scan(src, [`don${RSQUO}t.`], 0, 4),
    't',
    `[${label}] 点撇号右侧首字母仍只从该字母起扫（与 ⑥ 同一条规则）`,
  );

  // ⑧ 非空格分词脚本两侧的撇号仍是终点（日文正文里的 ’ 是引号，不是词内字符）。
  assert.strictEqual(
    scan(src, [`私は${RSQUO}そう${RSQUO}言った`], 0, 0),
    '私は',
    `[${label}] 日文两侧的撇号必须仍是终点`,
  );

  // ⑨ 跨文本节点时新节点开头的撇号不得桥接（与空白桥接同一条纪律）。
  assert.strictEqual(
    scan(src, ['don', `${RSQUO}t`], 0, 0),
    'don',
    `[${label}] 新文本节点开头的撇号不得被当成词内字符`,
  );

  // ⑩ 撇号后必须真有字母才跨：`rock 'n' roll` 的 ' 右侧是 n、左侧是空白 → 终点。
  assert.strictEqual(
    scan(src, ["rock 'n' roll"], 0, 0),
    'rock',
    `[${label}] 左侧非字母的撇号必须仍是终点`,
  );

  // ⑪ maxLength 仍是硬上限。
  assert.strictEqual(
    scan(src, [`don${RSQUO}t ask`], 0, 0, 4),
    `don${RSQUO}`,
    `[${label}] maxLength 必须仍然截断`,
  );

  // ⑬ **空格分词类字母集逐区间覆盖**（BUG-2056 补测）。
  //
  //    isIntraWordApostrophe 只看撇号紧邻的左右各一个字符，所以
  //    spaceDelimitedLetterPattern 那 30 多个区间里，只要哪一段被删掉/写错，就有一
  //    整类语言的缩合形与所有格重新被截断。此前这份测试全部用 ASCII 字母做样本：
  //    把整个字母集塌缩成 /[A-Za-z]/ 也照样全绿（实测三条变异全部存活），
  //    「与 word_scan.cpp 逐区间对齐」这句宣称没有任何东西钉住。
  //
  //    下表每条 = 一个区间的代表码点，直接放在撇号左右两侧；范围**外**的代表码点
  //    走 ⑭ 的负向表。改动字母集时先改 word_scan.cpp 的 is_space_delimited_letter，
  //    再同步四份 JS/Dart 副本，再往这两张表里加代表点。
  for (const [ch, why] of LETTER_RANGE_SAMPLES) {
    assert.strictEqual(
      scan(src, [`${ch}${RSQUO}${ch}.`], 0, 0),
      `${ch}${RSQUO}${ch}`,
      `[${label}] ${why}（U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}）`
        + ' 必须算空格分词类字母，撇号在它两侧时要被跨过',
    );
  }

  // ⑭ 字母集的**空隙**必须仍然是空隙：区间之间那些非字母码点（乘号/除号/阿拉伯
  //    tatweel/阿拉伯数字/格鲁吉亚段分隔符…）左侧不是字母，撇号仍是终点。
  //    没有这一档，把字母集放宽成一整片（\u00C0-\u02AF）也能全绿。
  for (const [ch, why] of LETTER_GAP_SAMPLES) {
    assert.strictEqual(
      scan(src, [`${ch}${RSQUO}${ch}.`], 0, 0),
      ch,
      `[${label}] ${why}（U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}）`
        + ' 不得算字母，撇号必须仍是终点',
    );
  }

  // ⑮ 真实语料形状（不是造出来的单字符）：跨区间的所有格/缩合形整词扫出。
  for (const [word, why] of REAL_WORLD_SAMPLES) {
    assert.strictEqual(
      scan(src, [`${word}.`], 0, 0),
      word,
      `[${label}] ${why} 必须整词扫出`,
    );
  }

  // ⑫ 日文逐字扫描完全不受影响（回归护栏）。
  assert.strictEqual(
    scan(src, ['素晴らしい世界'], 0, 0),
    '素晴らしい世界',
    `[${label}] 日文扫描行为不变`,
  );
}

function run() {
  const popupSrc = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'assets', 'popup', 'selection.js'),
    'utf8',
  );
  runSuite('popup/extension', popupSrc);

  const readerJsPath = process.env.FUSHI_READER_SELECTION_JS;
  if (readerJsPath && fs.existsSync(readerJsPath)) {
    runSuite('reader', fs.readFileSync(readerJsPath, 'utf8'));
  } else {
    console.log('reader selection script not provided; skipped that suite');
  }

  console.log('all assertions passed');
}

run();
