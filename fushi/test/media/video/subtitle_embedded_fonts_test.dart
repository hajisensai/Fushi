import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/subtitle_embedded_fonts.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// BUG-829：模拟「ffprobe 二进制根本不存在」——[CliFfmpegBackend] 底层 `Process.start`
/// 会抛 [ProcessException]（`系统找不到指定的文件。`）。用于验证枚举附件时被就地兜住、
/// 降级空集且不刷错误日志。
class _MissingFfprobeBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      throw const ProcessException('ffmpeg', <String>[]);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      throw const ProcessException('ffprobe', <String>[], '系统找不到指定的文件。', 2);
}

void _u16(List<int> out, int v) {
  out.add((v >> 8) & 0xFF);
  out.add(v & 0xFF);
}

void _u32(List<int> out, int v) {
  out
    ..add((v >> 24) & 0xFF)
    ..add((v >> 16) & 0xFF)
    ..add((v >> 8) & 0xFF)
    ..add(v & 0xFF);
}

/// 构造一个最小合法单字体 sfnt：仅一张 `name` 表，含一条 Windows(3) UTF-16BE 的
/// nameID=1（Family）记录 = [family]。用于验证 [parseSfntFamilyNames] 的解析路径。
Uint8List _buildSfntWithFamily(String family, {int nameId = 1}) {
  // name 表：format(0) count(1) stringOffset(6+12=18) + 1 记录 + 字符串存储。
  final List<int> nameUtf16 = <int>[];
  for (final int u in family.codeUnits) {
    nameUtf16
      ..add((u >> 8) & 0xFF)
      ..add(u & 0xFF);
  }
  final int strLen = nameUtf16.length;
  final List<int> nameTable = <int>[];
  _u16(nameTable, 0); // format
  _u16(nameTable, 1); // count
  _u16(nameTable, 18); // stringOffset (6 header + 12 record)
  // record: platformID=3, encodingID=1, languageID=0x0409, nameID, length, offset=0
  _u16(nameTable, 3);
  _u16(nameTable, 1);
  _u16(nameTable, 0x0409);
  _u16(nameTable, nameId);
  _u16(nameTable, strLen);
  _u16(nameTable, 0);
  nameTable.addAll(nameUtf16);

  const int nameOffset = 12 + 16; // sfnt header(12) + 1 table record(16)
  final List<int> out = <int>[];
  // sfnt header
  _u32(out, 0x00010000); // sfntVersion
  _u16(out, 1); // numTables
  _u16(out, 0); // searchRange
  _u16(out, 0); // entrySelector
  _u16(out, 0); // rangeShift
  // table record: tag 'name'
  out.addAll(<int>[0x6E, 0x61, 0x6D, 0x65]); // 'name'
  _u32(out, 0); // checksum
  _u32(out, nameOffset); // offset
  _u32(out, nameTable.length); // length
  out.addAll(nameTable);
  return Uint8List.fromList(out);
}

void main() {
  group('parseSfntFamilyNames', () {
    test('reads Windows UTF-16BE Family (nameID 1)', () {
      final Uint8List bytes = _buildSfntWithFamily('FOT-Matisse ProN B');
      expect(parseSfntFamilyNames(bytes), contains('FOT-Matisse ProN B'));
    });

    test('reads Typographic Family (nameID 16)', () {
      final Uint8List bytes =
          _buildSfntWithFamily('HYXuanSong 75S', nameId: 16);
      expect(parseSfntFamilyNames(bytes), contains('HYXuanSong 75S'));
    });

    test('non-font / truncated bytes degrade to empty (no throw)', () {
      expect(parseSfntFamilyNames(Uint8List.fromList(<int>[1, 2, 3])), isEmpty);
      expect(parseSfntFamilyNames(Uint8List(0)), isEmpty);
      // 合法头但 name 表 offset 越界 → 不崩、空集。
      final Uint8List truncated = _buildSfntWithFamily('X').sublist(0, 20);
      expect(parseSfntFamilyNames(truncated), isEmpty);
    });
  });

  group('parseFfprobeFontAttachments', () {
    test(
        'keeps font attachments, skips non-font, ordinal counts all '
        'attachment streams', () {
      const String json = '''
      {"streams":[
        {"index":0,"codec_type":"video"},
        {"index":1,"codec_type":"audio"},
        {"index":3,"codec_type":"attachment","codec_name":"ttf",
         "tags":{"filename":"matisse.ttf","mimetype":"application/x-truetype-font"}},
        {"index":4,"codec_type":"attachment","codec_name":"otf",
         "tags":{"filename":"hyxuansong.otf"}},
        {"index":5,"codec_type":"attachment",
         "tags":{"filename":"cover.jpg","mimetype":"image/jpeg"}},
        {"index":6,"codec_type":"attachment",
         "tags":{"filename":"noto.TTC","mimetype":"font/collection"}}
      ]}''';
      final List<EmbeddedFontAttachment> fonts =
          parseFfprobeFontAttachments(json);
      // matisse(ord0) + hyxuansong(ord1) + noto.TTC(ord3) are fonts; cover(ord2) not.
      expect(fonts.map((EmbeddedFontAttachment f) => f.attachmentOrdinal),
          <int>[0, 1, 3]);
      expect(fonts.map((EmbeddedFontAttachment f) => f.fileName),
          <String>['matisse.ttf', 'hyxuansong.otf', 'noto.TTC']);
    });

    test('empty / malformed json → empty list (no throw)', () {
      expect(parseFfprobeFontAttachments(''), isEmpty);
      expect(parseFfprobeFontAttachments('not json'), isEmpty);
      expect(parseFfprobeFontAttachments('{"streams":[]}'), isEmpty);
      expect(parseFfprobeFontAttachments('{"foo":1}'), isEmpty);
    });
  });

  group('SubtitleEmbeddedFontLoader missing-ffprobe degrade (BUG-829)', () {
    test('缺 ffprobe（ProcessException）时降级空集且不刷错误日志', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_embfont_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      // loadForVideo 要求本地文件存在才会去枚举附件。
      final File video = File(p.join(dir.path, 'clip.mkv'))
        ..writeAsBytesSync(<int>[0]);

      final int before = ErrorLogService.instance.entries.length;

      final SubtitleEmbeddedFontLoader loader =
          SubtitleEmbeddedFontLoader(backend: _MissingFfprobeBackend());
      final Set<String> families = await loader.loadForVideo(video.path);

      // 无 ffprobe → 无附件 → 空集，回退系统字体 fallback（不崩）。
      expect(families, isEmpty);

      // 关键回归：缺 ffprobe 二进制是预期降级，绝不作为「错误」刷进 ErrorLogService。
      final List<ErrorLogEntry> entries = ErrorLogService.instance.entries;
      expect(entries.length, before, reason: '缺 ffprobe 不应新增任何错误日志条目');
      expect(
        entries.where((ErrorLogEntry e) =>
            e.source == 'SubtitleEmbeddedFontLoader.loadForVideo'),
        isEmpty,
        reason: 'loadForVideo 不应把「无 ffprobe」记成错误',
      );
    });
  });
}
