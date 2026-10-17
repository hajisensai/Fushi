/// 音频 CD 抓轨：每轨一个 FLAC，落在按光盘身份命名的目录里（BUG-3312）。
///
/// - Windows 光驱（[AudioCdLayout.windowsCda]）：原始扇区在后台 isolate 里读成临时
///   WAV（阻塞系统调用，按块回报进度、可取消），再由 ffmpeg 转 FLAC。
/// - macOS 挂载点（[AudioCdLayout.macCddafs]）：每轨本就是 AIFF，直接由 ffmpeg 转
///   FLAC。挂载点拔盘即消失，所以同样要抓成本地文件才能入库。
///
/// FLAC 先写 `.part`、编码成功才改名到位，所以「文件存在」就是「已抓完」：同一张盘
/// 重插得到同一目录，已抓的轨直接复用，半截的 `.part` 会重抓。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/media/audio/flac_encoder.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/windows_audio_cd_drive.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:path/path.dart' as p;

/// 抓轨进度：[trackIndex] 从 0 起，[fraction] 是整张盘的完成比例。
typedef AudioCdRipProgress = ({
  int trackIndex,
  int trackCount,
  double fraction,
});

/// 抓轨结果。[unreadableSectors] > 0 表示有划伤扇区被静音填充。
typedef AudioCdRipResult = ({
  String directory,
  List<String> files,
  int unreadableSectors,
});

/// 取消开关：UI 持有一份。[ripAudioCd] 在轨之间、读扇区块之间检查它，正在跑的
/// FLAC 编码经 [whenCancelled] 当场强杀（后端支持时，见 [encodeFlacFile]），全部轨
/// 处理完后还要再看一次——取消之后绝不交出结果。
class AudioCdRipCancellation {
  final Completer<void> _cancelled = Completer<void>();
  void Function()? _onCancel;

  bool get isCancelled => _cancelled.isCompleted;

  /// 取消时完成；从不取消就永不完成。
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    _onCancel?.call();
  }
}

/// 一条待抓的轨：[weight] 是进度权重（扇区数或字节数）；[cdda] 与 [aiffPath]
/// 恰有一个非空，分别对应两种 [AudioCdLayout]。
typedef _DiscTrack = ({
  int number,
  int weight,
  AudioCdTrack? cdda,
  String? aiffPath,
});

typedef _Disc = ({String label, String id, List<_DiscTrack> tracks});

/// 把 [discPath] 上的音频 CD 抓到 `<outputRoot>/<卷标> (<光盘id>)/Track NN.flac`。
///
/// 被取消时删掉未完成的那一轨并返回 null；读盘 / 编码失败抛 [AudioCdException]。
Future<AudioCdRipResult?> ripAudioCd({
  required String discPath,
  required AudioCdLayout layout,
  required String outputRoot,
  required FfmpegBackend ffmpeg,
  void Function(AudioCdRipProgress progress)? onProgress,
  AudioCdRipCancellation? cancellation,
}) async {
  final _Disc disc = switch (layout) {
    AudioCdLayout.windowsCda => await Isolate.run(
      () => _readWindowsDisc(discPath),
    ),
    AudioCdLayout.macCddafs => _readMacDisc(discPath),
  };
  if (disc.tracks.isEmpty) {
    throw const AudioCdException('The disc has no audio tracks');
  }
  final Directory dir = Directory(
    p.join(outputRoot, audioCdFolderName(disc.label, disc.id)),
  );
  await dir.create(recursive: true);

  final int total = disc.tracks.fold(
    0,
    (int sum, _DiscTrack t) => sum + t.weight,
  );
  int done = 0;
  int unreadable = 0;
  final List<String> files = <String>[];
  for (int i = 0; i < disc.tracks.length; i++) {
    // 取消后连「已缓存的轨」也不再交出：调用方拿到 null 就不导入。
    if (cancellation?.isCancelled ?? false) return null;
    final _DiscTrack track = disc.tracks[i];
    void report(int units) {
      done += units;
      onProgress?.call((
        trackIndex: i,
        trackCount: disc.tracks.length,
        fraction: total == 0 ? 1 : done / total,
      ));
    }

    final String name = audioCdTrackBaseName(track.number);
    final String flac = p.join(dir.path, '$name.flac');
    if (File(flac).existsSync()) {
      report(track.weight);
      files.add(flac);
      continue;
    }
    final AudioCdTrack? cdda = track.cdda;
    final String? tempWav = cdda == null ? null : '$flac.wav';
    try {
      if (cdda != null) {
        final int? bad = await _ripTrack(
          drivePath: discPath,
          track: cdda,
          wavPath: tempWav!,
          onSectors: report,
          cancellation: cancellation,
        );
        if (bad == null) return null;
        unreadable += bad;
      }
      final bool encoded = await _encodeFlac(
        ffmpeg,
        input: tempWav ?? track.aiffPath!,
        output: flac,
        title: name,
        album: disc.label,
        number: track.number,
        total: disc.tracks.length,
        cancel: cancellation?.whenCancelled,
      );
      if (!encoded) return null;
    } finally {
      if (tempWav != null && File(tempWav).existsSync()) {
        File(tempWav).deleteSync();
      }
    }
    if (cdda == null) report(track.weight);
    files.add(flac);
  }
  // 最后一轨编码期间被取消：不支持中止的后端会把它照常编完、循环自然结束——
  // 这里不再看一次，取消后的结果就会被交出去导入。
  if (cancellation?.isCancelled ?? false) return null;
  return (directory: dir.path, files: files, unreadableSectors: unreadable);
}

_Disc _readWindowsDisc(String drivePath) {
  final WindowsAudioCdDrive drive = WindowsAudioCdDrive.open(drivePath);
  try {
    final List<AudioCdTrack> toc = drive.readToc();
    return (
      label: windowsVolumeLabel(drivePath) ?? 'Audio CD',
      id: audioCdDiscId(toc),
      tracks: <_DiscTrack>[
        for (final AudioCdTrack t in toc)
          (number: t.number, weight: t.sectorCount, cdda: t, aiffPath: null),
      ],
    );
  } finally {
    drive.close();
  }
}

/// macOS 挂载点：卷名就是盘名，`N Audio Track.aiff` 按轨号排序。
_Disc _readMacDisc(String mountPath) {
  final List<String> names = <String>[
    for (final FileSystemEntity e in Directory(
      mountPath,
    ).listSync(followLinks: false))
      if (e is File) p.basename(e.path),
  ];
  final List<({int number, String path, int bytes})> tracks =
      <({int number, String path, int bytes})>[
        for (final ({int number, String name}) t in macCdTracksOf(names))
          (
            number: t.number,
            path: p.join(mountPath, t.name),
            bytes: File(p.join(mountPath, t.name)).lengthSync(),
          ),
      ];
  return (
    label: p.basename(p.normalize(mountPath)),
    id: macCdDiscId(<({int number, int bytes})>[
      for (final ({int number, String path, int bytes}) t in tracks)
        (number: t.number, bytes: t.bytes),
    ]),
    tracks: <_DiscTrack>[
      for (final ({int number, String path, int bytes}) t in tracks)
        (number: t.number, weight: t.bytes, cdda: null, aiffPath: t.path),
    ],
  );
}

/// [input]（CDDA 的 WAV 或 macOS 的 AIFF）→ [output] FLAC，带轨号 / 专辑标签。
/// `.part` 落盘约定见 [encodeFlacFile]：中途失败 / 被杀只留 `.part`，下次重抓。
/// 返回 false = 编码途中被 [cancel] 强杀（`.part` 已删）。
Future<bool> _encodeFlac(
  FfmpegBackend ffmpeg, {
  required String input,
  required String output,
  required String title,
  required String album,
  required int number,
  required int total,
  Future<void>? cancel,
}) async {
  try {
    return await encodeFlacFile(
      ffmpeg,
      input: input,
      output: output,
      metadata: <String, String>{
        'title': title,
        'album': album,
        'track': '$number/$total',
      },
      cancel: cancel,
    );
  } on FlacEncodeException catch (e) {
    throw AudioCdException('FLAC encoding failed (${e.message})');
  }
}

/// 抓轨目录名 `<卷标> (<光盘id>)`。
///
/// 卷标经 [safeWindowsFileName] 去掉非法字符（字符集只有那一处真相源），再去掉首尾
/// 空白与 Windows 不允许的尾随 `.` / 空格；剩下为空回退 `Audio CD`。整名若会被
/// Windows 当成保留设备名（[isWindowsReservedFileName]：卷标 `CON.x` 得到的
/// `CON.x (…)` 在第一个 `.` 前就是 `CON`）则前缀 `_`。卷标恰为 `CON` 时整名是
/// `CON (…)`，本就不是设备名，原样保留。
String audioCdFolderName(String label, String discId) {
  final String cleaned = safeWindowsFileName(
    label,
  ).trim().replaceAll(RegExp(r'[. ]+$'), '');
  final String name = '${cleaned.isEmpty ? 'Audio CD' : cleaned} ($discId)';
  return isWindowsReservedFileName(name) ? '_$name' : name;
}

/// 在后台 isolate 抓一轨到 [wavPath]。返回静音填充的扇区数；被取消返回 null。
Future<int?> _ripTrack({
  required String drivePath,
  required AudioCdTrack track,
  required String wavPath,
  required void Function(int sectors) onSectors,
  AudioCdRipCancellation? cancellation,
}) async {
  final String partPath = '$wavPath.part';
  final ReceivePort port = ReceivePort();
  await Isolate.spawn(
    _ripTrackWorker,
    (drivePath: drivePath, track: track, path: partPath, reply: port.sendPort),
    onExit: port.sendPort,
    errorsAreFatal: true,
  );
  ({int bad, bool cancelled, String? error})? outcome;
  try {
    await for (final Object? msg in port) {
      if (msg is SendPort) {
        cancellation?._onCancel = () => msg.send(null);
        if (cancellation?.isCancelled ?? false) msg.send(null);
      } else if (msg is int) {
        onSectors(msg);
      } else if (msg is ({int bad, bool cancelled, String? error})) {
        outcome = msg;
      } else {
        break; // onExit（null）：worker 已退出
      }
    }
  } finally {
    port.close();
    cancellation?._onCancel = null;
  }
  final ({int bad, bool cancelled, String? error}) result =
      outcome ??
      (bad: 0, cancelled: false, error: 'CD reader exited unexpectedly');
  if (result.error != null || result.cancelled) {
    final File part = File(partPath);
    if (part.existsSync()) part.deleteSync();
    if (result.cancelled) return null;
    throw AudioCdException(result.error!);
  }
  final File done = File(wavPath);
  if (done.existsSync()) done.deleteSync();
  File(partPath).renameSync(wavPath);
  return result.bad;
}

typedef _TrackJob = ({
  String drivePath,
  AudioCdTrack track,
  String path,
  SendPort reply,
});

Future<void> _ripTrackWorker(_TrackJob job) async {
  final ReceivePort control = ReceivePort();
  bool cancelled = false;
  control.listen((_) => cancelled = true);
  job.reply.send(control.sendPort);
  WindowsAudioCdDrive? drive;
  RandomAccessFile? out;
  int bad = 0;
  String? error;
  try {
    drive = WindowsAudioCdDrive.open(job.drivePath);
    out = File(job.path).openSync(mode: FileMode.write);
    out.writeFromSync(
      cddaWavHeader(job.track.sectorCount * kCddaRawSectorBytes),
    );
    int badRun = 0;
    for (int lba = job.track.startLba; lba < job.track.endLba;) {
      // 每块让出一次事件循环，取消消息才进得来。
      await Future<void>.delayed(Duration.zero);
      if (cancelled) break;
      final int n = math.min(kWindowsCdRawReadChunk, job.track.endLba - lba);
      final ({Uint8List pcm, int bad}) read = _readRecovering(drive, lba, n);
      // 整整一秒连续读不出不是划伤，是盘被弹出 / 驱动失效：让本轨失败，绝不把
      // 一整段静音当成「抓完」写出来（同盘重插会按字节数把它当成品复用）。
      badRun = read.bad == n ? badRun + n : 0;
      if (badRun >= kCddaSectorsPerSecond) {
        throw const AudioCdException('The disc stopped responding');
      }
      out.writeFromSync(read.pcm);
      bad += read.bad;
      lba += n;
      job.reply.send(n);
    }
  } on Object catch (e) {
    error = e is AudioCdException ? e.message : '$e';
  } finally {
    out?.closeSync();
    drive?.close();
    control.close();
  }
  job.reply.send((
    bad: bad,
    cancelled: cancelled && error == null,
    error: error,
  ));
}

/// 读 [count] 个扇区；整块失败时逐扇区重读，仍读不出的扇区以静音填充并计数。
///
/// 重读不是掩盖症状：划伤 / 灰尘造成的瞬时读错是光盘介质的常态，抓轨软件
/// （EAC、cdparanoia）都按扇区重读；读不出的扇区如实计入 [unreadableSectors]
/// 交给 UI 告知用户，而不是静默吞掉。
({Uint8List pcm, int bad}) _readRecovering(
  WindowsAudioCdDrive drive,
  int lba,
  int count,
) {
  final Uint8List? whole = _readWithRetry(drive, lba, count);
  if (whole != null && whole.length == count * kCddaRawSectorBytes) {
    return (pcm: whole, bad: 0);
  }
  final BytesBuilder pcm = BytesBuilder(copy: false);
  int bad = 0;
  for (int i = 0; i < count; i++) {
    final Uint8List? one = _readWithRetry(drive, lba + i, 1);
    if (one != null && one.length == kCddaRawSectorBytes) {
      pcm.add(one);
    } else {
      pcm.add(Uint8List(kCddaRawSectorBytes));
      bad++;
    }
  }
  return (pcm: pcm.takeBytes(), bad: bad);
}

Uint8List? _readWithRetry(WindowsAudioCdDrive drive, int lba, int count) {
  for (int attempt = 0; attempt < 3; attempt++) {
    final Uint8List? data = drive.readSectors(lba, count);
    if (data != null) return data;
  }
  return null;
}
