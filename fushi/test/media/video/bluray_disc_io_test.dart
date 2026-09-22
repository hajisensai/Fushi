// 在真实磁盘上铺一张最小的盘，走完「认盘 → 读播放列表 → 选标题 → 解析成可播源」
// 整条 IO 链。上面几个测试文件测的都是纯函数，这条测的是它们之间的接缝：目录布局、
// 文件名大小写、CLPI 与 MPLS 的配对、片段缺失时的降级。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

void main() {
  late Directory temp;
  late String discRoot;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fushi_bd_');
    discRoot = p.join(temp.path, '某部电影 [BDMV]');
    for (final String dir in <String>[
      'PLAYLIST',
      'CLIPINF',
      'STREAM',
      'META',
    ]) {
      Directory(p.join(discRoot, 'BDMV', dir)).createSync(recursive: true);
    }
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄占用；临时目录留给系统清。
    }
  });

  void writePlaylist(String id, Uint8List bytes) => File(
    p.join(discRoot, 'BDMV', 'PLAYLIST', '$id.mpls'),
  ).writeAsBytesSync(bytes);

  void writeClipInfo(String id, Uint8List bytes) => File(
    p.join(discRoot, 'BDMV', 'CLIPINF', '$id.clpi'),
  ).writeAsBytesSync(bytes);

  void writeStream(String id, {int bytes = 4096}) => File(
    p.join(discRoot, 'BDMV', 'STREAM', '$id.m2ts'),
  ).writeAsBytesSync(Uint8List(bytes));

  /// 一条把整段 `00001` 从头用到尾的播放列表 + 配套 CLPI + 码流。
  void writeWholeClipTitle(
    String playlistId, {
    required String clipId,
    required int seconds,
    int startTicks = 45000 * 4,
    int streamBytes = 4096,
  }) {
    writePlaylist(
      playlistId,
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clipId,
            inTimeTicks: startTicks,
            outTimeTicks: startTicks + 45000 * seconds,
          ),
        ],
        marks: <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: startTicks),
        ],
      ),
    );
    writeClipInfo(
      clipId,
      buildClpiFixture(
        presentationStartTicks: startTicks,
        presentationEndTicks: startTicks + 45000 * seconds,
      ),
    );
    writeStream(clipId, bytes: streamBytes);
  }

  test('认盘：盘根与 BDMV 目录本身都认，别的目录不认', () async {
    writeWholeClipTitle('00001', clipId: '00001', seconds: 3600);

    expect(blurayDiscRootForDirectory(discRoot), p.normalize(discRoot));
    expect(
      blurayDiscRootForDirectory(p.join(discRoot, 'BDMV')),
      p.normalize(discRoot),
    );
    expect(blurayDiscRootForDirectory(temp.path), isNull);
    expect(
      blurayDiscRootForDirectory(p.join(discRoot, 'BDMV', 'STREAM')),
      isNull,
    );
  });

  test('电影盘：读出一条正片，花絮与菜单片不进来', () async {
    writeWholeClipTitle('00001', clipId: '00001', seconds: 7200); // 正片
    writeWholeClipTitle('00002', clipId: '00002', seconds: 150); // 预告
    writeWholeClipTitle('00800', clipId: '00800', seconds: 20); // 菜单循环

    final BlurayDisc disc = (await readBlurayDisc(discRoot))!;

    // 三条都解析成功、都留在 playlists 里，只是没被选成标题。
    expect(disc.playlists, hasLength(3));
    expect(disc.titles, hasLength(1));
    expect(disc.titles.single.playlist.id, '00001');
    expect(disc.titles.single.name, '某部电影 [BDMV]'); // 没有 META 时用目录名
    expect(disc.mainTitleIndex, 0);
  });

  test('MV 盘：各曲全进，标题按编号顺序编号', () async {
    for (int i = 1; i <= 4; i++) {
      writeWholeClipTitle(
        i.toString().padLeft(5, '0'),
        clipId: i.toString().padLeft(5, '0'),
        seconds: 240 + i * 10,
      );
    }

    final BlurayDisc disc = (await readBlurayDisc(discRoot))!;

    expect(disc.titles.map((BlurayTitle t) => t.name), <String>[
      '某部电影 [BDMV] - 01',
      '某部电影 [BDMV] - 02',
      '某部电影 [BDMV] - 03',
      '某部电影 [BDMV] - 04',
    ]);
    expect(disc.titles.last.isMainFeature, isTrue);
  });

  test('META 里的盘内标题优先于目录名', () async {
    writeWholeClipTitle('00001', clipId: '00001', seconds: 3600);
    Directory(p.join(discRoot, 'BDMV', 'META', 'DL')).createSync();
    File(
      p.join(discRoot, 'BDMV', 'META', 'DL', 'bdmt_jpn.xml'),
    ).writeAsStringSync(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<disclib xmlns:di="urn:BDA:bdmv;discinfo"><di:discinfo><di:title>'
      '<di:name>君の名は。</di:name></di:title></di:discinfo></disclib>',
    );

    final BlurayDisc disc = (await readBlurayDisc(discRoot))!;

    expect(disc.name, '君の名は。');
    expect(disc.titles.single.name, '君の名は。');
  });

  test('引用的码流不在盘上：这条不算可播放标题', () async {
    writeWholeClipTitle('00001', clipId: '00001', seconds: 3600);
    // 第二条播放列表引用一段根本不存在的码流。
    writePlaylist(
      '00002',
      buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00099',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 3600,
          ),
        ],
      ),
    );

    final BlurayDisc disc = (await readBlurayDisc(discRoot))!;

    expect(disc.titles.map((BlurayTitle t) => t.playlist.id), <String>[
      '00001',
    ]);
  });

  test('一张盘都没有：readBlurayDisc 返回 null 而不是抛', () async {
    expect(await readBlurayDisc(temp.path), isNull);
    // 有 BDMV/PLAYLIST 但里面是空的
    expect(await readBlurayDisc(discRoot), isNull);
  });

  test('坏掉的 mpls 被跳过，好的照常读出来', () async {
    writeWholeClipTitle('00001', clipId: '00001', seconds: 3600);
    File(
      p.join(discRoot, 'BDMV', 'PLAYLIST', '00002.mpls'),
    ).writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));

    final BlurayDisc disc = (await readBlurayDisc(discRoot))!;

    expect(disc.playlists, hasLength(1));
    expect(disc.titles, hasLength(1));
  });

  group('resolveBluraySource', () {
    test('整段用满 → 交真实 m2ts 路径', () async {
      writeWholeClipTitle('00001', clipId: '00001', seconds: 3600);

      final BluraySource source = (await resolveBluraySource(
        p.join(discRoot, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ))!;

      expect(source.isPlainFile, isTrue);
      expect(source.uri, p.join(discRoot, 'BDMV', 'STREAM', '00001.m2ts'));
      expect(File(source.uri).existsSync(), isTrue);
      expect(source.duration, const Duration(hours: 1));
      expect(source.chapters, <Duration>[Duration.zero]);
    });

    test('多段 → EDL 拼接，路径全部带长度前缀', () async {
      writePlaylist(
        '00001',
        buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00011',
              inTimeTicks: 45000 * 4,
              outTimeTicks: 45000 * 2404,
            ),
            FixturePlayItem(
              clipId: '00012',
              inTimeTicks: 45000 * 4,
              outTimeTicks: 45000 * 2404,
            ),
          ],
          marks: const <FixtureMark>[
            FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 4),
            FixtureMark(playItemIndex: 1, timestampTicks: 45000 * 4),
          ],
        ),
      );
      for (final String clipId in <String>['00011', '00012']) {
        writeClipInfo(
          clipId,
          buildClpiFixture(
            presentationStartTicks: 45000 * 4,
            presentationEndTicks: 45000 * 2404,
          ),
        );
        writeStream(clipId);
      }

      final BluraySource source = (await resolveBluraySource(
        p.join(discRoot, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ))!;

      expect(source.isPlainFile, isFalse);
      expect(source.uri, startsWith('edl://'));
      // 两段都整段用满，起止仍显式写出：段长不交给 lavf 估计。
      expect(
        source.uri,
        'edl://'
        '${encodeEdlField(p.join(discRoot, 'BDMV', 'STREAM', '00011.m2ts'))}'
        ',4.000000,2400.000000;'
        '${encodeEdlField(p.join(discRoot, 'BDMV', 'STREAM', '00012.m2ts'))}'
        ',4.000000,2400.000000;',
      );
      expect(source.duration, const Duration(minutes: 80));
      // 抽封面/探容器指向真实的第一段。
      expect(
        source.primaryStreamPath,
        p.join(discRoot, 'BDMV', 'STREAM', '00011.m2ts'),
      );
      expect(source.chapters, <Duration>[
        Duration.zero,
        const Duration(minutes: 40),
      ]);
    });

    test('不是 mpls / 文件不存在 → null', () async {
      expect(await resolveBluraySource(p.join(discRoot, '不存在.mkv')), isNull);
      expect(
        await resolveBluraySource(
          p.join(discRoot, 'BDMV', 'PLAYLIST', '09999.mpls'),
        ),
        isNull,
      );
    });
  });

  test('probeBlurayPlaylistFacts 把码流大小一起算上', () async {
    writeWholeClipTitle(
      '00001',
      clipId: '00001',
      seconds: 3600,
      streamBytes: 8192,
    );

    final VideoProbeFacts facts = await probeBlurayPlaylistFacts(
      p.join(discRoot, 'BDMV', 'PLAYLIST', '00001.mpls'),
    );

    expect(facts.durationMs, const Duration(hours: 1).inMilliseconds);
    expect(facts.fileSizeBytes, 8192);
    expect(facts.isUnavailable, isFalse);
  });

  test('读不出来的 mpls 给 unavailable（可重试）而不是 empty（终局）', () async {
    expect(
      (await probeBlurayPlaylistFacts(
        p.join(discRoot, 'BDMV', 'PLAYLIST', '09999.mpls'),
      )).isUnavailable,
      isTrue,
    );
  });
}
