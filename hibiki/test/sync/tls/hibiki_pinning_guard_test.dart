import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-961 M0 设计稿 2.7 源码守卫：lib/src/sync/ 下禁止出现无条件放行证书
/// 的 badCertificateCallback / onBadCertificate（写松 = 自以为加密、实则比
/// 明文更危险）。pinned client 的回调只能做指纹相等才 true。

/// 字符级剥除 Dart 注释，避免把文档/行/块注释里的示例文字误判为违规。
String stripDartComments(String src) {
  final StringBuffer out = StringBuffer();
  final int n = src.length;
  int i = 0;
  while (i < n) {
    final String c = src[i];
    final String next = i + 1 < n ? src[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < n && !(src[i] == '*' && i + 1 < n && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    if (c == '\\' || c == '"') {
      final String quote = c;
      out.write(c);
      i++;
      while (i < n) {
        final String s = src[i];
        out.write(s);
        if (s == '\\' && i + 1 < n) {
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
        i++;
        if (s == quote) break;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  test('stripDartComments 保留真实代码、剥除注释', () {
    expect(
      stripDartComments('/// badCertificateCallback = (a, b, c) => true;\n'),
      isNot(contains('=> true')),
    );
    expect(
      stripDartComments('x => true; // ok'),
      contains('=> true'),
    );
  });

  test('lib/src/sync/ 下不得无条件 badCertificateCallback/onBadCertificate => true',
      () {
    final RegExp unconditionalBad = RegExp(
      r'(badCertificateCallback|onBadCertificate)\b[^;{]*=>\s*true\b',
      multiLine: true,
    );
    final RegExp blockReturnTrue = RegExp(
      r'(badCertificateCallback|onBadCertificate)\b[^;{]*\{\s*return\s+true\s*;\s*\}',
      multiLine: true,
    );

    final List<String> offenders = <String>[];
    for (final File entity in Directory('lib/src/sync')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll('\\', '/');
      final String source = stripDartComments(entity.readAsStringSync());
      if (unconditionalBad.hasMatch(source) ||
          blockReturnTrue.hasMatch(source)) {
        offenders.add(normalized);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'TLS 自签证书只能经指纹钉扎接受；badCertificateCallback 绝不无条件 '
          'return true（防降级裸奔）。违规文件：\$offenders',
    );
  });

  test('pinning client 回调确实经过指纹比较（正向守卫，防被改空）', () {
    final String source =
        File('lib/src/sync/tls/hibiki_pinning_http.dart').readAsStringSync();
    expect(source.contains('certificateMatchesFingerprint'), isTrue,
        reason: 'pinned client 必须用指纹比较判据。');
    expect(source.contains('badCertificateCallback'), isTrue);
    final int cbIdx = source.indexOf('badCertificateCallback =');
    expect(cbIdx, isNonNegative);
    final String after = source.substring(cbIdx, cbIdx + 200);
    expect(after.contains('certificateMatchesFingerprint'), isTrue,
        reason: 'badCertificateCallback 必须委托给指纹比较，不得无条件放行。');
  });
}
