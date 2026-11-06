/// 合成音频的磁盘缓存。
///
/// - 键 = sha256(音色身份 + 合成文本)，文件名只用散列（不把正文写进路径）。
/// - 引擎先写 `<key>.part`，校验容器与时长后原子改名发布，旁边写 `<key>.json`
///   （格式 / 时长 / 词边界）。坏文件不发布。
/// - 正在被播放器用的键 [pin] 住，淘汰（按最近使用时间）跳过它们。
///
/// 全应用只应有一个实例（pin 计数不跨实例共享）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_types.dart';

class TtsCachedAudio {
  const TtsCachedAudio({
    required this.key,
    required this.path,
    required this.format,
    required this.durationMs,
    this.boundaries = const <TtsBoundary>[],
  });

  final String key;
  final String path;
  final TtsAudioFormat format;
  final int durationMs;
  final List<TtsBoundary> boundaries;
}

class TtsAudioCache {
  TtsAudioCache({required this.root, this.maxBytes = 512 * 1024 * 1024});

  final Directory root;
  final int maxBytes;

  final Map<String, int> _pins = <String, int>{};
  Future<void> _tail = Future<void>.value();

  static String keyFor(Map<String, Object?> audioIdentity, String text) {
    final List<String> names = audioIdentity.keys.toList()..sort();
    final String canonical = jsonEncode(<String, Object?>{
      'v': 1,
      'identity': <String, Object?>{
        for (final String n in names) n: audioIdentity[n],
      },
      'text': text,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  void pin(String key) => _pins[key] = (_pins[key] ?? 0) + 1;

  void unpin(String key) {
    final int count = (_pins[key] ?? 0) - 1;
    if (count <= 0) {
      _pins.remove(key);
    } else {
      _pins[key] = count;
    }
  }

  bool isPinned(String key) => _pins.containsKey(key);

  File _meta(String key) => File(p.join(root.path, '$key.json'));

  /// 音频文件的固定路径（与格式无关，容器格式记在元数据里、播放 / ffmpeg 按内容
  /// 识别）。调用方可以在合成之前就拿到这条路径（制卡切句子音频按它找文件）。
  String audioPathFor(String key) => p.join(root.path, '$key.audio');

  /// 已发布的缓存；元数据或音频缺失 / 不一致时返回 null（调用方重合成）。
  Future<TtsCachedAudio?> lookup(String key) async {
    final File meta = _meta(key);
    if (!await meta.exists()) return null;
    try {
      final Object? raw = jsonDecode(await meta.readAsString());
      if (raw is! Map) return null;
      final TtsAudioFormat? format = TtsAudioFormat.parse(
        raw['format'] as String?,
      );
      final Object? duration = raw['durationMs'];
      final Object? size = raw['bytes'];
      if (format == null || duration is! int || size is! int) return null;
      final File audio = File(audioPathFor(key));
      if (!await audio.exists() || await audio.length() != size) return null;
      // 最近使用时间 = 元数据 mtime，淘汰按它排。
      unawaited(meta.setLastModified(DateTime.now()).catchError((Object _) {}));
      final Object? rawBoundaries = raw['boundaries'];
      return TtsCachedAudio(
        key: key,
        path: audio.path,
        format: format,
        durationMs: duration,
        boundaries: <TtsBoundary>[
          if (rawBoundaries is List)
            for (final Object? b in rawBoundaries)
              if (TtsBoundary.fromJson(b) case final TtsBoundary boundary)
                boundary,
        ],
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 命中直接返回；否则调用 [synthesize] 写临时文件，校验后发布。
  Future<TtsCachedAudio> obtain(
    String key,
    Future<TtsResult> Function(String outputPath) synthesize,
  ) async {
    final TtsCachedAudio? hit = await lookup(key);
    if (hit != null) return hit;
    await root.create(recursive: true);
    final File part = File(
      p.join(root.path, '$key.${DateTime.now().microsecondsSinceEpoch}.part'),
    );
    try {
      final TtsResult result = await synthesize(part.path);
      final Uint8List bytes = await part.readAsBytes();
      final TtsAudioFormat? format = sniffTtsAudioFormat(bytes);
      final int? durationMs = format == null
          ? null
          : probeTtsAudioDurationMs(bytes, format);
      if (format == null || durationMs == null || durationMs <= 0) {
        throw const TtsFailure(TtsFailureCode.badResponse, 'invalid audio');
      }
      return await _serialized(() async {
        // 同 key 的另一路合成（书里相邻的重复短句「はい」「……」在并发 >1 时
        // 同时在途）可能已经先发布了：直接复用它，不删不覆盖——那个文件可能已
        // 被播放器打开，Windows 上删除正被打开的文件会抛 FileSystemException，
        // 让调度器把整条朗读判失败停下。本次的 .part 由 finally 清掉。
        final TtsCachedAudio? published = await lookup(key);
        if (published != null) return published;
        final File audio = File(audioPathFor(key));
        if (await audio.exists()) await audio.delete();
        await part.rename(audio.path);
        final File meta = _meta(key);
        final File metaPart = File('${meta.path}.part');
        await metaPart.writeAsString(
          jsonEncode(<String, Object?>{
            'format': format.extension,
            'durationMs': durationMs,
            'bytes': bytes.length,
            'boundaries': <Object?>[
              for (final TtsBoundary b in result.boundaries) b.toJson(),
            ],
          }),
        );
        await metaPart.rename(meta.path);
        await _evictLocked(protect: key);
        return TtsCachedAudio(
          key: key,
          path: audio.path,
          format: format,
          durationMs: durationMs,
          boundaries: result.boundaries,
        );
      });
    } finally {
      if (await part.exists()) {
        try {
          await part.delete();
        } on FileSystemException {
          // 下次启动的淘汰会扫掉残留 .part。
        }
      }
    }
  }

  Future<T> _serialized<T>(Future<T> Function() op) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await op());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// 丢弃一句的缓存（「重新生成」）。正在被使用的不删，返回 false。
  Future<bool> remove(String key) => _serialized(() async {
    if (isPinned(key)) return false;
    for (final File f in <File>[_meta(key), File(audioPathFor(key))]) {
      if (await f.exists()) await f.delete();
    }
    return true;
  });

  /// 总占用（字节）。
  Future<int> sizeBytes() async {
    if (!await root.exists()) return 0;
    int total = 0;
    await for (final FileSystemEntity e in root.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// 清空未被使用的缓存。
  Future<void> clear() => _serialized(() async {
    if (!await root.exists()) return;
    await for (final FileSystemEntity e in root.list()) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      if (name.endsWith('.part')) continue;
      final String key = name.split('.').first;
      if (isPinned(key)) continue;
      try {
        await e.delete();
      } on FileSystemException {
        // 被占用的文件留到下次。
      }
    }
  });

  Future<void> _evictLocked({required String protect}) async {
    final Map<String, List<File>> byKey = <String, List<File>>{};
    final Map<String, DateTime> usedAt = <String, DateTime>{};
    int total = 0;
    await for (final FileSystemEntity e in root.list()) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      // 在写的临时文件属于正在进行的合成，不参与淘汰。
      if (name.endsWith('.part')) continue;
      final String key = name.split('.').first;
      final FileStat stat = await e.stat();
      total += stat.size;
      byKey.putIfAbsent(key, () => <File>[]).add(e);
      if (name.endsWith('.json')) usedAt[key] = stat.modified;
      usedAt.putIfAbsent(key, () => stat.modified);
    }
    if (total <= maxBytes) return;
    final List<String> order = byKey.keys.toList()
      ..sort((String a, String b) => usedAt[a]!.compareTo(usedAt[b]!));
    for (final String key in order) {
      if (total <= maxBytes) break;
      if (key == protect || isPinned(key)) continue;
      for (final File f in byKey[key]!) {
        try {
          final int size = await f.length();
          await f.delete();
          total -= size;
        } on FileSystemException {
          // Windows 上播放器仍持有的文件删不掉：跳过，下次再试。
        }
      }
    }
  }
}
