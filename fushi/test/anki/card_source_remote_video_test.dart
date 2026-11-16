import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi_anki/fushi_anki.dart';
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

  test('接线：远程播放互联 host 制卡时向 host 取指纹写进链接', () {
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    expect(mining, contains('remoteClient is RemoteVideoFingerprintSource'));
    expect(mining, contains('hostFingerprints.fetchRemoteVideoFingerprint('));
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync();
    expect(router, contains('backend.fetchRemoteVideoFingerprint('));
    // 本地同 uid 但字节对不上时不直接判死，继续去 host 找同一份字节。
    expect(router, matches(RegExp(r'localMismatch = true;\s+video = null;')));
  });

  test('接线：本地没有时走 host 清单，远端复习不按本地指纹判死', () {
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync();
    expect(router, contains('resolveRemoteCardSourceVideo(app, ref, link)'));
    expect(router, contains('VideoFushiPage.neutralizedRemote('));
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(page, contains('_isRemote ? null : widget.sourceReview'));
  });
}
