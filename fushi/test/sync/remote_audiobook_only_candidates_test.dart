import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

/// BUG-2505：互联「只下到书、没下到有声书」之后，远端卡按「本端已有」被
/// [dedupeRemoteBooks] 整条藏掉，与书配对的 host 有声书又不是 standalone 占位卡，
/// 书架上没有任何补拉入口。[remoteAudiobookOnlyCandidates] 是把这批条目单独挑出来
/// 喂给本地书卡菜单的纯函数落点，本测试直接验它的判据。
void main() {
  RemoteBookInfo book(String title, {bool hasAudiobook = true}) =>
      RemoteBookInfo(
        title: title,
        hasContent: true,
        hasAudiobook: hasAudiobook,
      );

  group('remoteAudiobookOnlyCandidates', () {
    test('本端有书、无有声书、对端有配套有声书 → 入选，按本端 bookKey 索引', () {
      final String key = sanitizeTtuFilename('共有的书');
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[book('共有的书')],
        localBookKeys: <String>{key},
        localAudiobookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(got.keys, <String>[key]);
      expect(got[key]!.title, '共有的书');
    });

    test('本端已有有声书 → 不入选（已经补过了，菜单不再露入口）', () {
      final String key = sanitizeTtuFilename('共有的书');
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[book('共有的书')],
        localBookKeys: <String>{key},
        localAudiobookKeys: <String>{key},
        keyOf: sanitizeTtuFilename,
      );
      expect(got, isEmpty);
    });

    test('对端没有配套有声书 → 不入选（无东西可拉）', () {
      final String key = sanitizeTtuFilename('共有的书');
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[book('共有的书', hasAudiobook: false)],
        localBookKeys: <String>{key},
        localAudiobookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(got, isEmpty);
    });

    test('本端没有这本书 → 不入选（那是远端独有书，走远端卡整书下载）', () {
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[book('只在远端的书')],
        localBookKeys: const <String>{},
        localAudiobookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(got, isEmpty);
    });

    test('去重键与 dedupeRemoteBooks 同口径：按 sanitize(title) 对本端 bookKey', () {
      // BUG-2274 形状：标题含冒号，本端 bookKey 是 sanitize 后的键。
      const String title = 'Love, Death and Robots: The Official Anthology';
      final String key = sanitizeTtuFilename(title);
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[book(title)],
        localBookKeys: <String>{key},
        localAudiobookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(got.keys, <String>[key]);
      // 与去重互补：入选的条目正是被去重藏掉的那条。
      expect(
        dedupeRemoteBooks(
          remote: <RemoteBookInfo>[book(title)],
          localBookKeys: <String>{key},
          keyOf: sanitizeTtuFilename,
        ),
        isEmpty,
      );
    });

    test('同 key 多条远端书只取首条', () {
      final String key = sanitizeTtuFilename('同名书');
      final Map<String, RemoteBookInfo> got = remoteAudiobookOnlyCandidates(
        remote: <RemoteBookInfo>[
          const RemoteBookInfo(
            title: '同名书',
            hasContent: true,
            hasAudiobook: true,
            bookKey: 'a',
          ),
          const RemoteBookInfo(
            title: '同名书',
            hasContent: true,
            hasAudiobook: true,
            bookKey: 'b',
          ),
        ],
        localBookKeys: <String>{key},
        localAudiobookKeys: const <String>{},
        keyOf: sanitizeTtuFilename,
      );
      expect(got, hasLength(1));
      expect(got[key]!.bookKey, 'a');
    });
  });
}
