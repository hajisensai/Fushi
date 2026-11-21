import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4752 source-scan guard：「用其他应用打开 / 分享」收到的 content:// URI
/// 必须先过 `OpenWithUriPolicy` 访问判定才复制，否则 Fushi 会以自己的权限替
/// 发起方读它无权读的 provider（confused deputy）。判据本身由 JVM 单测
/// `android/app/src/test/kotlin/app/fushi/reader/OpenWithUriPolicyTest.kt` 覆盖；
/// intent 接收与复制在 flutter test 里跑不了，这里钉接线。
void main() {
  // Tests run with CWD = `fushi/`.
  const String channelPath =
      'android/app/src/main/java/app/fushi/reader/OpenWithChannel.java';
  late String channel;
  setUpAll(() {
    channel = maskComments(File(channelPath).readAsStringSync());
  });

  String methodBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(0), reason: 'missing $signature');
    int depth = 0;
    for (int i = src.indexOf('{', start); i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}' && --depth == 0) return src.substring(start, i + 1);
    }
    fail('unbalanced braces after $signature');
  }

  test('offer checks access before copying the URI', () {
    final String offer = methodBody(channel, 'public static void offer(');
    final int check = offer.indexOf('mayReadOnBehalfOfSender(app, uri)');
    final int copy = offer.indexOf('copyToCache(app, uri');
    expect(check, greaterThan(0), reason: 'offer must run the access check');
    expect(
      copy,
      greaterThan(check),
      reason: 'the access check must precede the copy',
    );
    expect(offer, contains('if (!mayReadOnBehalfOfSender(app, uri)) return;'));
  });

  test('access check delegates to OpenWithUriPolicy and fails closed', () {
    final String check = methodBody(
      channel,
      'private static boolean mayReadOnBehalfOfSender(',
    );
    expect(check, contains('OpenWithUriPolicy.decide('));
    expect(check, contains('OpenWithUriPolicy.Verdict.ALLOW'));
    // 查询出错不读。
    expect(check, contains('catch (RuntimeException e)'));
    expect(
      RegExp(
        r'catch \(RuntimeException e\) \{[^}]*return false;',
      ).hasMatch(check),
      isTrue,
    );
  });

  test('provider lookup uses the authority without the user prefix', () {
    final String facts = methodBody(channel, 'ProviderFacts providerFacts(');
    expect(
      facts,
      contains('OpenWithUriPolicy.bareAuthority(uri.getAuthority())'),
    );
    expect(facts, contains('resolveContentProvider(bare, 0)'));
    expect(facts, isNot(contains('resolveContentProvider(uri.getAuthority()')));
    expect(channel, isNot(contains('isOwnProvider(')));
  });
}
