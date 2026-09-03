import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「文本钩子不再自称实验性功能」，防回归。
///
/// 与 [video_experimental_markers_guard_test] 同一形状、同一理由：视频页当初也挂着
/// 一条「实验性功能」横幅，功能稳定后按用户要求整条移除；文本钩子这条是同款遗留
/// （`_buildExperimentalBanner` + `Icons.science_outlined` + i18n
/// `texthooker_experimental_banner`），现一并删除。
///
/// 守的是**用户可见文案**，不是实现细节：横幅方法、调用点、烧瓶图标、i18n key 四处
/// 缺一都会让这句话以某种形式回到界面上。
///
/// 用源码扫描而非整页 widget pump：texthooker 页依赖完整 AppModel + DB +
/// FushiFocusRoot + native hook 会话，整页启动成本高且脆弱；这条不变式的正面就是
/// 「源码里没有这四样东西」，源码扫描足以守住（与 video_experimental_markers_guard
/// 同范式）。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

void main() {
  group('文本钩子不再有实验性提示横幅', () {
    final String pageSrc =
        _read('lib/src/pages/implementations/texthooker_page.dart');
    final String baseI18n = _read('lib/i18n/strings.i18n.json');
    final String zhI18n = _read('lib/i18n/strings_zh-CN.i18n.json');

    test('页面不再渲染实验性横幅（方法与调用均已删除）', () {
      expect(pageSrc.contains('_buildExperimentalBanner'), isFalse,
          reason: '实验性横幅方法/调用应已删除');
      expect(pageSrc.contains('texthooker_experimental_banner'), isFalse,
          reason: '页面不应再引用 texthooker_experimental_banner 文案');
      expect(pageSrc.contains('Icons.science_outlined'), isFalse,
          reason: '实验性烧瓶图标应随横幅一并删除');
    });

    test('i18n key texthooker_experimental_banner 已从源文件删除', () {
      expect(baseI18n.contains('texthooker_experimental_banner'), isFalse,
          reason: '英文源文件不应再有该 key');
      expect(zhI18n.contains('texthooker_experimental_banner'), isFalse,
          reason: '中文源文件不应再有该 key');
    });

    test('页面正文仍在（确认上面三条不是因为整个文件读空而假绿）', () {
      // 反空转：横幅没了，但页面本体必须还在。
      expect(pageSrc.contains('class TexthookerPage'), isTrue);
      expect(pageSrc.length, greaterThan(1000));
    });
  });
}
