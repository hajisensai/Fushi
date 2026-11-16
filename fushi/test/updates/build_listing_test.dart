import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/updates/build_listing.dart';
import 'package:fushi/src/updates/notice_feed.dart';

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

void main() {
  final String a = 'a' * 64;
  final String b = 'b' * 64;
  final String c = 'c' * 64;
  final Set<String> listed = <String>{listedDigestHash(a)};

  group('localNoticeApplies', () {
    test('listed digest in both sources: no notice', () {
      expect(
        localNoticeApplies(<String>[a], <String>[a], listed: listed),
        isFalse,
      );
      expect(
        localNoticeApplies(<String>[a], <String>[], listed: listed),
        isFalse,
      );
      expect(
        localNoticeApplies(<String>[], <String>[a], listed: listed),
        isFalse,
      );
    });

    test('unknown digest: notice', () {
      expect(
        localNoticeApplies(<String>[b], <String>[b], listed: listed),
        isTrue,
      );
      expect(
        localNoticeApplies(<String>[b], <String>[], listed: listed),
        isTrue,
      );
    });

    test('sources with no shared digest: notice', () {
      expect(
        localNoticeApplies(<String>[a], <String>[c], listed: listed),
        isTrue,
      );
    });

    test('both sources empty: no notice', () {
      expect(
        localNoticeApplies(const <String>[], const <String>[], listed: listed),
        isFalse,
      );
      expect(localNoticeApplies(const <String>[], const <String>[]), isFalse);
    });

    test('digest case does not matter', () {
      expect(isListedDigest(a.toUpperCase(), listed: listed), isTrue);
    });

    test('built-in set is populated and rejects arbitrary digests', () {
      expect(kListedDigestHashes, isNotEmpty);
      for (final String h in kListedDigestHashes) {
        expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      expect(isListedDigest(b), isFalse);
    });
  });

  group('local text', () {
    test('round trip', () {
      for (final String s in <String>['', 'abc', '中文 · 混排 123', 'x' * 300]) {
        expect(decodeLocalText(encodeLocalText(s)), s);
      }
      expect(encodeLocalText('abc'), isNot(contains('abc')));
    });

    test('zh text decodes to the expected content', () {
      final LocalNoticeText zh = localNoticeText('zh-CN');
      expect(
        _sha(zh.title),
        '7014f2844301e7c2b57ff424d4048709c4624dcdb741b434e42fb40253c73479',
      );
      expect(
        _sha(zh.body),
        '4674e1f2bfde5baa1b3e1dc2bc8bb4ce139a24ff9891f5a5e47a0c83b56acdee',
      );
      expect(localNoticeText('zh-HK').title, zh.title);
    });

    test('other locales use en text', () {
      final LocalNoticeText en = localNoticeText('ja');
      expect(
        _sha(en.title),
        'ab03f1f7b6af59c41af824b01705ed6b0c42d81be7d877e670b5e1bc89fa3c84',
      );
      expect(
        _sha(en.body),
        '5f7a8881206cbdc248c3fef997a6b9b39ced5b1c670fa7bbe0a821405f9c458d',
      );
      expect(
        _sha(en.url.toString()),
        '2c63d77a2a652c765fc6a1f2a70365f19f6efc5b8d2fce2f281f53ee98dd3eeb',
      );
      expect(en.url.scheme, 'https');
    });
  });

  test('startup notice is handed out once per process', () async {
    final RemoteNotice? first = await takeLocalStartupNotice(
      active: () async => true,
    );
    expect(first, isNotNull);
    expect(first!.level, RemoteNoticeLevel.dialog);
    expect(first.id, kLocalNoticeId);
    expect(first.url?.scheme, 'https');
    expect(await takeLocalStartupNotice(active: () async => true), isNull);
  });

  test('outside release Android the state is inactive', () async {
    expect(await localNoticeActive(), isFalse);
  });
}
