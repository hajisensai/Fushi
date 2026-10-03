// BUG-2905：VN 切屏切点禁则的行为级跑手（由 vn_split_kinsoku_behavior_test.dart 用
// node 执行，argv[2] = payload.json）。
//
// 从生成的 VN shell 原文里切出 `splitScreenToViewport` 起到 `textItemsForScreen` 前的
// 整段方法（含 viewportSplitKinsokuBoundary / 禁则字表 / 单元分组），只把量尺与屏描述
// 换成替身：一屏装得下 = 字数 <= capacity。这样断言跑的是生产切点逻辑本身。
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

const shell = data.shell;
const startMarker = '\n  splitScreenToViewport: function(';
const endMarker = '\n  textItemsForScreen: function(';
const start = shell.indexOf(startMarker);
assert(start >= 0, 'splitScreenToViewport not found in the generated VN shell');
const end = shell.indexOf(endMarker, start);
assert(end > start, 'textItemsForScreen not found after splitScreenToViewport');
const methods = new Function('return {' + shell.slice(start, end) + '\n};')();

function split(text, capacity) {
  const vn = Object.assign({}, methods, {
    contentStream: null,
    textItemsForScreen(screen) {
      return Array.from(screen.text).map(function(char) {
        return {char: char, rubyRoot: null};
      });
    },
    screenFromTextItems(items, from, to) {
      return {text: items.slice(from, to).map(function(item) { return item.char; }).join('')};
    },
    measureScreenFits(candidate) {
      return Array.from(candidate.text).length <= capacity;
    }
  });
  return vn.splitScreenToViewport({text: text, ids: new Set()}, {}).map(function(s) {
    return s.text;
  });
}

function expectSplit(text, capacity, expected) {
  const actual = split(text, capacity);
  assert(actual.join('') === text,
    'split lost or reordered text: ' + JSON.stringify(actual));
  assert(JSON.stringify(actual) === JSON.stringify(expected),
    'split(' + JSON.stringify(text) + ', ' + capacity + ') = ' +
    JSON.stringify(actual) + ', expected ' + JSON.stringify(expected));
}

// ① 段落只多出一个句号：不得切出一屏孤零零的「。」，而是把前一个字一起带过去。
expectSplit('あいうえおかきくけこ。', 10, ['あいうえおかきくけ', 'こ。']);
// ② 连续的行首禁则字（！」）整串退回，直到下一屏以可开头的字起首。
expectSplit('あいうえおかきくな！」', 10, ['あいうえおかきく', 'な！」']);
// ③ 与正文 `line-break: normal` 对齐：CJ 类（拗音小字与长音）可以起首，不再把前一个
// 字带走（strict 下「たった」「コート」落在边界时会多推一个字、留出空格）。
expectSplit('あいうえおかきくちゃ', 9, ['あいうえおかきくち', 'ゃ']);
expectSplit('あいうえおかきくけー', 9, ['あいうえおかきくけ', 'ー']);
expectSplit('そうだ、たった', 6, ['そうだ、たっ', 'た']);
expectSplit('ロングコート', 4, ['ロングコ', 'ート']);
// ④ 开括号不得留在上一屏末尾。
expectSplit('あいうえおかきく「けこ」', 9, ['あいうえおかきく', '「けこ」']);
// ⑤ 装得下就不切。
expectSplit('そう思ったのは、俺だけ。', 20, ['そう思ったのは、俺だけ。']);
// ⑥ 全是禁则字时本屏内无合规切点：放弃禁则、用最宽切点，切屏仍有进展、不丢字。
expectSplit('。。。。。', 2, ['。。', '。。', '。']);
// ⑥' 连续禁则字远超一屏（capacity = 5）：切点等于二分的最宽切点 best，而不是退到
// start + 1 每屏只剩一个字（那样 21 个字会切出 21 屏）。
expectSplit('あ' + 'ー'.repeat(20), 5, ['あーーーー', 'ーーーーー', 'ーーーーー', 'ーーーーー', 'ー']);
expectSplit('っ'.repeat(12), 5, ['っっっっっ', 'っっっっっ', 'っっ']);
expectSplit('！？'.repeat(6), 5, ['！？！？！', '？！？！？', '！？']);
// 禁则串之前有合规切点时仍照常往回退（追い出し 不受影响）。
expectSplit('あいう' + '。'.repeat(12), 5, ['あい', 'う。。。。', '。。。。。', '。。。']);
// ⑦ 普通切点不受影响。
expectSplit('あいうえおかきくけこさしすせそ', 10, ['あいうえおかきくけこ', 'さしすせそ']);

process.stdout.write('OK\n');
