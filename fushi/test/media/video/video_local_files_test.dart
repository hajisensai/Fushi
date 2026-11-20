/// 删除确认框「同时删除本地文件」（视频侧）的判据与删除护栏：
/// 远端流没有文件可删、相对路径不可删、播放列表各集算本地文件、仍被别的行引用的
/// 文件保留、大小写不同的同一个文件仍被护栏挡住、目录绝不删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show dvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdTitlePath;
import 'package:fushi_engine/media/video/video_local_files.dart';
import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, platformPathKey;
import 'package:path/path.dart' as p;

/// 把路径里的字母大小写整体翻转，用来构造「同一个文件的另一种写法」。
String _swapCase(String value) => String.fromCharCodes(<int>[
  for (final int c in value.codeUnits)
    if (c >= 0x41 && c <= 0x5A)
      c + 32
    else if (c >= 0x61 && c <= 0x7A)
      c - 32
    else
      c,
]);

void main() {
  group('isLocalVideoFilePath', () {
    test('绝对的裸路径算本地', () {
      // 「绝对」由 package:path 按**宿主平台**判，而这正是删除判据要的语义：
      // File(path).delete() 同样按本进程解析。所以盘符路径只在 Windows 上算绝对；
      // 把它当跨平台常量断言，只会让这条用例在 Linux CI 上恒红、本机 Windows 恒绿。
      expect(
        isLocalVideoFilePath('/home/u/ep01.mkv'),
        isTrue,
        reason: '前导斜杠在 windows / posix 两种风格里都算 rooted',
      );
      expect(
        isLocalVideoFilePath(r'D:\Videos\ep01.mkv'),
        Platform.isWindows,
        reason: '盘符路径只有在 Windows 上才是本进程能解析的绝对路径',
      );
    });

    test('相对路径不算本地——File.delete() 会按进程 cwd 解析', () {
      // 删除路径上「删掉哪个文件取决于 app 启动时的工作目录」是不可接受的不确定性。
      expect(isLocalVideoFilePath('relative/ep01.mkv'), isFalse);
      expect(isLocalVideoFilePath('ep01.mkv'), isFalse);
    });

    test('带 scheme 的 URI 不算本地（远端直传 / WebDAV / content）', () {
      expect(isLocalVideoFilePath('https://host/stream?token=1'), isFalse);
      expect(isLocalVideoFilePath('http://192.168.1.2:8080/a.mkv'), isFalse);
      expect(isLocalVideoFilePath('content://media/external/video/1'), isFalse);
      expect(isLocalVideoFilePath('file:///tmp/a.mkv'), isFalse);
    });

    test('空 / 空白不算', () {
      expect(isLocalVideoFilePath(''), isFalse);
      expect(isLocalVideoFilePath('   '), isFalse);
    });
  });

  group('playlistEntryPaths', () {
    test('解出各集路径；坏 JSON / 非列表 → 空', () {
      final String json = jsonEncode(<Map<String, Object>>[
        <String, Object>{'title': 'e1', 'path': r'D:\v\e1.mkv'},
        <String, Object>{
          'title': 'e2',
          'path': r'D:\v\e2.mkv',
          'positionMs': 3,
        },
      ]);
      expect(playlistEntryPaths(json), <String>[
        r'D:\v\e1.mkv',
        r'D:\v\e2.mkv',
      ]);
      expect(playlistEntryPaths(null), isEmpty);
      expect(playlistEntryPaths(''), isEmpty);
      expect(playlistEntryPaths('{not json'), isEmpty);
      expect(playlistEntryPaths('{"a":1}'), isEmpty);
    });
  });

  group('videoBookEpisodePath（host 按集取文件）', () {
    final String json = jsonEncode(<Map<String, Object>>[
      <String, Object>{'title': 'e1', 'path': '/v/e1.mkv'},
      <String, Object>{'title': 'e2', 'path': '/v/e2.mkv'},
      <String, Object>{'title': 'e3', 'path': ''},
    ]);

    test('第 0 集用 videoPath；其余按播放列表下标', () {
      expect(
        videoBookEpisodePath(
          videoPath: '/v/current.mkv',
          playlistJson: json,
          episodeIndex: 0,
        ),
        '/v/current.mkv',
      );
      expect(
        videoBookEpisodePath(
          videoPath: '/v/current.mkv',
          playlistJson: json,
          episodeIndex: 1,
        ),
        '/v/e2.mkv',
      );
    });

    test('越界 / 负数 / 空路径 / 没有播放列表 / 坏 JSON 的第 N 集 → null', () {
      for (final (String? playlist, int index) in <(String?, int)>[
        (json, 3),
        (json, -1),
        (json, 2),
        (null, 1),
        ('{not json', 1),
      ]) {
        expect(
          videoBookEpisodePath(
            videoPath: '/v/current.mkv',
            playlistJson: playlist,
            episodeIndex: index,
          ),
          isNull,
          reason: '$playlist #$index',
        );
      }
      expect(
        videoBookEpisodePath(videoPath: '', episodeIndex: 0),
        isNull,
        reason: '空 videoPath',
      );
      expect(
        videoBookEpisodePath(videoPath: '/v/single.mkv', episodeIndex: 0),
        '/v/single.mkv',
      );
    });
  });

  group('videoBookDiscTitlePath（host 按盘 + title 定位）', () {
    final String root = p.join(p.separator, 'discs', 'Show Disc 1');
    final String main = p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls');

    test('同盘的另一条 title：由这一行自己的盘根拼出', () {
      expect(
        videoBookDiscTitlePath(
          videoPath: main,
          discTitle: 'BDMV/PLAYLIST/00005.mpls',
        ),
        p.join(root, 'BDMV', 'PLAYLIST', '00005.mpls'),
      );
      // 大小写不敏感（盘上常见大写目录名）；分集虚拟路径也能当锚点。
      expect(
        videoBookDiscTitlePath(
          videoPath: p.join(root, 'BDMV', 'PLAYLIST', '00001.p03.mpls'),
          discTitle: 'bdmv/playlist/00800.MPLS',
        ),
        p.join(root, 'bdmv', 'playlist', '00800.MPLS'),
      );
    });

    test('多角度 title 的角度成员路径也能定位（host 按角度读）', () {
      expect(
        videoBookDiscTitlePath(
          videoPath: main,
          discTitle: 'BDMV/PLAYLIST/00001.a2.mpls',
        ),
        p.join(root, 'BDMV', 'PLAYLIST', '00001.a2.mpls'),
      );
    });

    test('走不出这张盘、不是蓝光播放列表、锚点不是蓝光行 → null', () {
      for (final String bad in <String>[
        '',
        '00005.mpls',
        'BDMV/PLAYLIST/../00005.mpls',
        'BDMV/PLAYLIST/..',
        'BDMV/STREAM/00005.m2ts',
        'BDMV/PLAYLIST/00005.m2ts',
        'BDMV/PLAYLIST/sub/00005.mpls',
        r'BDMV/PLAYLIST/..\..\x.mpls',
        'BDMV/PLAYLIST/C:x.mpls',
        '/BDMV/PLAYLIST/00005.mpls',
        'VIDEO_TS/TITLE_01.dvdtitle',
      ]) {
        expect(
          videoBookDiscTitlePath(videoPath: main, discTitle: bad),
          isNull,
          reason: bad,
        );
      }
      // DVD 行：按这一行的盘根重拼 `VIDEO_TS/TITLE_nn.dvdtitle`（文件夹与 .iso 形态都认）。
      for (final String discRoot in <String>[
        p.join(p.separator, 'discs', 'Show DVD'),
        p.join(p.separator, 'discs', 'Show.iso'),
      ]) {
        final String dvdRow = dvdTitlePath(discRoot, 1);
        expect(
          videoBookDiscTitlePath(
            videoPath: dvdRow,
            discTitle: 'VIDEO_TS/TITLE_07.dvdtitle',
          ),
          dvdTitlePath(discRoot, 7),
        );
        expect(
          videoBookDiscTitlePath(
            videoPath: dvdRow,
            discTitle: 'video_ts/TITLE_07.dvdtitle',
          ),
          dvdTitlePath(discRoot, 7),
        );
        // 多角度 title 的角度成员路径保留角度（host 按正在播的角度读）。
        expect(
          videoBookDiscTitlePath(
            videoPath: dvdRow,
            discTitle: 'VIDEO_TS/TITLE_07.a2.dvdtitle',
          ),
          dvdTitleAnglePath(dvdTitlePath(discRoot, 7), 1),
        );
        for (final String bad in <String>[
          'VIDEO_TS/TITLE_07.a1.dvdtitle',
          'VIDEO_TS/TITLE_07.a10.dvdtitle',
          'BDMV/PLAYLIST/00005.mpls',
          'VIDEO_TS/TITLE_00.dvdtitle',
          'VIDEO_TS/TITLE_100.dvdtitle',
          'VIDEO_TS/TITLE_07.mpls',
          'VIDEO_TS/../TITLE_07.dvdtitle',
          'VIDEO_TS/sub/TITLE_07.dvdtitle',
          'TITLE_07.dvdtitle',
          'VIDEO_TS/C:TITLE_07.dvdtitle',
        ]) {
          expect(
            videoBookDiscTitlePath(videoPath: dvdRow, discTitle: bad),
            isNull,
            reason: bad,
          );
        }
      }
      expect(
        videoBookDiscTitlePath(
          videoPath: p.join(p.separator, 'v', 'single.mkv'),
          discTitle: 'BDMV/PLAYLIST/00005.mpls',
        ),
        isNull,
      );
    });
  });

  group('localVideoFileCandidates', () {
    test('videoPath + 播放列表各集，去重、剔远端', () {
      // 路径样本按宿主平台构造：候选筛选走 isLocalVideoFilePath，它本就是宿主
      // 相关的，写死盘符在非 Windows 上只会得到空表（而不是测到去重与剔远端）。
      final String root = Platform.isWindows ? r'D:\v' : '/v';
      final String list = p.join(root, 'list.m3u8');
      final String e1 = p.join(root, 'e1.mkv');
      final String json = jsonEncode(<Map<String, Object>>[
        <String, Object>{'title': 'e1', 'path': e1},
        <String, Object>{'title': 'e1-dup', 'path': e1},
        <String, Object>{'title': 'remote', 'path': 'https://h/e2.mkv'},
      ]);
      expect(
        localVideoFileCandidates(videoPath: list, playlistJson: json),
        <String>[list, e1],
      );
    });

    test('Windows：分隔符写法不同的同一集只留一条', () {
      // 分隔符等价（`D:/v/e1.mkv` ≡ `D:\v\e1.mkv`）是 Windows 独有的；posix 下
      // 反斜杠是合法文件名字符，那真是两个文件。
      final String json = jsonEncode(<Map<String, Object>>[
        <String, Object>{'title': 'e1', 'path': 'D:/v/e1.mkv'},
        <String, Object>{'title': 'e1-dup', 'path': r'D:\v\e1.mkv'},
        <String, Object>{'title': 'remote', 'path': 'https://h/e2.mkv'},
      ]);
      expect(
        localVideoFileCandidates(
          videoPath: r'D:\v\list.m3u8',
          playlistJson: json,
        ),
        <String>[r'D:\v\list.m3u8', 'D:/v/e1.mkv'],
      );
    }, skip: Platform.isWindows ? null : '盘符路径只在 Windows 上是绝对路径');

    test('远端流 → 无候选 → 弹窗不摆勾选框', () {
      expect(
        localVideoFileCandidates(videoPath: 'https://h/stream?token=x'),
        isEmpty,
      );
    });
  });

  group('deleteLocalVideoFiles', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi-local-del-');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('删未被引用的文件；被引用的保留；目录与缺失路径跳过', () async {
      final File a = File(p.join(tmp.path, 'a.mkv'))..writeAsStringSync('a');
      final File b = File(p.join(tmp.path, 'b.mkv'))..writeAsStringSync('b');
      final Directory d = Directory(p.join(tmp.path, 'dir'))..createSync();
      final String missing = p.join(tmp.path, 'missing.mkv');

      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path, b.path, d.path, missing],
        stillReferenced: <String>{platformPathKey(b.path)},
      );

      expect(report.removedSet, <String>{a.path});
      expect(report.failures, isEmpty, reason: '本来就不存在的路径不算删除失败');
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isTrue, reason: '仍被别的库行引用的文件不能删');
      expect(d.existsSync(), isTrue, reason: '目录绝不删');
    });

    test('护栏比对经路径归一（分隔符差异不放行误删）', () async {
      final File a = File(p.join(tmp.path, 'a.mkv'))..writeAsStringSync('a');
      final String flipped = a.path.replaceAll(r'\', '/');
      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path],
        stillReferenced: <String>{platformPathKey(flipped)},
      );
      expect(report.removed, isEmpty);
      expect(a.existsSync(), isTrue);
    });

    test('护栏比对折大小写：Windows 上大小写不同仍是同一个文件', () async {
      // 这正是 normalizeVideoPath 当判据时漏掉的那一格：它不折大小写，
      // `D:\a\b.mkv` 与 `d:\a\b.mkv` 被判成两个文件，护栏漏命中就删掉了用户
      // 还在用的那一份。
      final File a = File(p.join(tmp.path, 'Case.mkv'))..writeAsStringSync('a');
      final LocalFileDeleteReport report = await deleteLocalVideoFiles(
        candidates: <String>[a.path],
        stillReferenced: <String>{platformPathKey(_swapCase(a.path))},
      );
      if (Platform.isWindows) {
        expect(report.removed, isEmpty, reason: 'Windows 上大小写不同 = 同一个文件');
        expect(a.existsSync(), isTrue);
      } else {
        expect(report.removedSet, <String>{
          a.path,
        }, reason: 'Linux/Android 大小写敏感，那真是另一个文件，不该被护栏挡住');
        expect(a.existsSync(), isFalse);
      }
    });
  });

  group('sidecarSubtitlesForDeletedVideo（BUG-2565）', () {
    test('同名 sidecar 字幕跟着视频走：带语言标记与不带的都算', () {
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'ep01.mkv',
          dirFileNames: <String>[
            'ep01.mkv',
            'ep01.srt',
            'ep01.ja.ass',
            'ep01.zh-Hans.vtt',
          ],
        ),
        <String>['ep01.srt', 'ep01.ja.ass', 'ep01.zh-Hans.vtt'],
      );
    });

    test('别的集的字幕、非字幕文件一律不收', () {
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'ep01.mkv',
          dirFileNames: <String>[
            'ep01.srt',
            'ep02.srt',
            'ep01.jpg',
            'ep01.nfo',
            'ep01.mkv',
          ],
        ),
        <String>['ep01.srt'],
      );
    });

    test('大小写不同的同名字幕照样收（Windows 上是同一个文件）', () {
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'EP01.MKV',
          dirFileNames: <String>['ep01.JA.srt'],
        ),
        <String>['ep01.JA.srt'],
      );
    });

    test('更长 stem 的邻居视频还在盘上 → 它认领的字幕不跟着走', () {
      // `ep01.5.srt` 对 `ep01` 而言后缀是 `.5.srt`，那个 `5` 长得像语言标记，按
      // 前缀匹配会被 `ep01` 命中——但它显然属于还在的 `ep01.5.mkv`。
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'ep01.mkv',
          dirFileNames: <String>[
            'ep01.mkv',
            'ep01.srt',
            'ep01.5.mkv',
            'ep01.5.srt',
          ],
        ),
        <String>['ep01.srt'],
        reason: '邻居那一集还在，它的字幕一条都不能带走',
      );
      // 反过来，邻居自己被删时它的字幕照收——护栏只挡「实体还在的邻居」。
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'ep01.5.mkv',
          dirFileNames: <String>[
            'ep01.mkv',
            'ep01.srt',
            'ep01.5.mkv',
            'ep01.5.srt',
          ],
        ),
        <String>['ep01.5.srt'],
      );
    });

    test('没有字幕 → 空表', () {
      expect(
        sidecarSubtitlesForDeletedVideo(
          videoFileName: 'ep01.mkv',
          dirFileNames: <String>['ep01.mkv'],
        ),
        isEmpty,
      );
    });
  });

  group('localVideoSidecarSubtitleCandidates（BUG-2565）', () {
    test('真实目录：同名字幕进候选，别的集与非字幕不进', () async {
      final Directory dir = await Directory.systemTemp.createTemp('fushi_sub_');
      addTearDown(() => dir.delete(recursive: true));
      for (final String name in <String>[
        'ep01.mkv',
        'ep01.srt',
        'ep01.ja.ass',
        'ep01.jpg',
        'ep02.mkv',
        'ep02.srt',
      ]) {
        await File(p.join(dir.path, name)).writeAsString('x');
      }

      final List<String> got = await localVideoSidecarSubtitleCandidates(
        <String>[p.join(dir.path, 'ep01.mkv')],
      );

      expect(got.map(p.basename).toSet(), <String>{'ep01.srt', 'ep01.ja.ass'});
    });

    test('同一目录多集一起删 → 各自的字幕都进候选且不重复', () async {
      final Directory dir = await Directory.systemTemp.createTemp('fushi_sub_');
      addTearDown(() => dir.delete(recursive: true));
      for (final String name in <String>[
        'ep01.mkv',
        'ep01.srt',
        'ep02.mkv',
        'ep02.srt',
      ]) {
        await File(p.join(dir.path, name)).writeAsString('x');
      }

      final List<String> got = await localVideoSidecarSubtitleCandidates(
        <String>[p.join(dir.path, 'ep01.mkv'), p.join(dir.path, 'ep02.mkv')],
      );

      expect(got.map(p.basename).toList(), <String>['ep01.srt', 'ep02.srt']);
      expect(got.map(platformPathKey).toSet(), hasLength(2), reason: '不重复');
    });

    test('目录不存在 → 空表，不抛（收集候选失败只该少删文件）', () async {
      expect(
        await localVideoSidecarSubtitleCandidates(<String>[
          p.join(Directory.systemTemp.path, 'fushi_no_such_dir_2565', 'a.mkv'),
        ]),
        isEmpty,
      );
    });
  });
}
