/// 音频 CD 抓轨：光驱原始扇区 → 每轨一个 WAV，落在按光盘身份命名的目录里。
///
/// 直接写 WAV 而不经 ffmpeg 转 FLAC：Windows 随包的 ffmpeg-min 没有 FLAC 编码器
/// 与 flac/wav 封装器，WAV 头是 44 字节的定长结构，自己写零依赖、零失败模式。
///
/// 读盘是阻塞系统调用，每轨在一个后台 isolate 里读，按块回报进度、可取消。
/// 同一张盘重插得到同一目录（[audioCdDiscId]），已抓完的轨直接复用。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/windows_audio_cd_drive.dart';
import 'package:path/path.dart' as p;

/// 抓轨进度：[trackIndex] 从 0 起，[fraction] 是整张盘的扇区完成比例。
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

/// 取消开关：UI 持有一份，[ripAudioCd] 在块之间检查。
class AudioCdRipCancellation {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

/// 把 [drivePath] 所在光驱里的音频 CD 抓到 `<outputRoot>/<卷标> (<光盘id>)/`。
///
/// 被取消时删掉未完成的那一轨并返回 null；读盘失败抛 [AudioCdException]。
Future<AudioCdRipResult?> ripAudioCd({
  required String drivePath,
  required String outputRoot,
  void Function(AudioCdRipProgress progress)? onProgress,
  AudioCdRipCancellation? cancellation,
}) async {
  final ({List<AudioCdTrack> tracks, String? label}) disc = await Isolate.run(
    () => _readDisc(drivePath),
  );
  if (disc.tracks.isEmpty) {
    throw const AudioCdException('The disc has no audio tracks');
  }
  final Directory dir = Directory(
    p.join(
      outputRoot,
      '${_safeName(disc.label ?? 'Audio CD')} (${audioCdDiscId(disc.tracks)})',
    ),
  );
  await dir.create(recursive: true);

  final int totalSectors = disc.tracks.fold(
    0,
    (int sum, AudioCdTrack t) => sum + t.sectorCount,
  );
  int doneSectors = 0;
  int unreadable = 0;
  final List<String> files = <String>[];
  for (int i = 0; i < disc.tracks.length; i++) {
    // 取消后连「已缓存的轨」也不再交出：调用方拿到 null 就不导入。
    if (cancellation?.isCancelled ?? false) return null;
    final AudioCdTrack track = disc.tracks[i];
    void report(int sectors) {
      doneSectors += sectors;
      onProgress?.call((
        trackIndex: i,
        trackCount: disc.tracks.length,
        fraction: doneSectors / totalSectors,
      ));
    }

    final String wav = p.join(
      dir.path,
      '${audioCdTrackBaseName(track.number)}.wav',
    );
    if (_isCompleteTrack(wav, track)) {
      report(track.sectorCount);
      files.add(wav);
      continue;
    }
    final int? bad = await _ripTrack(
      drivePath: drivePath,
      track: track,
      wavPath: wav,
      onSectors: report,
      cancellation: cancellation,
    );
    if (bad == null) return null;
    unreadable += bad;
    files.add(wav);
  }
  return (directory: dir.path, files: files, unreadableSectors: unreadable);
}

({List<AudioCdTrack> tracks, String? label}) _readDisc(String drivePath) {
  final WindowsAudioCdDrive drive = WindowsAudioCdDrive.open(drivePath);
  try {
    return (tracks: drive.readToc(), label: windowsVolumeLabel(drivePath));
  } finally {
    drive.close();
  }
}

/// 已有的 WAV 字节数与本轨扇区数严格对上才算抓完（中途断电的残文件会重抓）。
bool _isCompleteTrack(String wavPath, AudioCdTrack track) {
  final File f = File(wavPath);
  return f.existsSync() &&
      f.lengthSync() == 44 + track.sectorCount * kCddaRawSectorBytes;
}

String _safeName(String name) {
  final String cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty ? 'Audio CD' : cleaned;
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
