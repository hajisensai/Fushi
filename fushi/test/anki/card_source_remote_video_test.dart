import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart'
    show InterconnectSyncBackend;
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoFingerprintSource, RemoteVideoFingerprintUnavailable;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 反馈 #gCk38gT_xu：从 Anki 卡片跳回来提示「此设备没有对应来源」，但互联 host /
/// Fushi 服务端上明明有这条视频。卡片制在有原文件的设备上（链接 uid = 那台的
/// bookUid），本机库里只有远端占位、没有 VideoBookRow，只查本地库必然报没有。
void main() {
  CardSourceLink link(CardSourceKind kind, String uid) => CardSourceLink(
    kind: kind,
    uid: uid,
    sourceId: CardSourceLink.newSourceId(),
    episodeIndex: 0,
    startMs: 1000,
    endMs: 2000,
    fingerprint:
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  );

  const List<RemoteVideoInfo> videos = <RemoteVideoInfo>[
    RemoteVideoInfo(id: 'uid-a', title: 'A'),
    RemoteVideoInfo(id: 'uid-b', title: 'B'),
  ];

  test('按 uid 在 host 清单里找到卡片指向的视频', () {
    final RemoteVideoInfo? hit = findRemoteVideoForCardSource(
      videos,
      link(CardSourceKind.video, 'uid-b'),
    );
    expect(hit?.title, 'B');
  });

  test('host 清单里没有该 uid 时返回 null', () {
    expect(
      findRemoteVideoForCardSource(videos, link(CardSourceKind.video, 'nope')),
      isNull,
    );
  });

  test('BUG-3875：host 列出但没有字节可给的条目（网络流书 / .strm）不当来源', () {
    const List<RemoteVideoInfo> withStream = <RemoteVideoInfo>[
      RemoteVideoInfo(id: 'uid-web', title: 'Netflix', peerPlayable: false),
    ];
    expect(
      findRemoteVideoForCardSource(
        withStream,
        link(CardSourceKind.video, 'uid-web'),
      ),
      isNull,
    );
  });

  test('书 / 漫画链接绝不去匹配视频清单', () {
    final CardSourceLink book = CardSourceLink(
      kind: CardSourceKind.book,
      uid: 'uid-a',
      sourceId: CardSourceLink.newSourceId(),
      chapterIndex: 0,
      charOffset: 0,
      charLength: 1,
    );
    expect(findRemoteVideoForCardSource(videos, book), isNull);
  });

  group('拍板台 IFCPPprIpT：远端回跳按 host 算的指纹核验', () {
    const String a =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const String b =
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

    test('host 那份字节与卡片一致才放行', () {
      expect(
        cardSourceHostFingerprintAccepted(
          linkFingerprint: a,
          hostFingerprint: a,
        ),
        isTrue,
      );
      expect(
        cardSourceHostFingerprintAccepted(
          linkFingerprint: a,
          hostFingerprint: b,
        ),
        isFalse,
        reason: 'host 上同名 bookUid 换成了别的片子，不是这张卡的来源',
      );
    });

    test('在线内容身份（无指纹）与老 host（算不出）按 bookUid 放行', () {
      expect(
        cardSourceHostFingerprintAccepted(
          linkFingerprint: null,
          hostFingerprint: b,
        ),
        isTrue,
      );
      expect(
        cardSourceHostFingerprintAccepted(
          linkFingerprint: a,
          hostFingerprint: null,
        ),
        isTrue,
      );
    });
  });

  group('拍板台 IFCPPprIpT：matchRemoteCardSourceVideo 行为', () {
    const String a =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const String b =
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

    Future<({RemoteVideoInfo? info, bool fingerprintMismatch})> run(
      CardSourceLink link,
      _FakeFingerprints host,
    ) => matchRemoteCardSourceVideo(
      listing: Future<List<RemoteVideoInfo>>.value(videos),
      fingerprints: host,
      link: link,
    );

    test('host 字节一致：放行，并按链接的集下标请求', () async {
      final _FakeFingerprints host = _FakeFingerprints(a);
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r = await run(
        link(CardSourceKind.video, 'uid-b'),
        host,
      );
      expect(r.info?.id, 'uid-b');
      expect(r.fingerprintMismatch, isFalse);
      expect(host.calls, <String>['uid-b#0']);
      // 拍板台 left3657：回跳不让 host 当场整文件哈希，只要它已算好的。
      expect(host.waits, <bool>[false]);
    });

    test('host 上同 bookUid 换成了别的片子：不放行、报指纹不符', () async {
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r = await run(
        link(CardSourceKind.video, 'uid-b'),
        _FakeFingerprints(b),
      );
      expect(r.info, isNull);
      expect(r.fingerprintMismatch, isTrue);
    });

    test('host 还没算好（wait: false 得 null）：按 bookUid 放行、不干等', () async {
      final _FakeFingerprints host = _FakeFingerprints.pending(a);
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r = await run(
        link(CardSourceKind.video, 'uid-a'),
        host,
      );
      expect(r.info?.id, 'uid-a');
      expect(r.fingerprintMismatch, isFalse);
      expect(host.waits, <bool>[false]);
    });

    test('老 host 算不出（null）：按 bookUid 放行', () async {
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r = await run(
        link(CardSourceKind.video, 'uid-a'),
        _FakeFingerprints(null),
      );
      expect(r.info?.id, 'uid-a');
      expect(r.fingerprintMismatch, isFalse);
    });

    test('清单里没有：不去请求指纹，按没有来源', () async {
      final _FakeFingerprints host = _FakeFingerprints(a);
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r = await run(
        link(CardSourceKind.video, 'nope'),
        host,
      );
      expect(r.info, isNull);
      expect(r.fingerprintMismatch, isFalse);
      expect(host.calls, isEmpty);
    });

    test('BUG-3490 无指纹的在线内容链接：不请求 host 指纹直接放行', () async {
      const List<RemoteVideoInfo> online = <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'video/stream/x', title: 'X'),
      ];
      final _FakeFingerprints host = _FakeFingerprints(b);
      final ({RemoteVideoInfo? info, bool fingerprintMismatch}) r =
          await matchRemoteCardSourceVideo(
            listing: Future<List<RemoteVideoInfo>>.value(online),
            fingerprints: host,
            link: CardSourceLink(
              kind: CardSourceKind.video,
              uid: 'video/stream/x',
              sourceId: CardSourceLink.newSourceId(),
              episodeIndex: 0,
              startMs: 1000,
              endMs: 2000,
            ),
          );
      expect(r.info?.id, 'video/stream/x');
      expect(host.calls, isEmpty);
    });

    test('BUG-4782：新 host 担保不了字节时抛出、不当老 host 放行', () async {
      await expectLater(
        run(
          link(CardSourceKind.video, 'uid-a'),
          _FakeFingerprints.unavailable(),
        ),
        throwsA(isA<RemoteVideoFingerprintUnavailable>()),
      );
    });

    test('host 网络失败原样抛出（由调用方记日志按没有来源）', () async {
      await expectLater(
        run(link(CardSourceKind.video, 'uid-a'), _FakeFingerprints.failing()),
        throwsA(isA<SocketException>()),
      );
    });
  });

  test('接线：远程播放互联 host 制卡时向 host 取指纹写进链接', () {
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    expect(
      mining,
      contains('final RemoteVideoFingerprintSource source => source'),
    );
    expect(mining, contains('hostFingerprints.fetchRemoteVideoFingerprint('));
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync();
    expect(router, contains('matchRemoteCardSourceVideo('));
    // 反馈 7gkdbfCXQ0 / BUG-4710：等 host 算指纹（几 GB 的片子首次几十秒）与等清单
    // 合成同一段 work，套可取消的进度反馈；只有「缓存新鲜且不用核验指纹」才直取。
    expect(router, contains('cached && link.fingerprint == null'));
    expect(router, contains('>(navigator: navigator, work: work);'));
    // 回跳去向由 [decideCardSourceVideoAction] 决定（行为见下方「回跳去向」组）。
    expect(router, contains('decideCardSourceVideoAction(local: local'));
  });

  group('回跳去向：本机核验 × host 查找', () {
    final RemoteCardSourceVideo found = (
      info: const RemoteVideoInfo(id: 'uid-a', title: 'A'),
      client: InterconnectSyncBackend.withProbe(
        (String url, String token) async => true,
      ),
    );
    const RemoteCardSourceLookup notFound = (
      value: null,
      cancelled: false,
      fingerprintMismatch: false,
      hostUnreadable: false,
    );
    const RemoteCardSourceLookup hostMismatch = (
      value: null,
      cancelled: false,
      fingerprintMismatch: true,
      hostUnreadable: false,
    );
    const RemoteCardSourceLookup cancelled = (
      value: null,
      cancelled: true,
      fingerprintMismatch: false,
      hostUnreadable: false,
    );
    const RemoteCardSourceLookup hostUnreadable = (
      value: null,
      cancelled: false,
      fingerprintMismatch: false,
      hostUnreadable: true,
    );
    final RemoteCardSourceLookup hostHas = (
      value: found,
      cancelled: false,
      fingerprintMismatch: false,
      hostUnreadable: false,
    );

    final List<
      (
        CardSourceLocalVideoCheck,
        RemoteCardSourceLookup?,
        CardSourceVideoAction,
      )
    >
    table =
        <
          (
            CardSourceLocalVideoCheck,
            RemoteCardSourceLookup?,
            CardSourceVideoAction,
          )
        >[
          (
            CardSourceLocalVideoCheck.verified,
            null,
            CardSourceVideoAction.openLocal,
          ),
          // 本机字节不符：host 有同一份字节就在线播，不直接判死。
          (
            CardSourceLocalVideoCheck.mismatch,
            hostHas,
            CardSourceVideoAction.openRemote,
          ),
          (
            CardSourceLocalVideoCheck.mismatch,
            hostMismatch,
            CardSourceVideoAction.fingerprintMismatch,
          ),
          (
            CardSourceLocalVideoCheck.mismatch,
            notFound,
            CardSourceVideoAction.fingerprintMismatch,
          ),
          (
            CardSourceLocalVideoCheck.unreadable,
            hostHas,
            CardSourceVideoAction.openRemote,
          ),
          (
            CardSourceLocalVideoCheck.unreadable,
            hostMismatch,
            CardSourceVideoAction.fingerprintMismatch,
          ),
          (
            CardSourceLocalVideoCheck.unreadable,
            notFound,
            CardSourceVideoAction.localRequired,
          ),
          (
            CardSourceLocalVideoCheck.absent,
            hostHas,
            CardSourceVideoAction.openRemote,
          ),
          (
            CardSourceLocalVideoCheck.absent,
            hostMismatch,
            CardSourceVideoAction.fingerprintMismatch,
          ),
          (
            CardSourceLocalVideoCheck.absent,
            notFound,
            CardSourceVideoAction.mediaMissing,
          ),
          // 拍板台 left3657：host 清单里有、却读不了文件 → 专门提示，不说「没有来源」；
          // 本机那份也读不了时同样（让用户「先下载」也下不成）；字节不符仍优先。
          (
            CardSourceLocalVideoCheck.absent,
            hostUnreadable,
            CardSourceVideoAction.hostUnreadable,
          ),
          (
            CardSourceLocalVideoCheck.unreadable,
            hostUnreadable,
            CardSourceVideoAction.hostUnreadable,
          ),
          (
            CardSourceLocalVideoCheck.mismatch,
            hostUnreadable,
            CardSourceVideoAction.fingerprintMismatch,
          ),
          // 等 host 时取消：不论本机如何都静默放弃，不弹提示。
          (
            CardSourceLocalVideoCheck.mismatch,
            cancelled,
            CardSourceVideoAction.cancelled,
          ),
          (
            CardSourceLocalVideoCheck.absent,
            cancelled,
            CardSourceVideoAction.cancelled,
          ),
        ];

    for (final (
          CardSourceLocalVideoCheck local,
          RemoteCardSourceLookup? lookup,
          CardSourceVideoAction expected,
        )
        in table) {
      final String host = switch (lookup) {
        null => '未查 host',
        final RemoteCardSourceLookup l when l.cancelled => '取消',
        final RemoteCardSourceLookup l when l.value != null => 'host 有',
        final RemoteCardSourceLookup l when l.fingerprintMismatch =>
          'host 字节不符',
        final RemoteCardSourceLookup l when l.hostUnreadable => 'host 读不了',
        _ => 'host 没有',
      };
      test('本机 ${local.name} + $host → ${expected.name}', () {
        expect(
          decideCardSourceVideoAction(local: local, lookup: lookup),
          expected,
        );
      });
    }
  });

  group('本机同 uid 视频的字节核验', () {
    late Directory dir;
    late File file;
    const String good =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final VideoSourceFingerprint hashes = VideoSourceFingerprint(
      compute: (String absolutePath, FileStat stat) async => good,
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('card_source_local_');
      file = File('${dir.path}/ep.mkv')..writeAsBytesSync(<int>[1, 2, 3]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<CardSourceLocalVideoCheck> check(
      String? path,
      String? fingerprint,
    ) => checkLocalCardSourceVideo(
      videoPath: path,
      linkFingerprint: fingerprint,
      fingerprints: hashes,
    );

    test('本机没有这一行 → absent', () async {
      expect(await check(null, good), CardSourceLocalVideoCheck.absent);
    });

    test('字节一致 → verified；不符 → mismatch', () async {
      expect(await check(file.path, good), CardSourceLocalVideoCheck.verified);
      expect(
        await check(file.path, 'f' * 64),
        CardSourceLocalVideoCheck.mismatch,
      );
    });

    test('BUG-3490 无指纹的链接：不比字节直接放行', () async {
      expect(
        await check('${dir.path}/missing.mkv', null),
        CardSourceLocalVideoCheck.verified,
      );
    });

    test('文件不在 / 是在线地址 → unreadable', () async {
      expect(
        await check('${dir.path}/missing.mkv', good),
        CardSourceLocalVideoCheck.unreadable,
      );
      expect(
        await check('https://host/ep.mkv', good),
        CardSourceLocalVideoCheck.unreadable,
      );
    });
  });

  test('接线：本地没有时走 host 清单，远端复习不按本地指纹判死', () {
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync();
    expect(router, contains('await resolveRemoteCardSourceVideo('));
    expect(router, contains('VideoFushiPage.neutralizedRemote('));
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(page, contains('_isRemote ? null : widget.sourceReview'));
  });
}

class _FakeFingerprints implements RemoteVideoFingerprintSource {
  _FakeFingerprints(this.fingerprint)
    : fail = false,
      unverifiable = false,
      pending = false;
  _FakeFingerprints.failing()
    : fingerprint = null,
      fail = true,
      unverifiable = false,
      pending = false;
  _FakeFingerprints.unavailable()
    : fingerprint = null,
      fail = false,
      unverifiable = true,
      pending = false;

  /// 新 host 还没算好：`wait: false` 时得 null，`wait: true` 才给 [fingerprint]。
  _FakeFingerprints.pending(this.fingerprint)
    : fail = false,
      unverifiable = false,
      pending = true;

  final String? fingerprint;
  final bool fail;
  final bool unverifiable;
  final bool pending;
  final List<String> calls = <String>[];
  final List<bool> waits = <bool>[];

  @override
  Future<String?> fetchRemoteVideoFingerprint(
    String id, {
    int episodeIndex = 0,
    bool wait = true,
  }) async {
    calls.add('$id#$episodeIndex');
    waits.add(wait);
    if (fail) throw const SocketException('host unreachable');
    if (unverifiable) {
      throw RemoteVideoFingerprintUnavailable(id, 'unreadable');
    }
    if (pending && !wait) return null;
    return fingerprint;
  }
}
