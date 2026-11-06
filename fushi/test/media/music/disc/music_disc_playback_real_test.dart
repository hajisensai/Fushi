// 光盘章节曲目对**真 libmpv** 的播放验证（音乐方案 §9.2「播放章节曲目时起止精确」）：
// 读盘 → 导入成曲目行 → 曲目行换成播放项 → 音乐输出后端（`ao=pcm` 落盘）→ 数实际送出的
// 样本数。
//
// 需要（缺任一项整组 skip）：
//   FUSHI_TEST_LIBMPV   带 dvdnav / dvdvideo 的 libmpv-2.dll（其 fbd*.dll 所在目录在 PATH 里）
//   FUSHI_DVD_TEST_DISC `tool/dvd/make_test_dvd.py` 编出的无加密测试盘（`<out>/DVD`：title 1
//                       6 s、3 章 0 / 1.8 / 4.2 s，音轨是 48 kHz AC-3 静音）
//   FUSHI_BD_TEST_DISC  （可选）一张无加密的 BDMV 目录，只读
//
// 实测（2026-10-24，Windows x64，`…-dvd1-rdisc1` libmpv）：DVD title 1 整条音频 5.93 s
// （音轨比画面短）；第 2 + 3 章连播 4.18 s；BD 章节段按 3 s 截取出 3.00 s。

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

String? _env(String key) {
  final String? v = Platform.environment[key];
  return v == null || v.isEmpty ? null : v;
}

/// 用 `ao=pcm` 把后端实际送出的音频落盘（48 kHz 单声道 s16），播完返回秒数。
Future<double> _playToPcm(List<MusicPlayItem> items, String out) async {
  final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
    configuration: const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music disc test',
    ),
    initialProperties: <String, String>{
      'ao': 'pcm',
      'ao-pcm-file': out,
      'ao-pcm-waveheader': 'no',
      'audio-format': 's16',
      'audio-samplerate': '48000',
      'audio-channels': 'mono',
    },
  );
  final Completer<void> done = Completer<void>();
  int advanced = 0;
  final StreamSubscription<MusicBackendEvent> sub = backend.events.listen((
    MusicBackendEvent e,
  ) {
    if (e is MusicBackendAdvanced) advanced++;
    if (e is MusicBackendCompleted && !done.isCompleted) done.complete();
  });
  try {
    await backend.applySettings(
      const MusicOutputSettings(
        gapless: true,
        replayGain: MusicReplayGainMode.off,
      ),
    );
    await backend.openPair(
      items.first,
      items.length > 1 ? items[1] : null,
      play: true,
    );
    await done.future.timeout(const Duration(seconds: 60));
    if (items.length > 1) expect(advanced, greaterThanOrEqualTo(1));
  } finally {
    await sub.cancel();
    await backend.dispose();
  }
  return File(out).lengthSync() / 2 / 48000;
}

void main() {
  final String? libmpv = _env('FUSHI_TEST_LIBMPV');
  final String? dvd = _env('FUSHI_DVD_TEST_DISC');
  final String? bd = _env('FUSHI_BD_TEST_DISC');
  late Directory tmp;

  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
    tmp = Directory.systemTemp.createTempSync('music_disc_real_');
  });
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 留给系统清。
    }
  });

  test(
    'DVD：章节点来自 IFO；导入的第 2、3 章经 dvdvideo + EDL 连播，时长对上章节',
    () async {
      final MusicDiscInfo info = (await readMusicDiscInfo(dvd!))!;
      final MusicDiscTitle title = info.titles.firstWhere(
        (MusicDiscTitle t) => t.number == 1,
      );
      expect(
        title.chapters.map((MusicDiscChapter c) => c.start.inMilliseconds),
        <int>[0, 1800, 4200],
      );

      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await MusicDiscImportService(db).importChapters(
        info,
        titleNumbers: <int>{1},
        chapterTitle: (MusicDiscTitle t, MusicDiscChapter c) => 'ch${c.number}',
      );
      final List<MusicTrackRow> tracks = sortAlbumTracks(
        await db.listMusicTracks(),
      );
      expect(tracks.map((MusicTrackRow t) => t.title), <String>[
        'ch1',
        'ch2',
        'ch3',
      ]);

      final double seconds = await _playToPcm(<MusicPlayItem>[
        musicPlayItemOf(tracks[1]),
        musicPlayItemOf(tracks[2]),
      ], p.join(tmp.path, 'dvd_ch2_ch3.raw'));
      // 第 2 章 2.4 s + 第 3 章到 title 结尾（音轨比画面早约 0.05 s 结束）。
      expect(seconds, closeTo(4.17, 0.1));

      final double ch2 = await _playToPcm(<MusicPlayItem>[
        musicPlayItemOf(tracks[1]),
      ], p.join(tmp.path, 'dvd_ch2.raw'));
      // AC-3 一帧 32 ms：段尾落在帧内时按样本裁，误差不超过一帧。
      expect(ch2, closeTo(2.4, 0.04));
    },
    skip: libmpv == null || dvd == null
        ? 'set FUSHI_TEST_LIBMPV and FUSHI_DVD_TEST_DISC'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'BD：正片章节 → m2ts EDL 段，从章节点起播',
    () async {
      final MusicDiscInfo info = (await readMusicDiscInfo(bd!))!;
      final MusicDiscTitle main = info.titles.firstWhere(
        (MusicDiscTitle t) => t.isMainFeature,
      );
      expect(main.chapters.length, greaterThan(1));
      final MusicDiscChapter second = main.chapters[1];
      final double seconds = await _playToPcm(<MusicPlayItem>[
        MusicPlayItem(
          trackUid: 'bd',
          path: main.titlePath,
          title: 'bd',
          startMs: second.start.inMilliseconds,
          endMs: second.start.inMilliseconds + 3000,
        ),
      ], p.join(tmp.path, 'bd.raw'));
      expect(seconds, closeTo(3.0, 0.05));
    },
    skip: libmpv == null || bd == null
        ? 'set FUSHI_TEST_LIBMPV and FUSHI_BD_TEST_DISC'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
