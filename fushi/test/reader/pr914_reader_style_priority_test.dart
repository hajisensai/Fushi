import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// PR#914 阻塞④：「优先书籍样式」默认开启后，哪些声明**不许**跟着撤 `!important`。
///
/// ④ 链接色：`a { color }` 是阅读器唯一强制链接色的地方。撤掉 `!important` 后，EPUB
/// 里极常见的 `a{color:#000}` 在深色主题（背景 `#0A0A0A`）下就是黑底黑字，脚注/注释
/// 跳转链接不可见。e-ink 模式有无条件兜底，普通主题没有。开关的正当理由（「出版商
/// CSS 是为它自带的插图排的」）对图片尺寸成立，对链接色不成立。
///
/// 顺带保守化：`max-width` / `max-height` 是**页面容纳约束**。撤 `!important` 后书
/// CSS 自带 `!important`、id 选择器（固定版式插图页常见 `#page1 svg`）、`svg` 通用
/// 规则都能夺权，而本文件的通用规则特异性只有 (0,0,1) —— 那会打穿 BUG-025 / BUG-513
/// 的承重墙。只有 `width` / `height` / `object-fit` / `display` / `margin` 跟随开关。
///
/// 断言用到的生产 CSS 字面量（改这些要同步改这里）：
///   'color: ' + linkColor + ' !important;'（恒 !important）
///   'max-width: '/'max-height: ' 后必须恒跟 ' !important;'
///   'width: auto'/'object-fit: contain'/'display: block'/'margin: auto'（跟随开关）
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

/// 一条 CSS 声明的全部出现（整份样式表逐行扫，不截片段——截掉的抵消规则会让探针
/// 给出「可信但完全错误」的测量）。
List<String> _declarations(String css, String property) {
  return css
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.startsWith('$property:'))
      .toList();
}

void main() {
  late FushiDatabase db;

  setUp(() {
    db = _testDb();
    MediaSource.setDatabase(db);
    ReaderFushiSource.readerSettings = null;
  });

  tearDown(() async {
    ReaderFushiSource.readerSettings = null;
    await db.close();
  });

  Future<String> cssWith({required bool prioritizeBookStyles}) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setPrioritizeReaderStyles(prioritizeBookStyles);
    return ReaderContentStyles.css(settings: settings);
  }

  group('④ 链接色恒 !important（不跟随「优先书籍样式」）', () {
    test('开关开着（新默认）时 a{color} 仍带 !important', () async {
      final String css = await cssWith(prioritizeBookStyles: true);

      // 整份样式表里 `a { ... }` 这条规则只有一处，且它的 color 必须是 !important。
      final int aRuleCount = '\na {\n'.allMatches(css).length;
      expect(aRuleCount, 1, reason: '`a { }` 规则应当只有一处（改了就要重新核对本守卫）');
      final int aRuleStart = css.indexOf('\na {\n');
      final String aRule =
          css.substring(aRuleStart, css.indexOf('}', aRuleStart));
      expect(aRule, contains('!important'),
          reason: '撤掉 !important → 书自带 a{color:#000} 在深色主题下黑底黑字（PR#914 ④）');

      // 反向：整份样式表里不得存在**没有** !important 的裸 `color: <链接色>;` 结尾。
      expect(aRule.trim().endsWith(';'), isTrue);
      expect(aRule, isNot(matches(RegExp(r'color: [^;!]+;'))),
          reason: '链接色声明不得以无 !important 的形式出现');
    });

    test('开关关着时行为不变（仍是 !important，逐字节同形）', () async {
      final String on = await cssWith(prioritizeBookStyles: true);
      final String off = await cssWith(prioritizeBookStyles: false);
      final int onStart = on.indexOf('\na {\n');
      final int offStart = off.indexOf('\na {\n');
      expect(
        on.substring(onStart, on.indexOf('}', onStart)),
        off.substring(offStart, off.indexOf('}', offStart)),
        reason: '链接色不再受开关影响，两态必须完全一致',
      );
    });
  });

  group('④ 顺带：页面容纳约束（max-width / max-height）恒 !important', () {
    test('开关开着时每一条 max-width / max-height 都带 !important', () async {
      final String css = await cssWith(prioritizeBookStyles: true);

      final List<String> maxW = _declarations(css, 'max-width');
      final List<String> maxH = _declarations(css, 'max-height');
      expect(maxW, isNotEmpty);
      expect(maxH, isNotEmpty);
      for (final String d in <String>[...maxW, ...maxH]) {
        expect(d, contains('!important'),
            reason: '书 CSS 的 !important / id 选择器会夺权把图撑出页面容纳盒：$d');
      }
    });

    test('跟随开关的仍然跟随（只收紧上限，不把整条规则钉死）', () async {
      final String on = await cssWith(prioritizeBookStyles: true);
      final String off = await cssWith(prioritizeBookStyles: false);

      expect(on, contains('width: auto;'));
      expect(on, isNot(contains('width: auto !important;')));
      expect(on, contains('object-fit: contain;'));
      expect(on, isNot(contains('object-fit: contain !important;')));

      expect(off, contains('width: auto !important;'));
      expect(off, contains('object-fit: contain !important;'));
    });
  });
}
