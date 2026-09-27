import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_alignment_backup.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_reference_alignment.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_time_rewriter.dart';

/// 一集里的开口时刻（间隔 1.5–6 秒）。
List<double> _speech(int seed) {
  final math.Random r = math.Random(seed);
  final List<double> out = <double>[];
  double t = 20;
  while (t < 1400) {
    out.add(t);
    t += 1.5 + r.nextDouble() * 4.5;
  }
  return out;
}

/// 按开始时刻生成一份 SRT（每句 1.2 秒）。
Uint8List _srt(Iterable<double> starts) {
  String ts(double s) {
    final int ms = (s * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two((ms ~/ 60000) % 60)}:'
        '${two((ms ~/ 1000) % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final StringBuffer b = StringBuffer();
  int i = 1;
  for (final double s in starts) {
    b.write('${i++}\n${ts(s)} --> ${ts(s + 1.2)}\nline\n\n');
  }
  return Uint8List.fromList(b.toString().codeUnits);
}

void main() {
  late Directory tmp;
  late File video;
  late EnginePaths saved;
  final List<double> truth = _speech(3);
  final List<double> refStarts = truth.where((double t) => t % 7 > 1).toList();

  Future<List<SubtitleReferenceTrack>> refs(
    String _,
  ) async => <SubtitleReferenceTrack>[
    SubtitleReferenceTrack(label: 'eng', starts: uniqueCueStarts(refStarts)),
  ];
  Future<int?> duration(String _) async => 1440000;

  setUp(() {
    saved = enginePaths;
    tmp = Directory.systemTemp.createTempSync('ref_sync_test');
    video = File('${tmp.path}/ep.mkv')..writeAsBytesSync(<int>[0]);
    enginePaths = FixedEnginePaths(documents: tmp, support: tmp, temp: tmp);
  });

  tearDown(() {
    enginePaths = saved;
    tmp.deleteSync(recursive: true);
  });

  test('自动路径：证据足够就写对齐结果，并能用结果反查到原稿', () async {
    final Uint8List original = _srt(truth.map((double t) => t + 4));
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      video.path,
      loadReferences: refs,
      probeDurationMs: duration,
    );
    expect(out, isNot(same(original)));
    expect(alignableCueStartSeconds(out).first, closeTo(truth.first, 0.01));
    expect(await findSubtitleAlignmentOriginal(out), original);
  });

  test('自动路径：本来就对齐 → 原样返回、不留备份', () async {
    final Uint8List original = _srt(truth);
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      video.path,
      loadReferences: refs,
      probeDurationMs: duration,
    );
    expect(out, same(original));
    expect(await findSubtitleAlignmentOriginal(out), isNull);
  });

  test('自动路径：错集 → 原样返回', () async {
    final Uint8List original = _srt(_speech(99));
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      video.path,
      loadReferences: refs,
      probeDurationMs: duration,
    );
    expect(out, same(original));
  });

  test('自动路径：备份写不了就放弃对齐，写原稿', () async {
    enginePaths = const UninstalledEnginePaths();
    final Uint8List original = _srt(truth.map((double t) => t + 4));
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      video.path,
      loadReferences: refs,
      probeDurationMs: duration,
    );
    expect(out, same(original));
  });

  test('视频文件不存在（远端流）→ 原样返回，不读参考', () async {
    final Uint8List original = _srt(truth.map((double t) => t + 4));
    bool loaded = false;
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      'https://example.com/ep.mkv',
      loadReferences: (String _) async {
        loaded = true;
        return const <SubtitleReferenceTrack>[];
      },
      probeDurationMs: duration,
    );
    expect(out, same(original));
    expect(loaded, isFalse);
  });

  test('参考加载抛异常 → 降级为 noReference，原样', () async {
    final Uint8List original = _srt(truth);
    final EmbeddedReferenceSyncResult r =
        await syncSubtitleToEmbeddedReferences(
          subtitleBytes: original,
          videoPath: video.path,
          loadReferences: (String _) async => throw StateError('ffmpeg gone'),
        );
    expect(r.status, EmbeddedReferenceSyncStatus.noReference);
    expect(r.bytesForAutomaticPath, same(original));
  });

  test('开关：每次调用现读，关着原样返回且不调用对齐器', () async {
    bool enabled = false;
    int calls = 0;
    final AutomaticSubtitleAligner gated = gatedAutomaticSubtitleAligner(
      () => enabled,
      aligner: (Uint8List bytes, String path) async {
        calls++;
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );
    final Uint8List original = _srt(truth);
    expect(await gated(original, video.path), same(original));
    expect(calls, 0);
    enabled = true;
    expect(await gated(original, video.path), <int>[1, 2, 3]);
    expect(calls, 1);
  });

  test('isSubtitleAlignmentProduct：对齐写下的档认得出，原稿 / 不存在的档不认', () async {
    final Uint8List original = _srt(truth.map((double t) => t + 4));
    final Uint8List out = await alignSubtitleForAutomaticPath(
      original,
      video.path,
      loadReferences: refs,
      probeDurationMs: duration,
    );
    final File alignedFile = File('${tmp.path}/ep.ja.srt')
      ..writeAsBytesSync(out);
    final File originalFile = File('${tmp.path}/ep.orig.srt')
      ..writeAsBytesSync(original);
    expect(await isSubtitleAlignmentProduct(alignedFile.path), isTrue);
    expect(await isSubtitleAlignmentProduct(originalFile.path), isFalse);
    expect(
      await isSubtitleAlignmentProduct('${tmp.path}/missing.srt'),
      isFalse,
    );
  });

  test('isNetworkMediaPath：UNC 与 smb:// / nfs:// 等 URI 认作网络，本机路径不认', () {
    for (final String path in <String>[
      r'\\nas\anime\ep01.mkv',
      r'\\?\UNC\nas\anime\ep01.mkv',
      '//nas/anime/ep01.mkv',
      'smb://nas/anime/ep01.mkv',
      'nfs://nas/anime/ep01.mkv',
      'https://example.com/ep01.mkv',
    ]) {
      expect(isNetworkMediaPath(path), isTrue, reason: path);
    }
    for (final String path in <String>[
      r'C:\anime\ep01.mkv',
      'D:/anime/ep01.mkv',
      '/home/me/anime/ep01.mkv',
      r'anime\ep01.mkv',
    ]) {
      expect(isNetworkMediaPath(path), isFalse, reason: path);
    }
  });

  test('formatAlignmentOffsets', () {
    expect(
      formatAlignmentOffsets(const <AlignmentSegment>[
        AlignmentSegment(splitSeconds: 120, offsetSeconds: 0),
        AlignmentSegment(splitSeconds: null, offsetSeconds: -9.724),
      ]),
      '0.00s / -9.72s',
    );
    expect(
      formatAlignmentOffsets(const <AlignmentSegment>[
        AlignmentSegment(splitSeconds: null, offsetSeconds: 1.5),
      ]),
      '+1.50s',
    );
  });
}
