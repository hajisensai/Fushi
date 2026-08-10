import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1490 第二环：加载失败的**原因**必须留下来。
///
/// 原实现里 `_loadExternalCues` / `_loadEmbeddedCues` 把「格式不支持」「图形轨」
/// 「ffmpeg 抽取失败」「文件读不出」「解析不出 cue」五种根因统统 `catch (_)` 成
/// 一个空 `List<AudioCue>`，UI 只能拿同一句「可能是图形或不支持的字幕轨」兜底。
/// 用户拿着一个明明是文本 ASS 的 UTF-16 文件看到「不支持」，被引向错误的方向。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hibiki_subfail_');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  String pathOf(String name) => '${dir.path}${Platform.pathSeparator}$name';

  Future<SubtitleCueLoadResult> loadExternal(String path) {
    return loadSubtitleCueResult(
      SubtitleSource.external(externalPath: path, label: 'test'),
      pathOf('video.mkv'),
      'book-uid',
    );
  }

  test('扩展名不受支持 → unsupportedFormat', () async {
    final File f = File(pathOf('notes.txt'));
    await f.writeAsString('hello');
    final SubtitleCueLoadResult r = await loadExternal(f.path);
    expect(r.isFailure, isTrue);
    expect(r.failure, SubtitleCueLoadFailure.unsupportedFormat);
  });

  test('文件不存在 → fileUnreadable（不是 unsupportedFormat）', () async {
    final SubtitleCueLoadResult r = await loadExternal(pathOf('missing.ass'));
    expect(r.failure, SubtitleCueLoadFailure.fileUnreadable);
  });

  test('扩展名对但内容里没有任何 cue → parseFailed', () async {
    final File f = File(pathOf('empty.ass'));
    await f.writeAsString('[Script Info]\nScriptType: v4.00+\n');
    final SubtitleCueLoadResult r = await loadExternal(f.path);
    expect(r.failure, SubtitleCueLoadFailure.parseFailed);
  });

  test('UTF-16LE + BOM 的 ASS 现在加载成功（原始失败路径）', () async {
    final File f = File(pathOf('sample.tc.ass'));
    await f.writeAsBytes(_utf16leWithBom(_minimalAss), flush: true);
    final SubtitleCueLoadResult r = await loadExternal(f.path);
    expect(r.isFailure, isFalse, reason: 'UTF-16LE 字幕在桌面端必须能加载（BUG-1490）');
    expect(r.failure, isNull);
    expect(r.cues.length, 2);
    expect(r.cues.first.text, '吾輩は猫である。');
  });

  test('成功时 cues 非空、failure 为 null（结果不变式）', () async {
    final File f = File(pathOf('utf8.ass'));
    await f.writeAsBytes(utf8.encode(_minimalAss), flush: true);
    final SubtitleCueLoadResult r = await loadExternal(f.path);
    expect(r.cues.isNotEmpty, r.failure == null);
  });

  test('loadCuesForSource 仍是丢原因的薄封装，行为不变（向后兼容）', () async {
    final File f = File(pathOf('compat.ass'));
    await f.writeAsBytes(_utf16leWithBom(_minimalAss), flush: true);
    final List<AudioCue> cues = await loadCuesForSource(
      SubtitleSource.external(externalPath: f.path, label: 'test'),
      pathOf('video.mkv'),
      'book-uid',
    );
    expect(cues.length, 2);

    final List<AudioCue> none = await loadCuesForSource(
      SubtitleSource.external(externalPath: pathOf('gone.ass'), label: 'x'),
      pathOf('video.mkv'),
      'book-uid',
    );
    expect(none, isEmpty, reason: '失败仍返回空列表，老调用方不受影响');
  });

  group('UI 文案分流守卫（源码扫描）', () {
    late String src;

    setUpAll(() {
      src = File('lib/src/pages/implementations/video_fushi/subtitle.part.dart')
          .readAsStringSync();
    });

    test('存在按失败原因分流文案的映射函数', () {
      expect(
        src.contains('String _subtitleFailureMessage('),
        isTrue,
        reason: '失败文案必须由 SubtitleCueLoadFailure 决定，而非一句话兜底',
      );
    });

    test('读不出/解不出用 video_subtitle_read_failed，不再谎报「不支持的轨」', () {
      final int start = src.indexOf('String _subtitleFailureMessage(');
      expect(start, greaterThan(-1));
      final String body = src.substring(start, start + 900);
      expect(body.contains('SubtitleCueLoadFailure.fileUnreadable'), isTrue);
      expect(body.contains('SubtitleCueLoadFailure.parseFailed'), isTrue);
      expect(
        body.contains('t.video_subtitle_read_failed(label: label)'),
        isTrue,
        reason: '解码/解析失败必须给「无法读取该字幕文件」而不是「不支持的字幕轨」',
      );
      expect(
        body.contains('t.video_subtitle_load_failed(label: label)'),
        isTrue,
        reason: '真正的图形轨/不支持格式仍用旧文案',
      );
    });

    test('主/副字幕选择都走 loadSubtitleCueResult 而非丢原因的 loadCuesForSource', () {
      expect(
        'loadSubtitleCueResult(source, videoPath'.allMatches(src).length,
        2,
        reason: '主字幕与副字幕两条选择路径都必须保留失败原因',
      );
    });
  });
}

/// 最小 ASS 夹具（与 text_file_io_encoding_test 同构，故意各自持有一份，
/// 避免跨测试文件的隐式耦合）。
const String _minimalAss = '[Script Info]\r\n'
    'ScriptType: v4.00+\r\n'
    '\r\n'
    '[Events]\r\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n'
    'Dialogue: 0,0:00:01.00,0:00:04.23,Default,,0,0,0,,吾輩は猫である。\r\n'
    'Dialogue: 0,0:00:04.50,0:00:08.10,Default,,0,0,0,,名前はまだない。\r\n';

Uint8List _utf16leWithBom(String text) {
  final List<int> units = text.codeUnits;
  final ByteData data = ByteData((units.length + 1) * 2);
  data.setUint16(0, 0xFEFF, Endian.little);
  for (int i = 0; i < units.length; i++) {
    data.setUint16(2 + i * 2, units[i], Endian.little);
  }
  return data.buffer.asUint8List();
}
