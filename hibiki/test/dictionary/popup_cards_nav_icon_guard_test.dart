import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1325 #7 / #5 part1 + TODO-1338 三镜像守卫：查词弹窗的样式/脚本改动必须三端一致
/// （in-app 弹窗 + 两份浏览器扩展 vendor 副本；byte-parity 由
/// `browser_extension_popup_parity_guard` 另锁，此处锁语义约束防回退）。
///
///   #7 词典卡片：`.glossary-group` 是 Niratan 描边卡（1px 描边 + 圆角 + inset 顶部高光 +
///      薄贴地投影，无 background 填充；照抄 Niratan Features/Popup/popup.css）。
///   #5 词条导航：popup.js 暴露 `hoshiFocusDictionaryEntry/Move/Reset`，当前词条走
///      `.entry-current` 的 #1a73e8 纯 CSS 边框蓝三角（零字体依赖）。
///   #1338 制卡图标乱码：制卡按钮保留 ✓/✓↩ 文本标记（应用户要求不走 SVG），但用
///      `.mine-button` 单色符号字体栈切断对注入词典字体的继承，且 ↩ 追加 VS15(U+FE0E)
///      强制文本呈现——两处合力杜绝制卡后乱码。
///   #1368/BUG-691 Android 豆腐：#1338 的字体栈全是桌面字体，Android WebView 按名
///      解析不到、sans-serif=Roboto 又不含 U+2713/U+21A9 → 部分 ROM 制完卡 ✓ 变豆腐。
///      popup.css 内嵌 "Hibiki Symbols"(DejaVu Sans 子集) @font-face 兜底，本文件用
///      独立 WOFF/cmap 解析器锁「内嵌字体真含这三个码位」。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 抽取 `<selector> { ... }` 规则块（行首锚定，避免命中后代规则）。
  String ruleBody(String css, String selectorPattern) {
    final RegExp re = RegExp(r'(?:^|\n)' + selectorPattern + r'\s*\{([^}]*)\}');
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull, reason: 'rule "$selectorPattern" not found');
    return m!.group(1)!;
  }

  const Map<String, String> cssMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };

  cssMirrors.forEach((String name, String relPath) {
    group('[$name] popup.css 语义约束', () {
      late final String css;
      setUpAll(() => css = read(relPath));

      test('#7 词典卡片：.glossary-group 是 Niratan 描边卡（描边+圆角+inset高光投影，无填充）', () {
        final String body = ruleBody(css, r'\.glossary-group');
        expect(RegExp(r'(^|[;{\s])border\s*:').hasMatch(body), isTrue,
            reason: 'Niratan 描边卡靠 1px 描边定形，非 background 填充');
        expect(RegExp(r'border-radius\s*:').hasMatch(body), isTrue,
            reason: '卡片要有圆角');
        expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
            reason: '卡片要有薄贴地投影 + 顶部 inset 白高光');
        expect(body.contains('inset'), isTrue,
            reason: 'box-shadow 含 inset 顶部内高光（照抄 Niratan）');
        expect(RegExp(r'background\s*:').hasMatch(body), isFalse,
            reason: 'Niratan 描边卡无 background 填充；有填充即退回玻璃卡');
      });

      test('#5 当前词条蓝三角 = 纯 CSS 边框三角 #1a73e8（零字体依赖）', () {
        final String body =
            ruleBody(css, r'\.entry-current \.entry-header::before');
        expect(body, contains("content: ''"),
            reason: '::before 空 content 承载纯边框三角，不用字体字形');
        expect(body.contains('#1a73e8'), isTrue,
            reason: '当前词条指示用 Niratan 同款蓝 #1a73e8');
        expect(RegExp(r'border-left\s*:\s*7px solid #1a73e8').hasMatch(body),
            isTrue,
            reason: '右向三角：左边框实心蓝（顶点朝右指向词条）');
      });

      test('#1338 制卡按钮钉单色符号字体栈，切断注入词典字体继承', () {
        // 直接找「含 font-family 的独立 .mine-button 规则块」——不能用通用 ruleBody，因为
        // 它会先命中 `.audio-button,.favorite-button,.mine-button` 合并块（无 font-family）。
        final RegExp rule = RegExp(
            r'\.mine-button\s*\{[^}]*font-family[^}]*Segoe UI Symbol[^}]*!important');
        expect(rule.hasMatch(css), isTrue,
            reason: '.mine-button 显式声明单色符号字体栈(含 Segoe UI Symbol)+!important，'
                '切断对 html,body 注入词典字体的继承（否则制卡后 ✓/✓↩ 缺码位乱码）');
        // 不得含彩色 emoji 字体（否则 ↩ 又走 emoji 呈现）。
        final Match? m = rule.firstMatch(css);
        expect(m!.group(0)!.contains('Emoji'), isFalse,
            reason: '字体栈不含彩色 emoji 字体');
      });
    });
  });

  jsMirrors.forEach((String name, String relPath) {
    group('[$name] popup.js 语义约束', () {
      late final String js;
      setUpAll(() => js = read(relPath));

      test(
          '#5 暴露 hoshiFocusDictionaryEntry/Move/Reset + data-hoshi-entry-index',
          () {
        expect(js.contains('window.hoshiFocusDictionaryEntry ='), isTrue,
            reason: '聚焦指定下标词条 API');
        expect(js.contains('window.hoshiFocusDictionaryEntryMove ='), isTrue,
            reason: '相对上/下一条词条 API（Dart 焦点驱动调用点）');
        expect(js.contains('window.hoshiFocusDictionaryEntryReset ='), isTrue,
            reason: '清除当前词条焦点 API');
        expect(js.contains('data-hoshi-entry-index'), isTrue,
            reason: '词条打索引属性，DOM 可观测');
      });

      test('#1338 制卡按钮保留 ✓/✓↩ 文本标记且 ↩ 带 VS15（不回退字体乱码）', () {
        // 保留文本标记（应用户要求不走 SVG）。
        expect(js.contains('\u{2713}'), isTrue, reason: '制卡态仍用 ✓(U+2713) 文本标记');
        // ↩ 后必须紧跟 VS15(U+FE0E) 强制文本呈现，杜绝 emoji 回退乱码。
        expect(js.contains('\u{21A9}\u{FE0E}'), isTrue,
            reason: '↩(U+21A9) 后必须追加 VS15(U+FE0E) 强制文本呈现');
      });
    });
  });

  group('内嵌 "Hibiki Symbols" 字形子集（TODO-1368/BUG-691）', () {
    // content.css 是生成镜像：byte-parity 守卫不覆盖它对 popup.css 的 @font-face
    // 透传（completeness 检查只看类选择器），所以这里把两份 content.css 一并锁上。
    const Map<String, String> allCssMirrors = <String, String>{
      ...cssMirrors,
      'extension content.css (assets)':
          'assets/browser_extension/vendor/content.css',
      'extension content.css (tools)':
          '../tools/browser-extension/vendor/content.css',
    };

    allCssMirrors.forEach((String name, String relPath) {
      test('[$name] .mine-button 栈：桌面字体 → Hibiki Symbols → 通用回退', () {
        final String css = read(relPath);
        final RegExpMatch? m =
            RegExp(r'\.mine-button\s*\{[^}]*font-family\s*:([^;}]*)!important')
                .firstMatch(css);
        expect(m, isNotNull, reason: '.mine-button 显式 font-family 规则丢失');
        final String stack = m!.group(1)!;
        expect(stack, contains('"Hibiki Symbols"'),
            reason: 'Android WebView 解析不到任何桌面符号字体、Roboto 又不含 '
                'U+2713/U+21A9——必须保留内嵌 "Hibiki Symbols" 兜底，否则手机制完卡'
                '✓ 在部分 ROM 上变豆腐（BUG-691）');
        expect(stack.indexOf('"DejaVu Sans"'),
            lessThan(stack.indexOf('"Hibiki Symbols"')),
            reason: '内嵌字体排在桌面符号字体之后：桌面三平台仍先命中系统字体，'
                '保持 BUG-655 修复后的现状（零回归）');
        expect(stack.indexOf('"Hibiki Symbols"'),
            lessThan(stack.indexOf('sans-serif')),
            reason: '内嵌字体必须在通用回退 sans-serif 之前，否则 Android 上'
                '轮不到它兜底');
      });

      test('[$name] @font-face 内嵌 WOFF 真含 U+2713/U+21A9/U+FE0E 字形', () {
        final String css = read(relPath);
        final RegExpMatch? m =
            RegExp(r'@font-face\s*\{[^}]*font-family:\s*"Hibiki Symbols"[^}]*'
                    r'url\("data:font/woff;base64,([A-Za-z0-9+/=]+)"\)\s*'
                    r'format\("woff"\)')
                .firstMatch(css);
        expect(m, isNotNull,
            reason: '@font-face "Hibiki Symbols"（data: URI WOFF）规则丢失');
        final Uint8List woff = base64Decode(m!.group(1)!);
        final Uint8List cmap = woffTable(woff, 'cmap');
        for (final int cp in const <int>[0x2713, 0x21A9, 0xFE0E]) {
          expect(cmapGlyphId(cmap, cp), greaterThan(0),
              reason: '内嵌字体缺 U+${cp.toRadixString(16).toUpperCase()} 字形'
                  '——制卡按钮文本标记会在无系统符号字体的 WebView 上变豆腐');
        }
      });
    });
  });
}

/// 从 WOFF1 字节流取出指定表的原始（解压后）字节。
Uint8List woffTable(Uint8List woff, String tag) {
  final ByteData d = ByteData.sublistView(woff);
  expect(String.fromCharCodes(woff.sublist(0, 4)), 'wOFF',
      reason: 'data URI 不是 WOFF1 字体');
  final int numTables = d.getUint16(12);
  for (int i = 0; i < numTables; i++) {
    final int off = 44 + i * 20;
    if (String.fromCharCodes(woff.sublist(off, off + 4)) != tag) continue;
    final int dataOff = d.getUint32(off + 4);
    final int compLen = d.getUint32(off + 8);
    final int origLen = d.getUint32(off + 12);
    final Uint8List rawBytes =
        Uint8List.sublistView(woff, dataOff, dataOff + compLen);
    if (compLen == origLen) return rawBytes;
    return Uint8List.fromList(zlib.decode(rawBytes));
  }
  fail('WOFF 内找不到表 $tag');
}

/// cmap (3,1) format-4 查询：返回码位映射到的 glyph id（0 = 未映射）。
int cmapGlyphId(Uint8List cmap, int cp) {
  final ByteData d = ByteData.sublistView(cmap);
  final int numTables = d.getUint16(2);
  int subOff = -1;
  for (int i = 0; i < numTables; i++) {
    final int rec = 4 + i * 8;
    if (d.getUint16(rec) == 3 && d.getUint16(rec + 2) == 1) {
      subOff = d.getUint32(rec + 4);
      break;
    }
  }
  expect(subOff, isNot(-1), reason: '缺 (3,1) Windows BMP cmap 子表');
  expect(d.getUint16(subOff), 4, reason: 'cmap 子表应为 format 4');
  final int segCount = d.getUint16(subOff + 6) ~/ 2;
  final int endBase = subOff + 14;
  final int startBase = endBase + segCount * 2 + 2;
  final int deltaBase = startBase + segCount * 2;
  final int rangeBase = deltaBase + segCount * 2;
  for (int i = 0; i < segCount; i++) {
    if (cp > d.getUint16(endBase + i * 2)) continue;
    final int start = d.getUint16(startBase + i * 2);
    if (cp < start) return 0;
    final int rangeOffset = d.getUint16(rangeBase + i * 2);
    if (rangeOffset == 0) {
      return (cp + d.getInt16(deltaBase + i * 2)) & 0xFFFF;
    }
    final int gid =
        d.getUint16(rangeBase + i * 2 + rangeOffset + (cp - start) * 2);
    return gid == 0 ? 0 : (gid + d.getInt16(deltaBase + i * 2)) & 0xFFFF;
  }
  return 0;
}
