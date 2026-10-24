// 音频 CD 播放对**真 libmpv + 真光驱**的验证（音乐方案 §9.3 P5「音频 CD」）：读盘 → 入库 →
// 曲目行换成播放项 → 音乐输出后端（`ao=pcm` 落盘，44.1 kHz 立体声 s16，与 CD 同格式、不经
// 任何转换）→ 与 cd-paranoia 直读的同一轨**逐字节**比。
//
// 证明三件事：
//   1. 第 2 轨起止逐样本落在轨界上（`cdda-seek-sector-offset.patch` 之前 mpv 的 seek 丢掉
//      扇区内偏移，整段提前一百多个样本）；
//   2. 曲目中途 seek 后，送出的样本就是 seek 目标处的样本（偏移 0）；
//   3. 第 2 → 3 轨连播：拼起来与两轨直读首尾相接、逐字节相同（没有缺口、没有重叠），
//      无论下一首是打开时就排好的，还是播放中由 `replaceNext` 排进来的。
// 另外：光驱里不是这张盘 / 没有盘时，打开就明确报原因，不出声。
//
// 需要（缺任一项整组 skip——这类测试按硬件 skip，见 CLAUDE.md）：
//   FUSHI_TEST_LIBMPV        带 cdda 的 libmpv-2.dll（`tool/bluray/build_libmpv.ps1` 的产物，
//                            其 fbd*.dll 所在目录在 PATH 里）
//   FUSHI_CDDA_DEVICE        放着音频 CD 的光驱（Windows 盘符，如 `E:`）
//   FUSHI_CDDA_REFERENCE_DIR 参考：`cd-paranoia -d <设备> -Z -r 2 track02.raw`、同法 `-r 3
//                            track03.raw`（小端 s16 原始 PCM）
// 另需 fushi_music 原生库（读 TOC，`tool/native_libs.ps1`）。
//
// 实测见 docs/specs/2026-10-23-music-module-design.md §9.3「音频 CD」。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/disc/music_audio_cd.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

String? _env(String key) {
  final String? v = Platform.environment[key];
  return v == null || v.isEmpty ? null : v;
}

const int _kFrameBytes = 4; // s16 立体声

/// 一次后端播放的结果。
typedef _Run = ({
  Uint8List pcm,
  List<String> advanced,
  List<MusicBackendEvent> failures,
});

/// 用 `ao=pcm` 把后端实际送出的音频落盘；[drive] 拿到后端后驱动它（打开 / 排下一首 /
/// seek…），播完（Completed）或报错（Failed）即返回。
Future<_Run> _run(
  String out,
  Future<void> Function(MpvMusicOutputBackend backend) drive,
) async {
  final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
    configuration: const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music CD test',
    ),
    initialProperties: <String, String>{
      'ao': 'pcm',
      'ao-pcm-file': out,
      'ao-pcm-waveheader': 'no',
      'audio-format': 's16',
      'audio-samplerate': '44100',
      'audio-channels': 'stereo',
    },
  );
  final Completer<void> done = Completer<void>();
  final List<String> advanced = <String>[];
  final List<MusicBackendEvent> failures = <MusicBackendEvent>[];
  final StreamSubscription<MusicBackendEvent> sub = backend.events.listen((
    MusicBackendEvent e,
  ) {
    if (e is MusicBackendAdvanced) advanced.add(e.trackUid ?? '?');
    if (e is MusicBackendFailed) failures.add(e);
    if ((e is MusicBackendCompleted || e is MusicBackendFailed) &&
        !done.isCompleted) {
      done.complete();
    }
  });
  try {
    await backend.applySettings(
      const MusicOutputSettings(
        gapless: true,
        replayGain: MusicReplayGainMode.off,
      ),
    );
    await drive(backend);
    await done.future.timeout(const Duration(minutes: 4));
  } finally {
    await sub.cancel();
    await backend.dispose();
  }
  final File file = File(out);
  return (
    pcm: file.existsSync() ? file.readAsBytesSync() : Uint8List(0),
    advanced: advanced,
    failures: failures,
  );
}

void _expectNoFailure(_Run r) => expect(<String>[
  for (final MusicBackendEvent e in r.failures)
    if (e is MusicBackendFailed) '${e.reason}: ${e.message}',
], isEmpty);

/// [got] 在 [ref] 里从第几帧开始（只用于失败时说明偏了多少）。
int _locate(Uint8List got, Uint8List ref) {
  int first = 0;
  while (first + 4096 <= got.length &&
      got.sublist(first, first + 4).every((int b) => b == 0)) {
    first += _kFrameBytes;
  }
  if (first + 4096 > got.length) return -1;
  final Uint8List probe = got.sublist(first, first + 4096);
  outer:
  for (int i = 0; i + probe.length <= ref.length; i += _kFrameBytes) {
    for (int j = 0; j < probe.length; j++) {
      if (ref[i + j] != probe[j]) continue outer;
    }
    return (i - first) ~/ _kFrameBytes;
  }
  return -1;
}

/// [got] 必须与 [ref] 从 [fromFrame] 起到结尾逐字节相同（长度也相同）。
void _expectSamePcm(Uint8List got, Uint8List ref, {int fromFrame = 0}) {
  final Uint8List want = Uint8List.sublistView(ref, fromFrame * _kFrameBytes);
  final bool same =
      got.length == want.length &&
      () {
        for (int i = 0; i < got.length; i++) {
          if (got[i] != want[i]) return false;
        }
        return true;
      }();
  expect(
    same,
    isTrue,
    reason:
        'got ${got.length ~/ _kFrameBytes} frames, want '
        '${want.length ~/ _kFrameBytes} (from frame $fromFrame); got starts at '
        'ref frame ${_locate(got, ref)} (offset ${_locate(got, ref) - fromFrame})',
  );
}

void main() {
  final String? libmpv = _env('FUSHI_TEST_LIBMPV');
  final String? device = _env('FUSHI_CDDA_DEVICE');
  final String? refDir = _env('FUSHI_CDDA_REFERENCE_DIR');
  final String? skip = libmpv == null || device == null || refDir == null
      ? 'needs an audio CD in a drive: set FUSHI_TEST_LIBMPV (libmpv with '
            'cdda), FUSHI_CDDA_DEVICE and FUSHI_CDDA_REFERENCE_DIR '
            '(cd-paranoia -r track02.raw / track03.raw)'
      : null;

  late Directory tmp;
  late List<MusicTrackRow> tracks;
  late Uint8List ref2;
  late Uint8List ref3;
  late FushiDatabase db;

  setUpAll(() async {
    if (skip != null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    tmp = Directory.systemTemp.createTempSync('music_cdda_real_');
    ref2 = File(p.join(refDir!, 'track02.raw')).readAsBytesSync();
    ref3 = File(p.join(refDir, 'track03.raw')).readAsBytesSync();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final MusicAudioCdService service = MusicAudioCdService(db);
    final AudioCdInfo info = await service.read(device!);
    final String albumUid = await service.import(
      info,
      device: device,
      fallbackTitle: (int n) => 'Track $n',
      fallbackAlbumTitle: 'Audio CD',
    );
    tracks = sortAlbumTracks(await db.listMusicTracks(albumUid: albumUid));
    // ignore: avoid_print
    print(
      'disc ${info.discId}: ${tracks.length} tracks; track 2 '
      '${tracks[1].cueStartMs}–${tracks[1].cueEndMs} ms, track 3 '
      '${tracks[2].cueStartMs}–${tracks[2].cueEndMs} ms',
    );
  });
  tearDownAll(() async {
    if (skip != null) return;
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 留给系统清。
    }
  });

  MusicPlayItem item(int index) => musicPlayItemOf(tracks[index]);

  test(
    '第 2 轨：与 cd-paranoia 直读逐字节相同（起止都在轨界上，偏移 0）',
    () async {
      final _Run r = await _run(
        p.join(tmp.path, 'track02.raw'),
        (MpvMusicOutputBackend b) => b.openPair(item(1), null, play: true),
      );
      _expectNoFailure(r);
      _expectSamePcm(r.pcm, ref2);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '第 2 轨中途 seek：送出的就是 seek 目标处的样本（偏移 0），一直放到轨尾',
    () async {
      const Duration target = Duration(milliseconds: 100123);
      final _Run r = await _run(p.join(tmp.path, 'seek.raw'), (
        MpvMusicOutputBackend b,
      ) async {
        await b.openPair(item(1), null, play: false);
        // 文件加载完（mpv 报出时长）才能 seek。
        if (b.debugPlayer.state.duration <= Duration.zero) {
          await b.debugPlayer.stream.duration
              .firstWhere((Duration d) => d > Duration.zero)
              .timeout(const Duration(seconds: 60));
        }
        await b.seek(target);
        await b.play();
      });
      _expectNoFailure(r);
      // 后端把本曲在盘上的起点加回去；media_kit 的 seek 精确到毫秒，mpv 精确 seek 按
      // `trunc((目标 - 包起点) · 44100)` 跳过样本 = 目标时刻向下取整的那一帧。
      final int originUs = (musicCddaSeconds(tracks[1].cueStartMs!) * 1e6)
          .round();
      final double targetS =
          ((originUs + target.inMicroseconds) ~/ 1000) / 1000;
      final int originFrame = (musicCddaSeconds(tracks[1].cueStartMs!) * 44100)
          .round();
      final int fromFrame = (targetS * 44100).floor() - originFrame;
      _expectSamePcm(r.pcm, ref2, fromFrame: fromFrame);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  Uint8List both() => Uint8List.fromList(<int>[...ref2, ...ref3]);

  test(
    '第 2 → 3 轨连播（打开时就排好下一首）：首尾相接、逐字节无缝',
    () async {
      final _Run r = await _run(
        p.join(tmp.path, 'gapless_open.raw'),
        (MpvMusicOutputBackend b) => b.openPair(item(1), item(2), play: true),
      );
      _expectNoFailure(r);
      expect(r.advanced, <String>[tracks[2].trackUid]);
      _expectSamePcm(r.pcm, both());
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '第 2 → 3 轨连播（播放中才排下一首，同一文件延长终点）：同样逐字节无缝',
    () async {
      final _Run r = await _run(p.join(tmp.path, 'gapless_replace.raw'), (
        MpvMusicOutputBackend b,
      ) async {
        await b.openPair(item(1), null, play: true);
        await b.replaceNext(item(2));
      });
      _expectNoFailure(r);
      expect(r.advanced, <String>[tracks[2].trackUid]);
      _expectSamePcm(r.pcm, both());
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '光驱里不是这张盘 / 没有盘：打开即明确报原因，不出声',
    () async {
      final MusicPlayItem real = item(1);
      final MusicPlayItem otherDisc = MusicPlayItem(
        trackUid: 'not-the-disc-in-the-drive',
        path: real.path,
        title: real.title,
        startMs: real.startMs,
        endMs: real.endMs,
        trackNo: real.trackNo,
      );
      final _Run other = await _run(
        p.join(tmp.path, 'other.raw'),
        (MpvMusicOutputBackend b) => b.openPair(otherDisc, null, play: true),
      );
      final MusicBackendFailed f = other.failures.single as MusicBackendFailed;
      expect(f.reason, MusicPlaybackFailure.cdOtherDisc);
      expect(f.device, device);
      expect(other.pcm, isEmpty);

      final String missing = <String>[
        for (int c = 'Z'.codeUnitAt(0); c > 'F'.codeUnitAt(0); c--)
          String.fromCharCode(c),
      ].firstWhere((String l) => !Directory('$l:\\').existsSync());
      final _Run none = await _run(
        p.join(tmp.path, 'none.raw'),
        (MpvMusicOutputBackend b) => b.openPair(
          MusicPlayItem(
            trackUid: real.trackUid,
            path: musicCddaPath('$missing:'),
            title: real.title,
            startMs: real.startMs,
            endMs: real.endMs,
            trackNo: real.trackNo,
          ),
          null,
          play: true,
        ),
      );
      final MusicBackendFailed n = none.failures.single as MusicBackendFailed;
      expect(n.reason, MusicPlaybackFailure.cdNoDisc);
      expect(n.device, '$missing:');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
