import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-738 守卫：查词弹窗宿主 HTML 必须在任何外链 `<script>` 之前显式声明 UTF-8。
///
/// 根因：Android 从 `file:///android_asset/...` 加载 popup.html（无 HTTP charset 头），
/// `file://` 是 opaque origin，外链 `<script>` 的字符编码不继承文档默认编码而回退到
/// legacy windows-1252。popup.js 里制卡按钮的文本字形 `'✓↩︎'`（UTF-8 E2 9C 93 …）被按
/// 1252 解码成乱码 `âœ"`（用户报「制卡后 +号图标变乱码」）。audio/favorite 是 SVG 不受影响，
/// 故只有制卡按钮乱码。fork 的 `defaultTextEncodingName` 默认 UTF-8 只作用于文档本体，
/// 救不了 opaque-origin 外链脚本。
///
/// 修复：宿主 HTML 顶部 `<meta charset="utf-8">`（显式声明文档编码 → 外链脚本随之按 UTF-8
/// 解码）+ 每个 `<script src>` 直接带 `charset="utf-8"`（钉死第二层）。global_lookup_host.html
/// 一直有 charset 故从不复现，本守卫锁 popup.html / definition.html / global_lookup_host.html
/// 三个宿主都不回退。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  const List<String> popupHosts = <String>[
    'assets/popup/popup.html',
    'assets/popup/definition.html',
    'assets/popup/global_lookup_host.html',
  ];

  final RegExp charsetMeta =
      RegExp(r'<meta\s+charset\s*=\s*"utf-8"', caseSensitive: false);
  final RegExp firstScript = RegExp(r'<script\b', caseSensitive: false);

  for (final String host in popupHosts) {
    group('[$host] BUG-738 UTF-8 编码声明', () {
      late final String html;
      setUpAll(() => html = File(host).readAsStringSync());

      test('含 <meta charset="utf-8">', () {
        expect(charsetMeta.hasMatch(html), isTrue,
            reason: '$host 缺 <meta charset="utf-8">；file:// 加载时外链脚本会按 '
                'windows-1252 解码，popup.js 的 ✓ 变乱码 âœ"（BUG-738）');
      });

      test('<meta charset> 出现在第一个 <script> 之前（否则对外链脚本无效）', () {
        // 先剥掉 HTML 注释——本文件的说明注释里出现了字面 "<script>"，不能算真标签。
        final String noComments =
            html.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
        final int metaAt = noComments.indexOf(charsetMeta);
        final int scriptAt = noComments.indexOf(firstScript);
        // 无外链脚本的宿主天然不受影响，跳过顺序断言。
        if (scriptAt < 0) return;
        expect(metaAt, greaterThanOrEqualTo(0));
        expect(metaAt, lessThan(scriptAt),
            reason: 'charset 声明必须在外链 <script> 之前，才能决定其解码编码');
      });

      test('每个外链 <script src> 直接带 charset="utf-8"（第二层钉死）', () {
        final RegExp externalScript =
            RegExp(r'<script\b[^>]*\bsrc\s*=', caseSensitive: false);
        for (final RegExpMatch m in externalScript.allMatches(html)) {
          final String tag =
              html.substring(m.start, html.indexOf('>', m.start) + 1);
          expect(
              RegExp(r'charset\s*=\s*"utf-8"', caseSensitive: false)
                  .hasMatch(tag),
              isTrue,
              reason: '$host 的外链脚本标签缺 charset="utf-8"：$tag');
        }
      });
    });
  }
}
