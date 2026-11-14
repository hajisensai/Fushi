import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_download.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart'
    show interconnectDownloadTaskEntry;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteDownloadCancelled;
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

const String _plugin = 'asmr-one';

const MusicPluginAlbum _work = MusicPluginAlbum(
  id: 'RJ01234567',
  title: '癒しの耳かき: 夜*編?',
  artists: <MusicPluginArtistRef>[MusicPluginArtistRef(name: 'サークルA')],
  coverUrl: 'https://cdn.example/cover',
  releaseDate: '2024-05-01',
);

MusicPluginTrack _track(
  String id, {
  String title = '01 本編',
  int? trackNo = 1,
  int? discNo,
  String? albumId,
  bool playable = true,
}) => MusicPluginTrack(
  id: id,
  title: title,
  artists: const <MusicPluginArtistRef>[
    MusicPluginArtistRef(name: '声優B'),
    MusicPluginArtistRef(name: '声優C'),
  ],
  albumId: albumId,
  trackNo: trackNo,
  discNo: discNo,
  playable: playable,
);

/// 一段 FLAC 头 + 填充：嗅探认成 flac。
Uint8List _flacBytes() => Uint8List.fromList(<int>[
  ...ascii.encode('fLaC'),
  ...List<int>.filled(64, 0),
]);

Uint8List _jpegBytes() => Uint8List.fromList(<int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  ...List<int>.filled(16, 1),
]);

class _Harness {
  _Harness(this.root);

  final Directory root;
  final InterconnectDownloadManager downloads = InterconnectDownloadManager();
  final List<String> streamCalls = <String>[];
  final List<String> imported = <String>[];
  final Map<String, Map<MusicTagField, String>> tags =
      <String, Map<MusicTagField, String>>{};
  final List<String> softErrors = <String>[];

  /// 每首曲目 id 的取流行为（缺省给完整流）。
  final Map<String, Future<MusicPluginStream> Function()> streams =
      <String, Future<MusicPluginStream> Function()>{};

  /// 传输替身：缺省写 FLAC 字节；可换成会被取消 / 报错的。
  Future<void> Function(File dest, Future<void>? cancel) transfer =
      (File dest, Future<void>? cancel) async {
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(_flacBytes());
      };

  String? importError;

  late final MusicPluginDownloadService service = MusicPluginDownloadService(
    downloads: downloads,
    root: () async => root,
    stream: (String pluginId, String trackId) {
      streamCalls.add(trackId);
      final Future<MusicPluginStream> Function()? s = streams[trackId];
      if (s != null) return s();
      return Future<MusicPluginStream>.value(
        const MusicPluginStream(
          url: 'https://media.example/a/track',
          headers: <String, String>{'Referer': 'https://asmr.example/'},
        ),
      );
    },
    import: (String path) async {
      imported.add(path);
      return importError;
    },
    transfer:
        ({
          required String url,
          required Map<String, String> headers,
          required File dest,
          void Function(double progress)? onProgress,
          void Function(int received, int? total)? onBytes,
          Future<void>? cancelSignal,
        }) => transfer(dest, cancelSignal),
    fetchBytes: (String url) async => _jpegBytes(),
    writeTags: (String path, Map<MusicTagField, String> t) async {
      tags[path] = t;
    },
    softError: (String where, Object e, StackTrace s) => softErrors.add(where),
  );

  /// 等到没有在跑的任务（真实文件 IO 不在微任务里完成，按管理器状态等，不按轮数猜）。
  Future<void> settle() async {
    bool idle() => downloads.tasks.values.every(
      (InterconnectDownloadTask t) => !t.isRunning,
    );
    if (idle()) return;
    final Completer<void> done = Completer<void>();
    void listener() {
      if (idle() && !done.isCompleted) done.complete();
    }

    downloads.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } finally {
      downloads.removeListener(listener);
    }
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('music_plugin_download_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('落点', () {
    test('专辑目录按专辑键、文件名带碟-曲序与曲目哈希；非法字符被清掉', () {
      final MusicPluginDownloadTarget a = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('t1', discNo: 2, trackNo: 3),
        album: _work,
      );
      final MusicPluginDownloadTarget b = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('t2', title: '01 本編'),
        album: _work,
      );
      // 同一专辑 → 同一目录（目录封面只属于这张专辑）。
      expect(a.dir.path, b.dir.path);
      expect(p.dirname(a.dir.path), p.join(tmp.path, _plugin));
      final String dirName = p.basename(a.dir.path);
      expect(dirName, startsWith('癒しの耳かき_ 夜_編_ ['));
      expect(dirName, matches(RegExp(r'\[[0-9a-f]{8}\]$')));
      expect(a.stem, startsWith('2-03 01 本編 ['));
      // 同名曲目（ASMR 作品里 mp3 / wav 两套同名很常见）不撞文件。
      expect(a.stem, isNot(b.stem));
      expect(b.stem, startsWith('01 01 本編 ['));
      expect(a.staging.path, p.join(a.dir.path, '${a.stem}.download'));
    });

    test('曲目自带专辑 id 优先于专辑页上下文；没有专辑的单曲自成一个目录', () {
      final MusicPluginDownloadTarget own = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('t1', albumId: 'other'),
        album: _work,
      );
      final MusicPluginDownloadTarget ctx = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('t1'),
        album: _work,
      );
      expect(own.dir.path, isNot(ctx.dir.path));
      final MusicPluginDownloadTarget s1 = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('s1', title: 'Single', trackNo: null),
      );
      final MusicPluginDownloadTarget s2 = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('s2', title: 'Single', trackNo: null),
      );
      expect(s1.dir.path, isNot(s2.dir.path));
      expect(p.basename(s1.dir.path), startsWith('Single ['));
      expect(s1.stem, startsWith('Single ['));
    });

    test('路径段：保留设备名加前缀、结尾的点去掉、空串给下划线、按码点截断', () {
      expect(musicDownloadPathSegment('CON'), '_CON');
      expect(musicDownloadPathSegment('abc...  '), 'abc');
      expect(musicDownloadPathSegment('  '), '_');
      expect(musicDownloadPathSegment('a/b\\c:d'), 'a_b_c_d');
      expect(musicDownloadPathSegment('あ' * 100).runes.length, 80);
    });
  });

  group('元数据', () {
    test('标签：标题 / 艺人 / 专辑 / 专辑艺人 / 曲序 / 碟号 / 日期', () {
      expect(
        musicPluginDownloadTags(
          _track('t1', discNo: 1, trackNo: 4),
          album: _work,
        ),
        <MusicTagField, String>{
          MusicTagField.title: '01 本編',
          MusicTagField.artist: '声優B / 声優C',
          MusicTagField.album: _work.title,
          MusicTagField.albumArtist: 'サークルA',
          MusicTagField.trackNo: '4',
          MusicTagField.discNo: '1',
          MusicTagField.date: '2024-05-01',
        },
      );
    });

    test('歌单里的曲目（无专辑上下文）：专辑艺人回落到曲目艺人，没有的字段不写', () {
      final Map<MusicTagField, String> tags = musicPluginDownloadTags(
        const MusicPluginTrack(id: 'x', title: 'Song', albumTitle: 'LP'),
      );
      expect(tags, <MusicTagField, String>{
        MusicTagField.title: 'Song',
        MusicTagField.album: 'LP',
      });
      expect(
        musicPluginDownloadTags(
          const MusicPluginTrack(
            id: 'x',
            title: 'Song',
            artists: <MusicPluginArtistRef>[MusicPluginArtistRef(name: 'A')],
          ),
          album: const MusicPluginAlbum(id: 'al', title: 'AL', year: 2020),
        ),
        <MusicTagField, String>{
          MusicTagField.title: 'Song',
          MusicTagField.artist: 'A',
          MusicTagField.album: 'AL',
          MusicTagField.albumArtist: 'A',
          MusicTagField.date: '2020',
        },
      );
    });

    test('文件头嗅探', () {
      List<int> h(String s, [int at = 0, int len = 32]) {
        final List<int> b = List<int>.filled(len, 0);
        b.setAll(at, ascii.encode(s));
        return b;
      }

      expect(sniffAudioExtension(h('fLaC')), 'flac');
      expect(sniffAudioExtension(h('ID3')), 'mp3');
      expect(sniffAudioExtension(<int>[0xFF, 0xFB, 0x90, 0x00]), 'mp3');
      expect(sniffAudioExtension(<int>[0xFF, 0xF1, 0x50, 0x80]), 'aac');
      expect(
        sniffAudioExtension(<int>[
          ...ascii.encode('RIFF'),
          0,
          0,
          0,
          0,
          ...ascii.encode('WAVE'),
        ]),
        'wav',
      );
      expect(
        sniffAudioExtension(<int>[
          ...h('OggS', 0, 28),
          ...ascii.encode('OpusHead'),
        ]),
        'opus',
      );
      expect(sniffAudioExtension(h('OggS')), 'ogg');
      expect(sniffAudioExtension(h('ftyp', 4)), 'm4a');
      expect(sniffAudioExtension(h('<html>')), isNull);
      expect(
        musicPluginDownloadExtensionHint(
          const MusicPluginStream(url: 'https://x/y/01.wav?sig=1'),
        ),
        'wav',
      );
      expect(
        musicPluginDownloadExtensionHint(
          const MusicPluginStream(url: 'https://x/y/stream', codec: 'FLAC'),
        ),
        'flac',
      );
      expect(sniffCoverExtension(_jpegBytes()), 'jpg');
      expect(sniffCoverExtension(h('<html>')), isNull);
    });
  });

  group('歌词 sidecar', () {
    test('原文 / 译文落成曲库认的同名 sidecar（与本地歌词同一条读取规则）', () {
      final File audio = File(p.join(tmp.path, '01 本編 [abcd1234].flac'));
      final List<({String path, String text})> files = musicPluginLyricSidecars(
        audio,
        const MusicPluginLyrics(
          original: MusicPluginLyricText(format: 'lrc', text: '[00:01.00]あ'),
          translation: MusicPluginLyricText(
            format: 'lrc',
            text: '[00:01.00]啊',
            language: 'zh-Hans',
          ),
        ),
      );
      expect(files.map((f) => p.basename(f.path)), <String>[
        '01 本編 [abcd1234].lrc',
        '01 本編 [abcd1234].zh-Hans.lrc',
      ]);
      final LyricSidecarSet picked = pickLyricSidecars(audio.path, <String>[
        audio.path,
        for (final ({String path, String text}) f in files) f.path,
      ]);
      expect(picked.primary?.path, files[0].path);
      expect(picked.primary?.ext, 'lrc');
      expect(picked.translations.single.path, files[1].path);
      expect(picked.translations.single.translationLang, 'zh-Hans');
    });

    test('译文没给语言 / 语言不合形状按 zh-Hans；没有原文不写', () {
      final File audio = File(p.join(tmp.path, 'a.mp3'));
      final List<({String path, String text})> files = musicPluginLyricSidecars(
        audio,
        const MusicPluginLyrics(
          original: MusicPluginLyricText(format: 'yrc', text: 'x'),
          translation: MusicPluginLyricText(
            format: 'lrc',
            text: 'y',
            language: 'not a tag!',
          ),
        ),
      );
      expect(files.map((f) => p.basename(f.path)), <String>[
        'a.yrc',
        'a.zh-Hans.lrc',
      ]);
      expect(
        musicPluginLyricSidecars(audio, const MusicPluginLyrics()),
        isEmpty,
      );
    });
  });

  group('下载编排', () {
    test('单曲：落成带标签的本地文件 + 封面 + 歌词 sidecar，并导入曲库', () async {
      final _Harness h = _Harness(tmp);
      final MusicPluginTrack track = _track('t1');
      final MusicPluginDownloadStart outcome = await h.service.download(
        _plugin,
        track,
        album: _work,
        lyrics: (String pluginId, String trackId) async =>
            const MusicPluginLyrics(
              original: MusicPluginLyricText(
                format: 'lrc',
                text: '[00:00.00]x',
              ),
            ),
      );
      expect(outcome, MusicPluginDownloadStart.started);
      await h.settle();

      final MusicPluginDownloadTarget target = musicPluginDownloadTarget(
        tmp,
        _plugin,
        track,
        album: _work,
      );
      final File audio = target.audio('flac');
      expect(await audio.exists(), isTrue);
      expect(await target.staging.exists(), isFalse);
      expect(
        await File(
          p.join(target.dir.path, '${target.stem}.lrc'),
        ).readAsString(),
        '[00:00.00]x',
      );
      expect(await File(p.join(target.dir.path, 'cover.jpg')).exists(), isTrue);
      expect(h.tags[audio.path], musicPluginDownloadTags(track, album: _work));
      expect(h.imported, <String>[audio.path]);
      // 发起时为判断试听取的流直接用于第一轮，不重复取。
      expect(h.streamCalls, <String>['t1']);

      final InterconnectDownloadTask task = h.downloads.taskFor(
        musicPluginDownloadTaskId(_plugin, 't1'),
      )!;
      expect(task.status, InterconnectDownloadStatus.completed);
      expect(task.kind, InterconnectDownloadKind.music);
      expect(task.origin, InterconnectDownloadOrigin.musicPlugin);
      expect(task.title, '01 本編 · 声優B / 声優C');
      // 下载中心：归「音乐」类、与扩展源同标外部来源。
      final DownloadTaskEntry entry = interconnectDownloadTaskEntry(
        h.downloads,
        task,
      );
      expect(entry.kind, DownloadTaskKind.music);
      expect(entry.collectionKey, 'interconnect-extension');

      // 再点一次：成品在，只重新登记，不再取流 / 下载。
      final MusicPluginDownloadStart again = await h.service.download(
        _plugin,
        track,
        album: _work,
      );
      expect(again, MusicPluginDownloadStart.alreadyDownloaded);
      expect(h.streamCalls, <String>['t1']);
      expect(h.imported, <String>[audio.path, audio.path]);
    });

    test('只能试听的曲目拒绝下载：不建任务、不落文件', () async {
      final _Harness h = _Harness(tmp);
      h.streams['t1'] = () =>
          Future<MusicPluginStream>.error(const MusicPluginTrialOnly());
      final MusicPluginDownloadStart outcome = await h.service.download(
        _plugin,
        _track('t1'),
      );
      expect(outcome, MusicPluginDownloadStart.trialOnly);
      expect(h.downloads.tasks, isEmpty);
      expect(await Directory(p.join(tmp.path, _plugin)).exists(), isFalse);
      expect(h.imported, isEmpty);
    });

    test('试听判据与播放共用：插件给了 trial 的流被 fetchFullMusicPluginStream 拒掉', () {
      expect(
        const MusicPluginStream(
          url: 'u',
          trialStartMs: 0,
          trialEndMs: 30000,
        ).isTrial,
        isTrue,
      );
      expect(const MusicPluginTrialOnly(), isA<MusicPluginStreamUnavailable>());
    });

    test('不可播放的曲目不发起；其它取流失败照常抛给调用方', () async {
      final _Harness h = _Harness(tmp);
      expect(
        await h.service.download(_plugin, _track('t1', playable: false)),
        MusicPluginDownloadStart.unplayable,
      );
      expect(h.streamCalls, isEmpty);
      h.streams['t2'] = () => Future<MusicPluginStream>.error(
        const MusicPluginStreamUnavailable('需要 VIP'),
      );
      await expectLater(
        h.service.download(_plugin, _track('t2')),
        throwsA(isA<MusicPluginStreamUnavailable>()),
      );
      expect(h.downloads.tasks, isEmpty);
    });

    test('下载全部：试听 / 不可播放跳过并计数，其余串行下完', () async {
      final _Harness h = _Harness(tmp);
      h.streams['t2'] = () =>
          Future<MusicPluginStream>.error(const MusicPluginTrialOnly());
      final MusicPluginDownloadBatchResult r = await h.service.downloadAll(
        _plugin,
        <MusicPluginTrack>[
          _track('t1', trackNo: 1),
          _track('t2', trackNo: 2),
          _track('t3', trackNo: 3, playable: false),
          _track('t4', trackNo: 4),
        ],
        batchId: musicPluginDownloadBatchId(_plugin, albumId: _work.id),
        batchTitle: _work.title,
        album: _work,
      );
      expect(r.started, 2);
      expect(r.trialOnly, 1);
      expect(r.unplayable, 1);
      expect(r.failed, 0);
      expect(h.imported, hasLength(2));
      expect(
        h.downloads.taskFor(musicPluginDownloadTaskId(_plugin, 't2')),
        isNull,
      );
      // 一张专辑一个目录：两首都在里面，目录封面只取一次。
      final Directory dir = musicPluginDownloadTarget(
        tmp,
        _plugin,
        _track('t1'),
        album: _work,
      ).dir;
      final List<String> names =
          dir
              .listSync()
              .map((FileSystemEntity e) => p.basename(e.path))
              .toList()
            ..sort();
      expect(names.where((String n) => n.endsWith('.flac')), hasLength(2));
      expect(names.where((String n) => n.startsWith('cover.')), <String>[
        'cover.jpg',
      ]);
    });

    test('失败后重试：已下完的音频不重下，重试时才变成试听的如实失败', () async {
      final _Harness h = _Harness(tmp);
      h.importError = 'scan failed';
      final MusicPluginTrack track = _track('t1');
      await h.service.download(_plugin, track);
      await h.settle();
      final String id = musicPluginDownloadTaskId(_plugin, 't1');
      expect(
        h.downloads.taskFor(id)!.status,
        InterconnectDownloadStatus.failed,
      );
      expect(h.downloads.taskFor(id)!.error, contains('scan failed'));

      int transfers = 0;
      h.transfer = (File dest, Future<void>? cancel) async => transfers++;
      h.importError = null;
      await h.downloads.resume(id);
      expect(
        h.downloads.taskFor(id)!.status,
        InterconnectDownloadStatus.completed,
      );
      expect(transfers, 0);
      expect(h.streamCalls, <String>['t1']);

      // 另一首：第一轮被暂停，续传时插件只给试听了 → 任务失败、消息给用户看。
      final MusicPluginTrack other = _track('t2');
      final Completer<void> gate = Completer<void>();
      h.transfer = (File dest, Future<void>? cancel) async {
        await cancel;
        gate.complete();
        throw const RemoteDownloadCancelled();
      };
      await h.service.download(_plugin, other);
      final String otherId = musicPluginDownloadTaskId(_plugin, 't2');
      h.downloads.pause(otherId);
      await gate.future;
      await h.settle();
      expect(
        h.downloads.taskFor(otherId)!.status,
        InterconnectDownloadStatus.paused,
      );
      h.streams['t2'] = () =>
          Future<MusicPluginStream>.error(const MusicPluginTrialOnly());
      await h.downloads.resume(otherId);
      final InterconnectDownloadTask failed = h.downloads.taskFor(otherId)!;
      expect(failed.status, InterconnectDownloadStatus.failed);
      expect(failed.error, contains('试听'));
    });

    test('放弃任务（删文件）：清掉暂存字节、没导入成功的成品与 sidecar，不碰同目录别的曲目', () async {
      final _Harness h = _Harness(tmp);
      final MusicPluginTrack keep = _track('keep', trackNo: 1);
      await h.service.download(_plugin, keep, album: _work);
      await h.settle();
      h.importError = 'scan failed';
      final MusicPluginTrack track = _track('t1', trackNo: 2);
      await h.service.download(
        _plugin,
        track,
        album: _work,
        lyrics: (String a, String b) async => const MusicPluginLyrics(
          original: MusicPluginLyricText(format: 'lrc', text: '[00:00.00]x'),
        ),
      );
      await h.settle();
      final MusicPluginDownloadTarget target = musicPluginDownloadTarget(
        tmp,
        _plugin,
        track,
        album: _work,
      );
      expect(await target.audio('flac').exists(), isTrue);
      expect(
        await h.downloads.discard(musicPluginDownloadTaskId(_plugin, 't1')),
        isTrue,
      );
      expect(await target.audio('flac').exists(), isFalse);
      expect(
        await File(p.join(target.dir.path, '${target.stem}.lrc')).exists(),
        isFalse,
      );
      final MusicPluginDownloadTarget kept = musicPluginDownloadTarget(
        tmp,
        _plugin,
        keep,
        album: _work,
      );
      expect(await kept.audio('flac').exists(), isTrue);
    });

    test('认不出格式如实失败；封面 / 歌词取不到不让下载失败', () async {
      final _Harness h = _Harness(tmp);
      h.transfer = (File dest, Future<void>? cancel) async {
        await dest.parent.create(recursive: true);
        await dest.writeAsString('<html>blocked</html>');
      };
      await h.service.download(_plugin, _track('t1'));
      await h.settle();
      final InterconnectDownloadTask bad = h.downloads.taskFor(
        musicPluginDownloadTaskId(_plugin, 't1'),
      )!;
      expect(bad.status, InterconnectDownloadStatus.failed);
      expect(bad.error, contains('unrecognized audio format'));

      final _Harness ok = _Harness(Directory(p.join(tmp.path, 'ok')));
      await ok.service.download(
        _plugin,
        _track('t2'),
        album: _work,
        lyrics: (String a, String b) async => throw StateError('lyrics down'),
      );
      await ok.settle();
      expect(
        ok.downloads.taskFor(musicPluginDownloadTaskId(_plugin, 't2'))!.status,
        InterconnectDownloadStatus.completed,
      );
      expect(ok.softErrors, <String>['MusicPluginDownload.lyrics']);
    });
  });
}
