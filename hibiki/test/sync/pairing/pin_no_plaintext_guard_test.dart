import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-961 M1 §3.6 源码守卫：PIN 绝不明文出现在响应 body / 日志。
///
/// 防降级：配对协议的安全性建立在「PIN 只在 host 屏幕显示、绝不过线」之上。client
/// 只回传 HMAC proof，server 永不把 PIN 写进任何响应 body 或日志。本守卫扫描配对
/// 相关源码，禁止把 session.pin / 生成的 PIN 直接塞进 jsonEncode / _jsonResponse /
/// debugPrint / log 等出网或落盘路径。
///
/// 判据：
/// 1. lib/src/sync/ 下任何 `_jsonResponse(...)` / `jsonEncode(...)` 的实参里不得出现
///    `pin`（会话 PIN 字段）作为 map value。
/// 2. server 的 pair/v2 响应只含 sessionId / pinRequired / hostNonce（白名单）。
/// 3. PIN 不进 debugPrint / ErrorLogService 等日志调用。

String _stripComments(String src) {
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
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  test('pair/v2 响应体只含白名单字段，绝不含 PIN', () {
    final String src = _stripComments(
        File('lib/src/sync/hibiki_sync_server.dart').readAsStringSync());
    // 定位 _handlePairV2 的响应构造，断言它返回 sessionId/pinRequired/hostNonce，
    // 且整个 v2 响应 map 字面不含 "'pin'"（PIN 字段名）。
    // 定位方法定义（带签名）而非路由里的调用点——两处都出现符号名。
    final int v2Idx =
        src.indexOf('Future<shelf.Response> _handlePairV2(shelf.Request');
    expect(v2Idx, isNonNegative, reason: '应存在 _handlePairV2 方法定义');
    final int confirmIdx =
        src.indexOf('Future<shelf.Response> _handlePairConfirm(shelf.Request');
    expect(confirmIdx, isNonNegative);
    expect(confirmIdx > v2Idx, isTrue);
    // 截取 v2 创建会话方法体（到下一个方法 _handlePairConfirm 前）。
    final String v2Body = src.substring(v2Idx, confirmIdx);
    // 响应里不得把 PIN 写进 body：禁止出现 "'pin':" 作为 JSON key。
    expect(v2Body.contains("'pin':"), isFalse,
        reason: 'pair/v2 响应绝不能含 PIN 明文字段。');
    // 正向白名单：确实返回这三个字段。
    expect(v2Body.contains("'sessionId'"), isTrue);
    expect(v2Body.contains("'pinRequired'"), isTrue);
    expect(v2Body.contains("'hostNonce'"), isTrue);
  });

  test('配对相关源码不把 session.pin 写进 jsonEncode / 日志', () {
    final List<String> offenders = <String>[];
    final RegExp jsonWithPin = RegExp(
      r'(jsonEncode|_jsonResponse)\s*\([^;]*\bsession\.pin\b',
      multiLine: true,
    );
    final RegExp logWithPin = RegExp(
      r'(debugPrint|print|ErrorLogService[^;]*\.log)\s*\([^;]*\bsession\.pin\b',
      multiLine: true,
    );
    final RegExp logWithPendingPin = RegExp(
      r'(debugPrint|print|ErrorLogService[^;]*\.log)\s*\([^;]*\b_pendingPairPin\b',
      multiLine: true,
    );
    for (final File entity in Directory('lib/src/sync')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll('\\', '/');
      final String source = _stripComments(entity.readAsStringSync());
      if (jsonWithPin.hasMatch(source) ||
          logWithPin.hasMatch(source) ||
          logWithPendingPin.hasMatch(source)) {
        offenders.add(normalized);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'PIN 绝不能进响应 body 或日志（只过 HMAC proof）。违规文件: $offenders',
    );
  });

  test('协议核心不持有/不打印任何明文 PIN 出网调用', () {
    final String src = _stripComments(
        File('lib/src/sync/pairing/hibiki_pairing_protocol.dart')
            .readAsStringSync());
    // computePinProof 把 PIN 作为 HMAC key（不可逆），断言它确实经 Hmac 处理。
    expect(src.contains('Hmac(sha256'), isTrue,
        reason: 'pinProof 必须经 HMAC-SHA256 计算，PIN 不可逆地参与。');
    // 不得把 pin 直接 jsonEncode 出去。
    expect(RegExp(r'jsonEncode\s*\([^;]*\bpin\b').hasMatch(src), isFalse);
  });
}
