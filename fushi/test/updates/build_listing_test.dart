import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/build_listing.dart';
import 'package:fushi/src/updates/notice_feed.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

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

  group('localNoticeIdFor', () {
    test('same digests in any order / case give the same id', () {
      final String id = localNoticeIdFor(<String>[b], <String>[c]);
      expect(id, startsWith(kLocalNoticeIdPrefix));
      expect(localNoticeIdFor(<String>[c.toUpperCase()], <String>[b]), id);
      expect(localNoticeIdFor(<String>[b, c], const <String>[]), id);
    });

    test('a different signing key gets a new id', () {
      expect(
        localNoticeIdFor(<String>[b], <String>[b]),
        isNot(localNoticeIdFor(<String>[c], <String>[c])),
      );
    });

    test('the id does not reveal the digest', () {
      expect(localNoticeIdFor(<String>[b], <String>[b]), isNot(contains(b)));
    });
  });

  test('notice text comes from i18n and is conditional', () {
    final LocalNoticeText text = currentLocalNoticeText();
    expect(text.title, t.notice_unofficial_build_title);
    expect(text.body, t.notice_unofficial_build_body);
    expect(text.url.toString(), kOfficialReleasesUrl);
    // 条件式措辞：不对所有非官方构建一口咬定「被骗了」。
    expect(text.body, contains('If you paid'));
  });

  test(
    'startup notice is handed out once per process with the digest id',
    () async {
      final RemoteNotice? first = await takeLocalStartupNotice(
        id: () async => '${kLocalNoticeIdPrefix}abc',
      );
      expect(first, isNotNull);
      expect(first!.level, RemoteNoticeLevel.dialog);
      expect(first.id, '${kLocalNoticeIdPrefix}abc');
      expect(first.url?.scheme, 'https');
      expect(
        await takeLocalStartupNotice(
          id: () async => '${kLocalNoticeIdPrefix}x',
        ),
        isNull,
      );
    },
  );

  test('outside release Android the state is inactive', () async {
    expect(await localNoticeActive(), isFalse);
    expect(await localNoticeId(), isNull);
  });
}
