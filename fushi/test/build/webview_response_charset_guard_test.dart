import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';

import '../helpers/source_guard.dart';

/// BUG-4102 守卫：拦截响应的 `contentEncoding` 是**字符集**，必须落进 Content-Type 的
/// `charset=` 参数，不能当 HTTP `Content-Encoding` 头发出去。
///
/// 反馈 ktWIKsgWIz（zh-CN Windows）：英文 EPUB 正文里的 `’`（UTF-8 `E2 80 99`）显示成
/// 「鈥檛」「鈥�」。阅读器下发章节时写的是 `contentType: 'text/html'` +
/// `contentEncoding: 'utf-8'`（Android 的 `encoding` 参数 / iOS 的 `textEncodingName`
/// 语义），但 Windows fork 把它发成 `Content-Encoding: utf-8`、Content-Type 不带
/// charset，章节里只有 `<?xml encoding="utf-8"?>`（HTML 解析器不认）而没有
/// `<meta charset>` 时 WebView2 按系统 ANSI 码页（GBK）解码。Linux fork 的
/// `webkit_uri_scheme_request_finish` 同样只拿到裸 media type。
void main() {
  const String winDir = '../packages/flutter_inappwebview_windows/windows';
  const String linuxDir = '../packages/flutter_inappwebview_linux/linux';

  String src(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: path);
    return maskComments(f.readAsStringSync());
  }

  group('Windows fork 不把 contentEncoding 发成 Content-Encoding', () {
    for (final String name in <String>[
      'web_resource_response.cpp',
      'custom_scheme_response.cpp',
    ]) {
      test(name, () {
        final String code = src('$winDir/types/$name');
        expect(
          code.contains('L"Content-Encoding"'),
          isFalse,
          reason: 'contentEncoding 是字符集，发成 Content-Encoding 头就是 BUG-4102',
        );
        expect(
          RegExp(
            r'AppendHeader\(L"Content-Type",\s*utf8_to_wide\([^;]*contentTypeWithCharset\(',
          ).hasMatch(code),
          isTrue,
          reason: 'Content-Type 必须经 contentTypeWithCharset 带上 charset',
        );
        expect(code, contains('#include "../utils/content_type.h"'));
      });
    }
  });

  test('Linux fork 的 custom scheme 把 charset 拼进 media type', () {
    final String code = src('$linuxDir/in_app_webview/in_app_webview.cc');
    expect(
      code,
      contains(
        'contentTypeWithCharset(response->contentType, response->contentEncoding)',
      ),
    );
    expect(
      RegExp(
        r'webkit_uri_scheme_request_finish\([^;]*response->contentType\.c_str\(\)',
      ).hasMatch(code),
      isFalse,
      reason: '裸 contentType 会丢掉 charset',
    );
  });

  group('content_type.h', () {
    for (final String path in <String>[
      '$winDir/utils/content_type.h',
      '$linuxDir/utils/content_type.h',
    ]) {
      test(path, () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: path);
        final String raw = f.readAsStringSync();
        // MSVC 按系统码页（936）读源文件，插件以 /W4 /WX 编译：非 ASCII 字符触发
        // C4819 → 编译失败。注释里也不许有。
        expect(
          raw.runes.every((int r) => r < 0x80),
          isTrue,
          reason: 'C4819：头文件必须纯 ASCII',
        );
        final String code = maskComments(raw);
        expect(code, contains('contentTypeWithCharset'));
        expect(code, contains('"; charset="'));
        expect(code, contains('"charset="'), reason: '已带 charset 的类型不重复追加');
        expect(code, contains('"binary"'), reason: 'binary 约定 = 无文本字符集');
      });
    }
    test('Windows 与 Linux 的实现逐字相同', () {
      String body(String path) {
        final String s = File(path).readAsStringSync();
        return s.substring(s.indexOf('static inline'));
      }

      expect(
        body('$linuxDir/utils/content_type.h'),
        body('$winDir/utils/content_type.h'),
      );
    });
  });

  test('阅读器给 HTML / CSS / JS 声明 utf-8 字符集', () {
    final String code = src(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    );
    expect(
      RegExp(
        r"_contentEncodingForMime\(String mime\)\s*\{[^}]*mime\.startsWith\('text/'\)[^}]*return 'utf-8';",
      ).hasMatch(code),
      isTrue,
    );
    expect(code, contains('contentEncoding: _contentEncodingForMime(mime),'));
  });

  test('只有 XML 声明、无 <meta charset> 的 UTF-8 章节，下发字节仍是合法 UTF-8', () {
    // 反馈样本形态：英文 EPUB，弯引号 / 撇号，只靠 XML 声明标编码。
    const String chapter =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title>'
        '</head><body><p>If they didn’t love school… '
        '“Sure I hate school,” Miss Daisy said.</p></body></html>';
    final Uint8List out = ReaderResourceSanitizer.buildChapterHtmlBytes(
      Uint8List.fromList(utf8.encode(chapter)),
      mergedImagesHtml: '',
      headStart: '',
      headEnd: '',
    );
    // 下发时声明 charset=utf-8 的前提：字节必须是严格合法的 UTF-8。
    final String decoded = utf8.decode(out);
    expect(decoded, contains('didn’t love school…'));
    expect(decoded, contains('“Sure I hate school,”'));
    expect(
      decoded.toLowerCase().contains('<meta charset'),
      isFalse,
      reason: '样本确实不带 meta charset，解码只能靠响应头的 charset',
    );
    // 反证：同一串字节按 GBK 解就是反馈截图里的「鈥檛」——`’t` = E2 80 99 74，
    // 前两字节在 GBK 是「鈥」，后两字节是「檛」。
    final int at = _indexOf(out, utf8.encode('didn’t'));
    expect(at, greaterThanOrEqualTo(0));
    expect(out.sublist(at + 4, at + 8), <int>[0xE2, 0x80, 0x99, 0x74]);
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
