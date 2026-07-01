import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// TODO-1045：M4B/M4A 容器 tag 自动填充导入对话框的纯函数层测试。
/// 覆盖 ffprobe 参数构造 + JSON 解析（含 ©nam→title 归一、缺 tag、空 tag、
/// 大小写不敏感、坏 JSON 降级）。纯函数无 IO，三端可跑。
void main() {
  group('buildFfprobeFormatTagsArgs', () {
    test('emits -show_format json probe args for the input path', () {
      expect(
        buildFfprobeFormatTagsArgs(inputPath: '/a/book.m4b'),
        <String>[
          '-v',
          'quiet',
          '-print_format',
          'json',
          '-show_format',
          '/a/book.m4b',
        ],
      );
    });

    test('carries an arbitrary path verbatim as the last arg', () {
      final List<String> args =
          buildFfprobeFormatTagsArgs(inputPath: r'C:\Books\日本語.m4b');
      expect(args.last, r'C:\Books\日本語.m4b');
      expect(args.first, '-v');
    });
  });

  group('parseAudioMetadataFromFfprobeJson', () {
    test('M4B ©nam/©ART/©alb normalized to title/artist/album', () {
      // ffprobe 把 iTunes 原子归一成 title/artist/album 键（模拟真实输出）。
      const String json = '''
{
  "format": {
    "filename": "book.m4b",
    "tags": {
      "title": "吾輩は猫である",
      "artist": "夏目漱石",
      "album": "青空文庫",
      "encoder": "Lavf"
    }
  }
}''';
      final AudioMetadata meta = parseAudioMetadataFromFfprobeJson(json);
      expect(meta.title, '吾輩は猫である');
      expect(meta.author, '夏目漱石');
      expect(meta.album, '青空文庫');
      expect(meta.isEmpty, isFalse);
    });

    test('case-insensitive tag keys (TITLE/Artist)', () {
      const String json = '''
{"format":{"tags":{"TITLE":"Uppercase","Artist":"Mixed"}}}''';
      final AudioMetadata meta = parseAudioMetadataFromFfprobeJson(json);
      expect(meta.title, 'Uppercase');
      expect(meta.author, 'Mixed');
      expect(meta.album, isNull);
    });

    test('blank/whitespace tag values normalize to null', () {
      const String json = '''
{"format":{"tags":{"title":"   ","artist":""}}}''';
      final AudioMetadata meta = parseAudioMetadataFromFfprobeJson(json);
      expect(meta.title, isNull);
      expect(meta.author, isNull);
      expect(meta.isEmpty, isTrue);
    });

    test('missing tags block yields empty metadata', () {
      const String json = '{"format":{"filename":"x.m4b"}}';
      final AudioMetadata meta = parseAudioMetadataFromFfprobeJson(json);
      expect(meta.isEmpty, isTrue);
    });

    test('empty / malformed JSON degrades to empty metadata (never throws)',
        () {
      expect(parseAudioMetadataFromFfprobeJson('').isEmpty, isTrue);
      expect(parseAudioMetadataFromFfprobeJson('not json {').isEmpty, isTrue);
      expect(parseAudioMetadataFromFfprobeJson('[1,2,3]').isEmpty, isTrue);
      expect(
        parseAudioMetadataFromFfprobeJson('{"format":"scalar"}').isEmpty,
        isTrue,
      );
    });

    test('partial tags: title only, author only', () {
      expect(
        parseAudioMetadataFromFfprobeJson(
          '{"format":{"tags":{"title":"Only Title"}}}',
        ).author,
        isNull,
      );
      expect(
        parseAudioMetadataFromFfprobeJson(
          '{"format":{"tags":{"artist":"Only Author"}}}',
        ).title,
        isNull,
      );
    });
  });

  group('AudioMetadata value object', () {
    test('isEmpty reflects all-null fields', () {
      expect(const AudioMetadata().isEmpty, isTrue);
      expect(const AudioMetadata(title: 'x').isEmpty, isFalse);
      expect(const AudioMetadata(author: 'x').isEmpty, isFalse);
      expect(const AudioMetadata(album: 'x').isEmpty, isFalse);
    });
  });
}
