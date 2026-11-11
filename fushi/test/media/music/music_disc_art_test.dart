import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_cover.dart';

const String _release = '4b9a8200-7eb4-445f-8cd6-4c67eefb1f5e';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('disc_art_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('isMusicDiscArtFileName', () {
    test('认明确命名的盘面图', () {
      for (final String n in <String>[
        'Disc.webp',
        'disc1.jpg',
        'CD 2.png',
        'disc_02.jpeg',
        'Medium.jpg',
        'BD.jpg',
        'label.png',
      ]) {
        expect(isMusicDiscArtFileName(n), isTrue, reason: n);
      }
    });

    test('编号扫描、封面、非图片一律不认', () {
      for (final String n in <String>[
        '01.jpg',
        'scan_03.jpg',
        'cover.jpg',
        'SakuraTrickCharacterCdTokutenCard1.jpg',
        'disc.flac',
        'cdtext.jpg',
      ]) {
        expect(isMusicDiscArtFileName(n), isFalse, reason: n);
      }
    });
  });

  test('本地：在专辑目录下两层里找，取排序后的第一张', () async {
    final Directory scans = Directory(p.join(tmp.path, 'Scans', 'BDBox'))
      ..createSync(recursive: true);
    File(p.join(scans.path, 'Disc2.webp')).writeAsBytesSync(<int>[1]);
    File(p.join(scans.path, 'Disc1.webp')).writeAsBytesSync(<int>[1]);
    File(p.join(tmp.path, '01.jpg')).writeAsBytesSync(<int>[1]);
    expect(
      await findLocalMusicDiscArt(tmp.path),
      p.join(scans.path, 'Disc1.webp'),
    );
    expect(await findLocalMusicDiscArt(p.join(tmp.path, 'nope')), isNull);
  });

  test('pickMusicDiscArtImage 只挑 Medium，已审核优先', () {
    const MusicCoverImage front = MusicCoverImage(
      imageUrl: 'f',
      types: <String>['Front'],
      front: true,
    );
    const MusicCoverImage pending = MusicCoverImage(
      imageUrl: 'm0',
      types: <String>['Medium'],
      approved: false,
    );
    const MusicCoverImage medium = MusicCoverImage(
      imageUrl: 'm1',
      types: <String>['Medium'],
    );
    expect(pickMusicDiscArtImage(<MusicCoverImage>[front]), isNull);
    expect(
      pickMusicDiscArtImage(<MusicCoverImage>[front, pending, medium]),
      same(medium),
    );
    expect(
      pickMusicDiscArtImage(<MusicCoverImage>[front, pending]),
      same(pending),
    );
  });

  group('MusicDiscArtService', () {
    MusicDiscArtService service({
      required Future<List<MusicCoverImage>> Function(String) fetch,
      DateTime Function()? clock,
      List<String>? downloads,
      MusicDiscScanDetector? detect,
    }) => MusicDiscArtService(
      cacheDirectory: () async => Directory(p.join(tmp.path, 'cache')),
      fetchCovers: fetch,
      download: (String url) async {
        downloads?.add(url);
        return <int>[0xFF, 0xD8, 0xFF];
      },
      detectScan: detect ?? (_) => throw StateError('no scans expected'),
      clock: clock,
    );

    test('本地盘面图优先，不问 CAA', () async {
      File(p.join(tmp.path, 'Disc.webp')).writeAsBytesSync(<int>[1]);
      int fetches = 0;
      final String? art = await service(
        fetch: (_) async {
          fetches++;
          return const <MusicCoverImage>[];
        },
      ).resolve(albumUid: 'a', albumDir: tmp.path, mbReleaseId: _release);
      expect(art, p.join(tmp.path, 'Disc.webp'));
      expect(fetches, 0);
    });

    test('CAA 有 Medium：下到缓存目录，下次直接命中', () async {
      final List<String> downloads = <String>[];
      Future<List<MusicCoverImage>> fetch(String _) async =>
          const <MusicCoverImage>[
            MusicCoverImage(
              imageUrl: 'https://x/full.jpg',
              thumbnails: <String, String>{'500': 'https://x/500.jpg'},
              types: <String>['Medium'],
            ),
          ];
      final String? art = await service(
        fetch: fetch,
        downloads: downloads,
      ).resolve(albumUid: 'a', mbReleaseId: _release);
      expect(art, p.join(tmp.path, 'cache', '$_release.jpg'));
      expect(File(art!).existsSync(), isTrue);
      expect(downloads, <String>['https://x/500.jpg']);

      // 新的服务实例（= 下次启动）：不再联网。
      final String? again = await service(
        fetch: (_) => throw StateError('should hit cache'),
      ).resolve(albumUid: 'a', mbReleaseId: _release);
      expect(again, art);
    });

    test('CAA 没有 Medium：记 .none，期限内不再问，过期重查', () async {
      int fetches = 0;
      Future<List<MusicCoverImage>> fetch(String _) async {
        fetches++;
        return const <MusicCoverImage>[
          MusicCoverImage(imageUrl: 'f', types: <String>['Front']),
        ];
      }

      expect(
        await service(
          fetch: fetch,
        ).resolve(albumUid: 'a', mbReleaseId: _release),
        isNull,
      );
      expect(
        File(p.join(tmp.path, 'cache', '$_release.none')).existsSync(),
        isTrue,
      );
      expect(
        await service(
          fetch: fetch,
        ).resolve(albumUid: 'a', mbReleaseId: _release),
        isNull,
      );
      expect(fetches, 1);
      await service(
        fetch: fetch,
        clock: () => DateTime.now().add(kMusicDiscArtNegativeTtl * 2),
      ).resolve(albumUid: 'a', mbReleaseId: _release);
      expect(fetches, 2);
    });

    test('网络失败不记 .none', () async {
      final String? art = await service(
        fetch: (_) async => throw const SocketException('offline'),
      ).resolve(albumUid: 'a', mbReleaseId: _release);
      expect(art, isNull);
      expect(
        File(p.join(tmp.path, 'cache', '$_release.none')).existsSync(),
        isFalse,
      );
    });

    test('编号扫描交给识别器，结论按图片清单缓存', () async {
      final File a = File(p.join(tmp.path, '01.jpg'))
        ..writeAsBytesSync(<int>[1]);
      final File b = File(p.join(tmp.path, '02.jpg'))
        ..writeAsBytesSync(<int>[2]);
      final List<List<String>> calls = <List<String>>[];
      Future<String?> detect(List<String> paths) async {
        calls.add(paths);
        return paths.last;
      }

      Future<String?> run() => service(
        fetch: (_) => throw StateError('scan hit, no CAA'),
        detect: detect,
      ).resolve(albumUid: 'a', albumDir: tmp.path, mbReleaseId: _release);

      expect(await run(), b.path);
      expect(calls, <List<String>>[
        <String>[a.path, b.path],
      ]);
      // 新实例（= 下次启动）：清单没变，读 local_scans.json，不再解码。
      expect(await run(), b.path);
      expect(calls, hasLength(1));
      // 加了一张：清单变了，重新识别。
      File(p.join(tmp.path, '03.jpg')).writeAsBytesSync(<int>[3]);
      await run();
      expect(calls, hasLength(2));
    });

    test('识别器失败不写缓存，退到 CAA', () async {
      File(p.join(tmp.path, '01.jpg')).writeAsBytesSync(<int>[1]);
      int fetches = 0;
      final String? art = await service(
        fetch: (_) async {
          fetches++;
          return const <MusicCoverImage>[];
        },
        detect: (_) async => throw StateError('native missing'),
      ).resolve(albumUid: 'a', albumDir: tmp.path, mbReleaseId: _release);
      expect(art, isNull);
      expect(fetches, 1);
      expect(
        File(p.join(tmp.path, 'cache', 'local_scans.json')).existsSync(),
        isFalse,
      );
    });

    test('标签没有发行 ID 时用自动对号的；标签有就不问', () async {
      final List<String> asked = <String>[];
      Future<List<MusicCoverImage>> fetch(String id) async {
        asked.add(id);
        return const <MusicCoverImage>[];
      }

      int matcherCalls = 0;
      Future<String?> matched() async {
        matcherCalls++;
        return _release.toUpperCase();
      }

      await service(
        fetch: fetch,
      ).resolve(albumUid: 'a', matchedRelease: matched);
      expect(asked, <String>[_release]);
      final MusicDiscArtService svc = service(fetch: fetch);
      await svc.resolve(
        albumUid: 'b',
        mbReleaseId: _release,
        matchedRelease: matched,
      );
      expect(matcherCalls, 1);
      // invalidate 后重查。
      svc.invalidate('b');
      await svc.resolve(albumUid: 'b', matchedRelease: matched);
      expect(matcherCalls, 2);
    });

    test('没有发行 ID 也没有本地图：null', () async {
      expect(
        await service(
          fetch: (_) => throw StateError('no id, no fetch'),
        ).resolve(albumUid: 'a', albumDir: tmp.path),
        isNull,
      );
    });
  });

  test('musicLocalAlbumDirOf 不碰远程路径', () {
    expect(musicLocalAlbumDirOf('sftp://h/a/1.flac'), isNull);
    expect(musicLocalAlbumDirOf(null), isNull);
    expect(
      musicLocalAlbumDirOf(p.join('D:', 'm', 'a', '1.flac')),
      p.join('D:', 'm', 'a'),
    );
  });

  testWidgets('有盘面图画盒子 + 盘且不出界，没有只画方形封面', (WidgetTester tester) async {
    final File disc = File(p.join(tmp.path, 'Disc.png'))
      ..writeAsBytesSync(_onePixelPng);
    final MusicDiscArtService svc = MusicDiscArtService(
      cacheDirectory: () async => Directory(p.join(tmp.path, 'cache')),
      fetchCovers: (_) async => const <MusicCoverImage>[],
    );
    Widget card(String uid, String? trackPath) => MaterialApp(
      // Center：否则 home 的紧约束把格子撑成整屏。
      home: Center(
        child: SizedBox.square(
          dimension: 200,
          child: MusicDiscArtOrCover(
            albumUid: uid,
            trackPath: trackPath,
            service: svc,
            cover: const ColoredBox(
              key: ValueKey<String>('fallback'),
              color: Colors.pink,
            ),
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(card('with', p.join(tmp.path, '01.flac')));
      await svc.resolve(albumUid: 'with');
    });
    await tester.pump();
    expect(find.byType(MusicDiscFace), findsOneWidget);
    // 盒子（封面）也在，且盒子、盘都在 200×200 的格子里。
    final Finder box = find.byKey(const ValueKey<String>('fallback'));
    expect(box, findsOneWidget);
    final Rect cell = tester.getRect(find.byType(MusicDiscArtOrCover));
    final Rect caseRect = tester.getRect(box);
    final Rect discRect = tester.getRect(find.byType(MusicDiscFace));
    expect(caseRect.width, closeTo(200 * kMusicDiscCaseFraction, 0.01));
    expect(discRect.right, greaterThan(caseRect.right));
    for (final Rect r in <Rect>[caseRect, discRect]) {
      expect(
        cell.contains(r.topLeft) &&
            cell.contains(r.bottomRight - const Offset(0.01, 0.01)),
        isTrue,
        reason: '$r',
      );
    }
    expect(disc.existsSync(), isTrue);

    await tester.runAsync(() async {
      await tester.pumpWidget(card('without', null));
      await svc.resolve(albumUid: 'without');
    });
    await tester.pump();
    expect(find.byType(MusicDiscFace), findsNothing);
    expect(find.byKey(const ValueKey<String>('fallback')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('fallback'))),
      const Size(200, 200),
    );
  });

  test('悬停时盘仍不出界', () {
    const double peek = kMusicDiscCaseFraction + kMusicDiscPeekHover;
    expect(peek, lessThanOrEqualTo(1));
    expect(kMusicDiscDiameterFraction, lessThanOrEqualTo(1));
  });
}

/// 1×1 透明 PNG。
const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
