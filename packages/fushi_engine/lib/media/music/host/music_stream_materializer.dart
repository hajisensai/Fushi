/// 互联共享音乐库：把「播放器不能直接按 Range 读」的曲目截成 / 转成 host 缓存里的一个文件，再由统一
/// 流票按 Range 直出（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §9）。
///
/// 三类来源走同一个出口：
/// - **转码**（design-imusic-q6）：client 设了码率上限 → AAC（`.m4a`，faststart，可 seek）；
/// - **光盘标题**（design-imusic-q5）：DVD title 经 `dvdvideo` 输入、BD `.mpls` 经播放列表输入（都由
///   [resolveFfmpegBackend] 的原盘适配器改写），按章节起止截段 → FLAC（无损）或 AAC（有码率上限）；
/// - **CDDA**（design-imusic-q5）：Windows 光驱按扇区读成 WAV（[extractAudioCdRange]）→ FLAC / AAC；
/// - 网络来源 / CUE 曲目在要转码时同样经这里（上游地址带头部作 ffmpeg 输入，CUE 截段）。
///
/// 截好的文件**就是这一首**（CUE / 章节起止已应用），client 不再拼 EDL 段（签票回 `segmentApplied`）。
/// 同一输入并发只截一次；缓存按总量（[capacityBytes]）淘汰最久没用的。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_engine/media/audio_cd/audio_cd_ripper.dart'
    show extractAudioCdRange;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:path/path.dart' as p;

/// 一次截取的输入。
sealed class MusicMaterializeInput {
  const MusicMaterializeInput();

  /// 进缓存键的稳定描述（同一输入 + 同一参数 = 同一个缓存文件）。
  String get identity;
}

/// ffmpeg 能直接打开的输入：本机文件、原盘适配器认的 DVD title / BD `.mpls`、上游 http(s)。
final class MusicFfmpegInput extends MusicMaterializeInput {
  const MusicFfmpegInput(
    this.input, {
    this.headers = const <String, String>{},
    required this.version,
  });

  final String input;

  /// 上游 http(s) 的请求头（WebDAV Basic 等）；本机输入为空。
  final Map<String, String> headers;

  /// 源的版本（文件 mtime / 大小等）：源变了缓存自动失效。
  final String version;

  @override
  String get identity => 'ff|$input|$version';
}

/// Windows 光驱上整盘时间轴的一段（`cdda://E:` 曲目）。
final class MusicCddaInput extends MusicMaterializeInput {
  const MusicCddaInput(this.drivePath, {required this.discId});

  final String drivePath;

  /// 光盘身份（换盘缓存自动失效）。
  final String discId;

  @override
  String get identity => 'cdda|$drivePath|$discId';
}

/// 截取失败（ffmpeg 退出码非 0 / 读盘失败）。
class MusicMaterializeException implements Exception {
  const MusicMaterializeException(this.message);

  final String message;

  @override
  String toString() => 'MusicMaterializeException($message)';
}

/// 跑一条 ffmpeg 命令（测试替身在此接管）。返回退出码与输出。
typedef MusicFfmpegRunner =
    Future<({int? code, String output})> Function(List<String> args);

/// 读 CD 一段到 WAV（测试替身在此接管）。
typedef MusicCddaExtractor =
    Future<void> Function({
      required String drivePath,
      required int startMs,
      int? endMs,
      required String wavPath,
    });

class MusicStreamMaterializer {
  MusicStreamMaterializer({
    Directory? cacheDir,
    this.capacityBytes = 2 * 1024 * 1024 * 1024,
    MusicFfmpegRunner? ffmpeg,
    MusicCddaExtractor? cdda,
    this.timeout = const Duration(minutes: 10),
  }) : _cacheDir =
           cacheDir ??
           Directory(p.join(Directory.systemTemp.path, 'fushi_music_streams')),
       _ffmpeg = ffmpeg ?? _defaultFfmpeg,
       _cdda = cdda ?? _defaultCdda;

  final Directory _cacheDir;

  /// 缓存总量上限；超出时按最后访问时间淘汰。
  final int capacityBytes;

  /// 一次截取最多等多久（整张盘的 BD title 转码也在这之内）。
  final Duration timeout;

  final MusicFfmpegRunner _ffmpeg;
  final MusicCddaExtractor _cdda;
  final Map<String, Future<File>> _running = <String, Future<File>>{};

  /// [input] 的 [startMs, endMs) 截成一个文件：[bitrateKbps] 为 null → FLAC（无损），否则 AAC。
  Future<File> materialize(
    MusicMaterializeInput input, {
    int? startMs,
    int? endMs,
    int? bitrateKbps,
  }) {
    final String key = sha1
        .convert(
          utf8.encode(
            '${input.identity}|${startMs ?? ''}|${endMs ?? ''}|'
            '${bitrateKbps ?? 'lossless'}',
          ),
        )
        .toString();
    final String ext = bitrateKbps == null ? 'flac' : 'm4a';
    final File out = File(p.join(_cacheDir.path, '$key.$ext'));
    return _running[key] ??=
        _produce(
          input,
          out,
          startMs: startMs,
          endMs: endMs,
          bitrateKbps: bitrateKbps,
        ).whenComplete(() {
          // 不能写成 `=> _running.remove(key)`：remove 回的正是这个 future，whenComplete 会等它自己。
          _running.remove(key);
        });
  }

  Future<File> _produce(
    MusicMaterializeInput input,
    File out, {
    int? startMs,
    int? endMs,
    int? bitrateKbps,
  }) async {
    if (await out.exists()) {
      // 记一次访问：淘汰按最后访问时间。
      try {
        await out.setLastModified(DateTime.now());
      } on FileSystemException {
        // 只影响淘汰顺序。
      }
      return out;
    }
    await _cacheDir.create(recursive: true);
    final String part = '${out.path}.part';
    String? tempWav;
    try {
      final List<String> args = <String>['-hide_banner', '-nostdin', '-y'];
      switch (input) {
        case MusicFfmpegInput():
          if (input.headers.isNotEmpty) {
            args.addAll(<String>[
              '-headers',
              input.headers.entries
                  .map(
                    (MapEntry<String, String> e) => '${e.key}: ${e.value}\r\n',
                  )
                  .join(),
            ]);
          }
          if (startMs != null && startMs > 0) {
            args.addAll(<String>['-ss', _seconds(startMs)]);
          }
          args.addAll(<String>['-i', input.input]);
          if (endMs != null) {
            args.addAll(<String>['-t', _seconds(endMs - (startMs ?? 0))]);
          }
        case MusicCddaInput():
          tempWav = '${out.path}.wav';
          await _cdda(
            drivePath: input.drivePath,
            startMs: startMs ?? 0,
            endMs: endMs,
            wavPath: tempWav,
          );
          args.addAll(<String>['-i', tempWav]);
      }
      args.addAll(<String>['-map', '0:a:0', '-vn', '-sn', '-dn']);
      if (bitrateKbps == null) {
        args.addAll(<String>['-c:a', 'flac', '-f', 'flac']);
      } else {
        args.addAll(<String>[
          '-c:a',
          'aac',
          '-b:a',
          '${bitrateKbps}k',
          '-movflags',
          '+faststart',
          '-f',
          'mp4',
        ]);
      }
      args.add(part);
      final ({int? code, String output}) r = await _ffmpeg(
        args,
      ).timeout(timeout);
      if (r.code != 0 || !await File(part).exists()) {
        throw MusicMaterializeException(
          'ffmpeg exit ${r.code}: ${_tail(r.output)}',
        );
      }
      await File(part).rename(out.path);
      unawaited(_evict(keep: out.path));
      return out;
    } on TimeoutException {
      throw const MusicMaterializeException('ffmpeg timed out');
    } finally {
      for (final String path in <String>[part, ?tempWav]) {
        try {
          final File f = File(path);
          if (await f.exists()) await f.delete();
        } on FileSystemException {
          // 清理失败不影响结果；下次同名会覆盖。
        }
      }
    }
  }

  /// 超过 [capacityBytes] 时删最久没用的（刚产出的 [keep] 不删）。
  Future<void> _evict({required String keep}) async {
    try {
      final List<File> files = <File>[
        await for (final FileSystemEntity e in _cacheDir.list())
          if (e is File &&
              !e.path.endsWith('.part') &&
              !e.path.endsWith('.wav'))
            e,
      ];
      final List<({File file, int size, DateTime at})> stats =
          <({File file, int size, DateTime at})>[
            for (final File f in files)
              (file: f, size: f.lengthSync(), at: f.lastModifiedSync()),
          ]..sort(
            (
              ({File file, int size, DateTime at}) a,
              ({File file, int size, DateTime at}) b,
            ) => a.at.compareTo(b.at),
          );
      int total = stats.fold(
        0,
        (int sum, ({File file, int size, DateTime at}) s) => sum + s.size,
      );
      for (final ({File file, int size, DateTime at}) s in stats) {
        if (total <= capacityBytes) break;
        if (s.file.path == keep) continue;
        try {
          await s.file.delete();
          total -= s.size;
        } on FileSystemException {
          // 正在被流读的文件（Windows 上删不掉）：留到下次。
        }
      }
    } on FileSystemException {
      // 缓存目录被外部清掉：下次截取时重建。
    }
  }

  static String _seconds(int ms) => (ms / 1000).toStringAsFixed(3);

  static String _tail(String s) =>
      s.length <= 400 ? s : s.substring(s.length - 400);

  static Future<({int? code, String output})> _defaultFfmpeg(
    List<String> args,
  ) async {
    final FfmpegRunResult r = await resolveFfmpegBackend().run(
      args,
      const Duration(minutes: 10),
    );
    return (code: r.returnCode, output: r.output);
  }

  static Future<void> _defaultCdda({
    required String drivePath,
    required int startMs,
    int? endMs,
    required String wavPath,
  }) async {
    await extractAudioCdRange(
      drivePath: drivePath,
      startMs: startMs,
      endMs: endMs,
      wavPath: wavPath,
    );
  }
}
