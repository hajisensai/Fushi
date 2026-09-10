import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 词典改名（v95）在查词弹窗里的注入边界守卫。
///
/// 弹窗里的 `dictName` 是**一个字符串扛七种职责**：一份给人看的标题，另外六份
/// 是键——`data-dictionary` CSS 作用域属性、`window.dictionaryStyles` 查表、
/// 隐藏/折叠过滤、释义语言查表、词典媒体 URL 的 `dictionary=` 参数（要对上磁盘
/// 目录名）、`glossaries` 分组 key（Anki `{single-glossary-<名>}` token 靠它
/// 对齐）。
///
/// 所以改名的正确做法是**旁路翻译**：只在渲染文本的地方把真名换成显示名，其余
/// 六处一律保持真名。这个守卫的重点不是「翻译有没有接上」（那一眼能看出来），
/// 而是**负向**的那半——顺手把某个键也翻译了，表现是用户样式静默失效 / 词典图
/// 音 404 / 已配置的制卡字段对不上，全都不会抛错，只会安静地错。
String _readPopupJs() {
  final File file = File('assets/popup/popup.js');
  expect(file.existsSync(), isTrue, reason: '找不到 assets/popup/popup.js');
  // 掩掉注释：本文件的锚点全是代码标识符，没有一条要读注释内容。不掩的话在注释
  // 里写一句 `__fushiDictDisplayName(dictName)` 就能把整组正向断言骗绿。
  return maskJsComments(file.readAsStringSync());
}

/// 取 [source] 中 [needle] 所在那一行（已掩码的源码上定位）。
String _lineContaining(String source, String needle) {
  final int at = source.indexOf(needle);
  expect(at, isNot(-1), reason: '锚点消失了，需要重新确认渲染点：$needle');
  final int start = source.lastIndexOf('\n', at) + 1;
  int end = source.indexOf('\n', at);
  if (end < 0) end = source.length;
  return source.substring(start, end);
}

void main() {
  group('词典显示名只翻译文本、不翻译键', () {
    test('翻译函数存在，且回落真名而不是空', () {
      final String js = _readPopupJs();
      expect(
        js.contains('function __fushiDictDisplayName('),
        isTrue,
        reason: '真名 -> 显示名的唯一入口',
      );
      // 表不存在 / 没改过名时必须原样返回真名。少了这条回落，扩展侧（映射表可能
      // 还没下发）和悬浮窗会渲染出 undefined。
      final String body = methodBody(
        js,
        'function __fushiDictDisplayName(',
        lexicon: SourceLexicon.js,
      );
      expect(
        body.contains('return name'),
        isTrue,
        reason: '无映射时必须回落真名',
      );
    });

    test('四个给人看的词典名都过翻译', () {
      final String js = _readPopupJs();
      for (final (String what, String anchor) in <(String, String)>[
        ('释义分组标题', "className: 'dict-name'"),
        ('频率标签', "className: 'frequency-dict-label'"),
        ('音高标签', "className: 'pitch-dict-label'"),
        ('汉字卡词典名', "className: 'kanji-card-dict'"),
      ]) {
        final String line = _lineContaining(js, anchor);
        expect(
          line.contains('__fushiDictDisplayName('),
          isTrue,
          reason: '$what 是给人看的文本，必须显示用户改的名字（$anchor）',
        );
      }
    });

    test('负向：翻译只许出现在那 4 个渲染点，别处一律真名', () {
      // 白名单而不是黑名单。黑名单要枚举所有「当键用」的写法——`data-dictionary`
      // 有单引号属性名和模板串两种形态、还有 `dataset.dictionary`，样式查表是可选
      // 链 `window.dictionaryStyles?.[`，另有隐藏/折叠过滤、释义语言查表、媒体
      // URL、glossaries 分组 key——枚举一定漏，而本守卫第一版就漏了：needle 写成
      // `window.dictionaryStyles[`（无可选链），在文件里命中 0 行，那半组断言一次
      // 都没执行过。
      //
      // 反过来钉「允许出现的位置」就没有这个问题：调用点是有限且明确的 4 个，
      // 任何新增的翻译——包括顺手加到 data-dictionary 上的——都会落在白名单外
      // 而被当场抓住。
      final String js = _readPopupJs();
      const List<String> allowedAnchors = <String>[
        "className: 'dict-name'",
        "className: 'frequency-dict-label'",
        "className: 'pitch-dict-label'",
        "className: 'kanji-card-dict'",
      ];

      final List<String> offenders = <String>[];
      int callSites = 0;
      for (final String line in js.split('\n')) {
        if (!line.contains('__fushiDictDisplayName(')) continue;
        // 函数自身的定义与递归无关的内部引用不算调用点。
        if (line.contains('function __fushiDictDisplayName(')) continue;
        callSites++;
        if (!allowedAnchors.any(line.contains)) offenders.add(line.trim());
      }

      expect(
        offenders,
        isEmpty,
        reason: '词典显示名只能进 textContent。这些行把它用在了别处——那个字符串'
            '同时是 CSS 作用域键 / 媒体目录键 / 分组键 / Anki token 键，翻译了'
            '会让用户样式静默失效、词典图音 404、已配置的制卡字段对不上：$offenders',
      );
      expect(
        callSites,
        allowedAnchors.length,
        reason: '调用点数量应恰好等于允许的渲染点数量',
      );
    });

    test('负向：CSS 作用域键的每一种写法都仍是真名', () {
      // data-dictionary 单独再钉一遍：它是最危险的一个（要与样式规则编译出的
      // 选择器、以及已导出 Anki 卡片里的属性同源），且有属性名和模板串两种形态。
      final String js = _readPopupJs();
      for (final String line in js.split('\n')) {
        final bool mentionsScopeKey = line.contains("'data-dictionary'") ||
            line.contains('data-dictionary=') ||
            line.contains('dataset.dictionary');
        if (!mentionsScopeKey) continue;
        expect(
          line.contains('__fushiDictDisplayName('),
          isFalse,
          reason: 'CSS 作用域键必须是真名：$line',
        );
      }
    });

    test('宿主与两个扩展镜像装的是同一份翻译', () {
      // parity 守卫已经钉了三份 popup.js 逐字节相同；这里只钉「翻译确实进了
      // 三份」，免得有人只改了 assets 那一份就以为扩展也生效了。
      for (final String path in <String>[
        'assets/popup/popup.js',
        'assets/browser_extension/vendor/popup.js',
        '../tools/browser-extension/vendor/popup.js',
      ]) {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: '缺镜像：$path');
        expect(
          file.readAsStringSync().contains('function __fushiDictDisplayName('),
          isTrue,
          reason: '$path 没有翻译函数——该宿主里的改名不生效',
        );
      }
    });

    test('扩展侧真的会拿到映射表', () {
      // popup.js 读 window.dictionaryDisplayNames；扩展里这个全局只可能由
      // dict-media.js 的 applyFushiPopupCss 赋值。少这一步，改名在扩展里静默
      // 无效（不报错，只是永远显示真名）。
      for (final String path in <String>[
        'assets/browser_extension/vendor/dict-media.js',
        '../tools/browser-extension/vendor/dict-media.js',
      ]) {
        final String js = maskJsComments(File(path).readAsStringSync());
        expect(
          js.contains('window.dictionaryDisplayNames'),
          isTrue,
          reason: '$path 没把映射表落到 window，扩展里改名不生效',
        );
      }
      // 且 SW 侧必须把它并进 revision 门控缓存，否则命中缓存的那些查词回包里
      // 没有这个字段 → 上面那步赋成空表 → 改名忽有忽无。
      for (final String path in <String>[
        'assets/browser_extension/background.js',
        '../tools/browser-extension/background.js',
      ]) {
        final String js = maskJsComments(File(path).readAsStringSync());
        expect(
          js.contains('dictionaryDisplayNames'),
          isTrue,
          reason: '$path 的 popup CSS 缓存没带上映射表，命中缓存时改名会丢',
        );
      }
    });
  });

  group('宿主侧注入', () {
    test('注入了映射表，且它进了 memo 判定', () {
      final String source =
          File('lib/src/pages/implementations/popup_settings_injection.dart')
              .readAsStringSync();
      // 注入语句本身住在一段 JS 模板**字符串字面量**里，所以这一条只能掩注释
      // （掩了字符串就什么都找不到——这正是本守卫第一版的假红）。
      final String withStrings = maskComments(source);
      expect(
        withStrings.contains('window.dictionaryDisplayNames'),
        isTrue,
        reason: 'popup.js 读这个全局，宿主必须注入',
      );
      // memo 判定是真代码，掩掉字符串再找，免得被注释/字面量骗绿。
      final String dart = maskCommentsAndStrings(source);
      // 静态设置块是 memo 过的：不把映射表纳入命中判定，改完名会一直命中旧
      // memo，表现就是「改了没反应」——与 languageFingerprint 当年同一个坑。
      expect(
        dart.contains('cached.dictionaryDisplayNames == dictionaryDisplayNames'),
        isTrue,
        reason: '映射表必须进 memo 判定，否则改名不生效',
      );
    });
  });
}
