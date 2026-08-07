import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind;

/// 互联 wire format 黄金守卫（TODO-2120 的前置安全网）。
///
/// **为什么需要这个文件**——互联 DTO 的 `toJson` 里有 **30+ 处条件省略 key**：
/// `if (tags.isNotEmpty)`、`if (progressPercent > 0)`、`if (kind != MediaKind.epub)`、
/// `if (episodes.length > 1)`、`if (hasDisplayCover)` …… 这些不是随手写的优化，而是
/// **活的线上协议**：老 host / 老 client 靠「键不存在」来判断「没有这个东西」，
/// 一旦某个键从「不写」变成「写 null / false / 空数组」，对端的解析分支就换了一条路。
///
/// 而此前只有 3 处（`kind` / `tags` / `collection`）被测试锁住，其余 30 来处**一旦被
/// 改成无条件写出，全套测试照样全绿**。这意味着：
/// - 任何人给 DTO 加字段、或把手写 `toJson` 换成 codegen（json_serializable 默认
///   `includeIfNull: true`，且根本表达不了 `isNotEmpty` / `> 0` / `!= epub` 这类
///   **基于值**的条件），都会静默改变 wire，且没有任何测试会红。
///
/// 本文件把「最小实例写出哪些键」和「最大实例写出哪些键」**逐 DTO 精确钉死**。
/// 加字段时这里必然变红——那正是要的：强制作者显式声明新字段的省略语义，而不是
/// 让它悄悄溜进协议。
///
/// 断言的主体是 **key 集合**，不是具体的值——值语义由各域自己的测试负责。
/// 但**值的 JSON 类型**是 wire 协议的一部分，所以另有一组「类型锁」（见文件末尾
/// `wire 值类型锁`）：key 集合不变、类型悄悄变（`int` 写成 `String`、`bool` 写成
/// `int` 之类）同样会让对端的 `as num?` / `== true` 解析静默失效，而只锁 key 集合
/// 的断言对此**全绿**。类型锁把每个 wire 键的 JSON 类型逐个钉死，补上这个洞。
void main() {
  /// 断言 [json] 的键集合恰好是 [expected]（多一个少一个都红）。
  void expectKeys(
    Map<String, Object?> json,
    Set<String> expected, {
    required String what,
  }) {
    expect(
      json.keys.toSet(),
      expected,
      reason: '$what 的 wire key 集合变了。若这是有意的协议变更，请连同老 host/老 '
          'client 的兼容影响一起评估后再改本断言；若只是新加字段，请先想清楚它该在'
          '什么条件下省略。',
    );
  }

  group('RemoteBookInfo', () {
    test('最小实例：只写 title / hasContent（其余全部省略）', () {
      expectKeys(
        const RemoteBookInfo(title: 'T', hasContent: false).toJson(),
        <String>{'title', 'hasContent'},
        what: 'RemoteBookInfo 最小实例',
      );
    });

    test('最大实例：全部可选键都出现', () {
      final Map<String, Object?> json = RemoteBookInfo(
        title: 'T',
        hasContent: true,
        bookKey: 'k',
        hasEmbeddedCover: true,
        coverUrl: 'http://h/c.png',
        coverPath: '/local/c.png',
        hasAudiobook: true,
        tags: const <String>['a'],
        tagsAddedAt: const <String, int>{'a': 1},
        tagTombstones: const <String, int>{'b': 2},
        collection: const RemoteCollectionMembership(
          collectionName: 'C',
          collectionType: 'book',
          sortIndex: 0,
        ),
        progressPercent: 50,
        progressUpdatedAtMs: 123,
        kind: MediaKind.srt,
      ).toJson();
      expectKeys(
        json,
        <String>{
          'title',
          'bookKey',
          'hasContent',
          'hasCover',
          'coverUrl',
          'hasAudiobook',
          'tags',
          'tagsAddedAt',
          'tagTombstones',
          'collection',
          'progressPercent',
          'progressUpdatedAtMs',
          'kind',
        },
        what: 'RemoteBookInfo 最大实例',
      );
      // coverPath 是 host 本地绝对路径：fromJson 读、toJson **永不写**（不外泄）。
      expect(json.containsKey('coverPath'), isFalse,
          reason: 'host 本地路径绝不能出现在 wire 上');
    });

    test('epub 是默认 kind，不写 kind 键（旧 wire 字节不变）', () {
      expect(
        const RemoteBookInfo(title: 'T', hasContent: true).toJson(),
        isNot(contains('kind')),
      );
      expect(
        const RemoteBookInfo(title: 'T', hasContent: true, kind: MediaKind.epub)
            .toJson(),
        isNot(contains('kind')),
      );
    });

    test('hasCover 写的是派生语义（coverPath/coverUrl 也算有封面）', () {
      // wire key 叫 hasCover，值取的却是 hasDisplayCover（= 内嵌封面 或 有 coverUrl
      // 或 有 coverPath）。Dart 侧字段名是 hasEmbeddedCover——同名不同义，改这里前
      // 先读 DTO 里的注释。
      expect(
        const RemoteBookInfo(
          title: 'T',
          hasContent: true,
          coverPath: '/local/c.png',
        ).toJson()['hasCover'],
        isTrue,
        reason: '只有本地封面路径时，wire 上仍应告诉对端「这本书有封面」',
      );
    });

    test('progress 为 0 时不写（0 与「没有进度」在 wire 上同义）', () {
      final Map<String, Object?> json = const RemoteBookInfo(
        title: 'T',
        hasContent: true,
        progressPercent: 0,
        progressUpdatedAtMs: 0,
      ).toJson();
      expect(json.containsKey('progressPercent'), isFalse);
      expect(json.containsKey('progressUpdatedAtMs'), isFalse);
    });
  });

  group('RemoteVideoInfo', () {
    test('最小实例：只写 id / title / hasSubtitle', () {
      expectKeys(
        const RemoteVideoInfo(id: 'video/x', title: 'T').toJson(),
        <String>{'id', 'title', 'hasSubtitle'},
        what: 'RemoteVideoInfo 最小实例',
      );
    });

    test('最大实例：全部可选键都出现', () {
      final Map<String, Object?> json = RemoteVideoInfo(
        id: 'video/x',
        title: 'T',
        sizeBytes: 1,
        hasSubtitle: true,
        subtitleFileName: 's.srt',
        embeddedSubtitleTracks: const <RemoteVideoEmbeddedSubtitleTrack>[
          RemoteVideoEmbeddedSubtitleTrack(streamIndex: 0, codec: 'subrip'),
        ],
        durationMs: 2,
        hasCover: true,
        coverUrl: 'http://h/c.png',
        coverPath: '/local/c.png',
        positionMs: 3,
        positionUpdatedAtMs: 4,
        delayMs: 5,
        episodes: const <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'e0'),
          RemoteVideoEpisode(index: 1, title: 'e1'),
        ],
        currentEpisode: 1,
        tags: const <String>['a'],
        tagsAddedAt: const <String, int>{'a': 1},
        tagTombstones: const <String, int>{'b': 2},
        collection: const RemoteCollectionMembership(
          collectionName: 'C',
          collectionType: 'video',
          sortIndex: 0,
        ),
      ).toJson();
      expectKeys(
        json,
        <String>{
          'id',
          'title',
          'sizeBytes',
          'hasSubtitle',
          'subtitleFileName',
          'embeddedSubtitleTracks',
          'durationMs',
          'hasCover',
          'coverUrl',
          'positionMs',
          'positionUpdatedAtMs',
          'delayMs',
          'episodes',
          'currentEpisode',
          'tags',
          'tagsAddedAt',
          'tagTombstones',
          'collection',
        },
        what: 'RemoteVideoInfo 最大实例',
      );
      expect(json.containsKey('coverPath'), isFalse,
          reason: 'host 本地路径绝不能出现在 wire 上');
    });

    test('单视频（episodes<=1）不写 episodes / currentEpisode（旧 client 兼容）', () {
      final Map<String, Object?> single = const RemoteVideoInfo(
        id: 'video/x',
        title: 'T',
        episodes: <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'e')
        ],
        currentEpisode: 0,
      ).toJson();
      expect(single.containsKey('episodes'), isFalse,
          reason: '只有一集时 wire 上不应出现播放列表键');
      expect(single.containsKey('currentEpisode'), isFalse);
    });

    test('多集但 currentEpisode 为 0 时不写 currentEpisode（旧 client 兼容）', () {
      // 上一条只覆盖了外层 `episodes.length > 1` 这道门（单视频整块不写）。内层还有
      // 一道**独立**的 `currentEpisode > 0`：多集播放列表停在第 0 集时，wire 上同样
      // 不写这个键——旧 client 读不到就按 0 处理，语义相同、字节更少。少了这条用例，
      // 把内层条件删成无条件写照样全绿（旧 client 会凭空多收到一个 currentEpisode:0）。
      final Map<String, Object?> json = const RemoteVideoInfo(
        id: 'video/x',
        title: 'T',
        episodes: <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'e0'),
          RemoteVideoEpisode(index: 1, title: 'e1'),
        ],
        currentEpisode: 0,
      ).toJson();
      expect(json.containsKey('episodes'), isTrue, reason: '多集必须写播放列表键（外层门已开）');
      expect(json.containsKey('currentEpisode'), isFalse,
          reason: 'currentEpisode 为 0 时不写键——0 与「没有当前集」在 wire 上同义');
    });

    test('无内封字幕轨时不写 embeddedSubtitleTracks', () {
      expect(
        const RemoteVideoInfo(id: 'video/x', title: 'T').toJson(),
        isNot(contains('embeddedSubtitleTracks')),
      );
    });

    test('delayMs 为 0 不写；非 0（含负值）要写', () {
      expect(
        const RemoteVideoInfo(id: 'v', title: 'T', delayMs: 0).toJson(),
        isNot(contains('delayMs')),
      );
      expect(
        const RemoteVideoInfo(id: 'v', title: 'T', delayMs: -250)
            .toJson()['delayMs'],
        -250,
        reason: '负 delay 是合法的字幕提前量，不能被当成「无值」省掉',
      );
    });
  });

  group('RemoteVideoEmbeddedSubtitleTrack', () {
    test('最小实例：streamIndex / codec / isText', () {
      expectKeys(
        const RemoteVideoEmbeddedSubtitleTrack(streamIndex: 0, codec: 'subrip')
            .toJson(),
        <String>{'streamIndex', 'codec', 'isText'},
        what: '内封字幕轨最小实例',
      );
    });

    test('最大实例', () {
      expectKeys(
        const RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 1,
          codec: 'ass',
          language: 'jpn',
          title: 'JP',
          isText: false,
          url: 'http://h/s',
          fileName: 's.ass',
        ).toJson(),
        <String>{
          'streamIndex',
          'codec',
          'language',
          'title',
          'isText',
          'url',
          'fileName'
        },
        what: '内封字幕轨最大实例',
      );
    });

    test('isText 缺失解成 true（反向默认，不是 false）', () {
      // 老 host 不下发 isText → 必须当文本轨处理，否则字幕全被当图形轨丢掉。
      expect(
        RemoteVideoEmbeddedSubtitleTrack.fromJson(
          const <String, Object?>{'streamIndex': 0, 'codec': 'subrip'},
        ).isText,
        isTrue,
      );
      expect(
        RemoteVideoEmbeddedSubtitleTrack.fromJson(
          const <String, Object?>{
            'streamIndex': 0,
            'codec': 'hdmv_pgs',
            'isText': false,
          },
        ).isText,
        isFalse,
      );
    });
  });

  group('RemoteAudiobookInfo', () {
    test('uid 为空时省略（旧 host 不下发此字段）', () {
      expectKeys(
        const RemoteAudiobookInfo(bookKey: 'k').toJson(),
        <String>{'bookKey', 'title'},
        what: 'RemoteAudiobookInfo 无 uid',
      );
      expectKeys(
        const RemoteAudiobookInfo(bookKey: 'k', uid: 'u', title: 't').toJson(),
        <String>{'bookKey', 'uid', 'title'},
        what: 'RemoteAudiobookInfo 全字段',
      );
    });

    test('身份键：srt-backed 用 bookKey，standalone 用 uid', () {
      expect(const RemoteAudiobookInfo(bookKey: 'k', uid: 'u').identity, 'k');
      expect(const RemoteAudiobookInfo(bookKey: '', uid: 'u').identity, 'u');
      expect(const RemoteAudiobookInfo(bookKey: '').isStandaloneSrt, isTrue);
    });
  });

  group('RemoteActivityEvent', () {
    test('最小实例：5 个必填键', () {
      expectKeys(
        const RemoteActivityEvent(
          eventType: 'read',
          mediaType: 'book',
          title: 'T',
          dateKey: '2026-07-28',
          timestampMs: 1,
        ).toJson(),
        <String>{'eventType', 'mediaType', 'title', 'dateKey', 'timestampMs'},
        what: 'RemoteActivityEvent 最小实例',
      );
    });

    test('最大实例：可选三键出现', () {
      expectKeys(
        const RemoteActivityEvent(
          eventType: 'read',
          mediaType: 'book',
          title: 'T',
          dateKey: '2026-07-28',
          timestampMs: 1,
          mediaKey: 'k',
          durationMs: 2,
          charsDelta: 3,
        ).toJson(),
        <String>{
          'eventType',
          'mediaType',
          'title',
          'dateKey',
          'timestampMs',
          'mediaKey',
          'durationMs',
          'charsDelta'
        },
        what: 'RemoteActivityEvent 最大实例',
      );
    });
  });

  group('固定键集的 DTO（无条件省略）', () {
    test('RemoteCollectionMembership：wire key 是 name，不是 collectionName', () {
      expectKeys(
        const RemoteCollectionMembership(
          collectionName: 'C',
          collectionType: 'book',
          sortIndex: 3,
        ).toJson(),
        <String>{'name', 'collectionType', 'sortIndex'},
        what: 'RemoteCollectionMembership',
      );
    });

    test('RemoteBookProgress', () {
      expectKeys(
        const RemoteBookProgress(
          sectionIndex: 0,
          normCharOffset: 0,
          charOffset: -1,
          updatedAtMs: 0,
        ).toJson(),
        <String>{'sectionIndex', 'normCharOffset', 'charOffset', 'updatedAtMs'},
        what: 'RemoteBookProgress',
      );
    });

    test('RemoteBookProgress.charOffset 缺失默认 -1（不是 0）', () {
      // -1 = 「host 没有精确字符偏移」，0 是合法的「在开头」。混淆会让恢复跳到开头。
      expect(
        RemoteBookProgress.fromJson(const <String, Object?>{}).charOffset,
        -1,
      );
    });

    test('RemoteDictionaryInfo / RemoteLocalAudioInfo / RemoteVideoEpisode',
        () {
      expectKeys(
        const RemoteDictionaryInfo(name: 'n', type: 't').toJson(),
        <String>{'name', 'type'},
        what: 'RemoteDictionaryInfo',
      );
      expectKeys(
        const RemoteLocalAudioInfo(displayName: 'd').toJson(),
        <String>{'displayName'},
        what: 'RemoteLocalAudioInfo',
      );
      expectKeys(
        const RemoteVideoEpisode(index: 0, title: 't').toJson(),
        <String>{'index', 'title'},
        what: 'RemoteVideoEpisode',
      );
    });
  });

  group('round-trip：省略的键在 fromJson 侧还原成等价缺省', () {
    test('RemoteBookInfo 最小实例 round-trip 不产生新键', () {
      const RemoteBookInfo original =
          RemoteBookInfo(title: 'T', hasContent: true);
      final RemoteBookInfo back = RemoteBookInfo.fromJson(original.toJson());
      expect(back.toJson(), original.toJson(),
          reason: 'toJson→fromJson→toJson 必须是幂等的，否则同一本书在两端会写出不同 wire');
    });

    test('RemoteVideoInfo 最小实例 round-trip 不产生新键', () {
      const RemoteVideoInfo original = RemoteVideoInfo(id: 'v', title: 'T');
      final RemoteVideoInfo back = RemoteVideoInfo.fromJson(original.toJson());
      expect(back.toJson(), original.toJson());
    });

    test('RemoteVideoInfo 播放列表 round-trip 保住 episodes/currentEpisode', () {
      const RemoteVideoInfo original = RemoteVideoInfo(
        id: 'v',
        title: 'T',
        episodes: <RemoteVideoEpisode>[
          RemoteVideoEpisode(index: 0, title: 'a'),
          RemoteVideoEpisode(index: 1, title: 'b'),
        ],
        currentEpisode: 1,
      );
      final RemoteVideoInfo back = RemoteVideoInfo.fromJson(original.toJson());
      expect(back.episodes.length, 2);
      expect(back.currentEpisode, 1);
      expect(back.toJson(), original.toJson());
    });
  });

  group('wire 值类型锁', () {
    /// 断言 [json] 里每个键的**运行时 JSON 类型**符合 [types]；覆盖的键必须与
    /// [json] 完全一致（漏掉一个键就说明类型锁没跟上 key 集合的变化）。
    void expectWireTypes(
      Map<String, Object?> json,
      Map<String, Type> types, {
      required String what,
    }) {
      expect(json.keys.toSet(), types.keys.toSet(),
          reason: '$what：类型锁覆盖的键与实际写出的键不一致，请同步补齐');
      types.forEach((String key, Type expected) {
        final Object? value = json[key];
        final bool ok = switch (expected) {
          const (int) => value is int,
          const (bool) => value is bool,
          const (String) => value is String,
          const (List<Object?>) => value is List,
          const (Map<String, Object?>) => value is Map,
          _ => false,
        };
        expect(ok, isTrue,
            reason: '$what 的 wire 键 `$key` 类型变了：期望 $expected，实际写出 '
                '${value.runtimeType}（值 $value）。对端按固定类型解析'
                '（`as num?` / `== true` 之类），类型一变解析就静默失效——'
                '这是**协议变更**，不是实现细节。');
      });
    }

    test('RemoteBookInfo 最大实例的每个 wire 键类型', () {
      expectWireTypes(
        RemoteBookInfo(
          title: 'T',
          hasContent: true,
          bookKey: 'k',
          hasEmbeddedCover: true,
          coverUrl: 'http://h/c.png',
          hasAudiobook: true,
          tags: const <String>['a'],
          tagsAddedAt: const <String, int>{'a': 1},
          tagTombstones: const <String, int>{'b': 2},
          collection: const RemoteCollectionMembership(
            collectionName: 'C',
            collectionType: 'book',
            sortIndex: 0,
          ),
          progressPercent: 50,
          progressUpdatedAtMs: 123,
          kind: MediaKind.srt,
        ).toJson(),
        const <String, Type>{
          'title': String,
          'bookKey': String,
          'hasContent': bool,
          'hasCover': bool,
          'coverUrl': String,
          'hasAudiobook': bool,
          'tags': List<Object?>,
          'tagsAddedAt': Map<String, Object?>,
          'tagTombstones': Map<String, Object?>,
          'collection': Map<String, Object?>,
          'progressPercent': int,
          'progressUpdatedAtMs': int,
          'kind': String,
        },
        what: 'RemoteBookInfo',
      );
    });

    test('RemoteVideoInfo 最大实例的每个 wire 键类型', () {
      expectWireTypes(
        RemoteVideoInfo(
          id: 'video/x',
          title: 'T',
          sizeBytes: 1,
          hasSubtitle: true,
          subtitleFileName: 's.srt',
          embeddedSubtitleTracks: const <RemoteVideoEmbeddedSubtitleTrack>[
            RemoteVideoEmbeddedSubtitleTrack(streamIndex: 0, codec: 'subrip'),
          ],
          durationMs: 2,
          hasCover: true,
          coverUrl: 'http://h/c.png',
          positionMs: 3,
          positionUpdatedAtMs: 4,
          delayMs: 5,
          episodes: const <RemoteVideoEpisode>[
            RemoteVideoEpisode(index: 0, title: 'e0'),
            RemoteVideoEpisode(index: 1, title: 'e1'),
          ],
          currentEpisode: 1,
          tags: const <String>['a'],
          tagsAddedAt: const <String, int>{'a': 1},
          tagTombstones: const <String, int>{'b': 2},
          collection: const RemoteCollectionMembership(
            collectionName: 'C',
            collectionType: 'video',
            sortIndex: 0,
          ),
        ).toJson(),
        const <String, Type>{
          'id': String,
          'title': String,
          'sizeBytes': int,
          'hasSubtitle': bool,
          'subtitleFileName': String,
          'embeddedSubtitleTracks': List<Object?>,
          'durationMs': int,
          'hasCover': bool,
          'coverUrl': String,
          'positionMs': int,
          'positionUpdatedAtMs': int,
          'delayMs': int,
          'episodes': List<Object?>,
          'currentEpisode': int,
          'tags': List<Object?>,
          'tagsAddedAt': Map<String, Object?>,
          'tagTombstones': Map<String, Object?>,
          'collection': Map<String, Object?>,
        },
        what: 'RemoteVideoInfo',
      );
    });

    test('内封字幕轨 / 合集归属 / 分集 / 进度的每个 wire 键类型', () {
      expectWireTypes(
        const RemoteVideoEmbeddedSubtitleTrack(
          streamIndex: 1,
          codec: 'ass',
          language: 'jpn',
          title: 'JP',
          isText: false,
          url: 'http://h/s',
          fileName: 's.ass',
        ).toJson(),
        const <String, Type>{
          'streamIndex': int,
          'codec': String,
          'language': String,
          'title': String,
          'isText': bool,
          'url': String,
          'fileName': String,
        },
        what: 'RemoteVideoEmbeddedSubtitleTrack',
      );
      expectWireTypes(
        const RemoteCollectionMembership(
          collectionName: 'C',
          collectionType: 'book',
          sortIndex: 3,
        ).toJson(),
        const <String, Type>{
          'name': String,
          'collectionType': String,
          'sortIndex': int,
        },
        what: 'RemoteCollectionMembership',
      );
      expectWireTypes(
        const RemoteVideoEpisode(index: 0, title: 't').toJson(),
        const <String, Type>{'index': int, 'title': String},
        what: 'RemoteVideoEpisode',
      );
      expectWireTypes(
        const RemoteBookProgress(
          sectionIndex: 0,
          normCharOffset: 0,
          charOffset: -1,
          updatedAtMs: 0,
        ).toJson(),
        const <String, Type>{
          'sectionIndex': int,
          'normCharOffset': int,
          'charOffset': int,
          'updatedAtMs': int,
        },
        what: 'RemoteBookProgress',
      );
    });

    test('RemoteActivityEvent 最大实例的每个 wire 键类型', () {
      expectWireTypes(
        const RemoteActivityEvent(
          eventType: 'read',
          mediaType: 'book',
          title: 'T',
          dateKey: '2026-07-28',
          timestampMs: 1,
          mediaKey: 'k',
          durationMs: 2,
          charsDelta: 3,
        ).toJson(),
        const <String, Type>{
          'eventType': String,
          'mediaType': String,
          'title': String,
          'dateKey': String,
          'timestampMs': int,
          'mediaKey': String,
          'durationMs': int,
          'charsDelta': int,
        },
        what: 'RemoteActivityEvent',
      );
    });

    test('RemoteAudiobookInfo / RemoteDictionaryInfo / RemoteLocalAudioInfo',
        () {
      expectWireTypes(
        const RemoteAudiobookInfo(bookKey: 'k', uid: 'u', title: 't').toJson(),
        const <String, Type>{'bookKey': String, 'uid': String, 'title': String},
        what: 'RemoteAudiobookInfo',
      );
      expectWireTypes(
        const RemoteDictionaryInfo(name: 'n', type: 't').toJson(),
        const <String, Type>{'name': String, 'type': String},
        what: 'RemoteDictionaryInfo',
      );
      expectWireTypes(
        const RemoteLocalAudioInfo(displayName: 'd').toJson(),
        const <String, Type>{'displayName': String},
        what: 'RemoteLocalAudioInfo',
      );
    });
  });
}
