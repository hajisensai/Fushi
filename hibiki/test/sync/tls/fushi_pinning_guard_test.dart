import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// TODO-961 M0 设计稿 2.7 源码守卫：lib/src/sync/ 下禁止出现无条件放行证书
/// 的 badCertificateCallback / onBadCertificate（写松 = 自以为加密、实则比
/// 明文更危险）。pinned client 的回调只能做指纹相等才 true。

/// 剥除 Dart 注释，避免把文档/行/块注释里的示例文字误判为违规。
///
/// TODO-2477：改为委托共享词法掩码 [maskComments]。原先这里手写的字符级状态机
/// 有一处真实缺陷——判串起点写成 `c == '\' || c == '"'`，把**反斜杠**当成了
/// 单引号，于是单引号串（Dart 源码里的绝大多数串）根本没被保护，串里的 `//`
/// 会把该行剩余部分连同真实代码一起抹掉。共享版按 Dart 词法正确识别单/双引号、
/// 三引号、`r` 原始串与转义。
String stripDartComments(String src) => maskComments(src);

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
        File('lib/src/sync/tls/fushi_pinning_http.dart').readAsStringSync();
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
