// BUG-2496：封面写侧唯一入口必须拒收「非图片 / 截断图片」，否则渲染层只判
// existsSync，坏文件到 FileImage 就是 `Invalid image data`，且每次重建反复报。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

/// 最小合法 JPEG：SOI + APP0 段壳 + EOI（够魔数与尾标判定；不追求可渲染）。
List<int> minimalJpeg() => <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0xFF,
  0xD9,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDecodableImageBytes', () {
    test('完整 PNG / JPEG / GIF 通过', () {
      expect(isDecodableImageBytes(kTransparentImage), isTrue);
      expect(isDecodableImageBytes(minimalJpeg()), isTrue);
      expect(
        isDecodableImageBytes(<int>[
          0x47,
          0x49,
          0x46,
          0x38,
          0x39,
          0x61,
          1,
          0,
          1,
          0,
          0,
          0,
          0x3B,
        ]),
        isTrue,
      );
    });

    test('JPEG 尾部允许少量填充，但 EOI 不能不见', () {
      expect(
        isDecodableImageBytes(<int>[...minimalJpeg(), 0, 0, 0, 0]),
        isTrue,
      );
      final List<int> truncated = minimalJpeg().sublist(0, 18);
      expect(
        isDecodableImageBytes(truncated),
        isFalse,
        reason: '截断 JPEG 头部完全合法，只有查 EOI 才抓得住',
      );
    });

    test('截断 PNG（无 IEND）拒收', () {
      final List<int> truncated = kTransparentImage.sublist(
        0,
        kTransparentImage.length - 8,
      );
      expect(isDecodableImageBytes(truncated), isFalse);
    });

    test('HTML 错误页 / 空字节拒收', () {
      expect(isDecodableImageBytes('<!DOCTYPE html><html>'.codeUnits), isFalse);
      expect(isDecodableImageBytes(<int>[]), isFalse);
    });
  });

  group('writer 入口', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('hibiki_cover_w'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writeCoverBytesAtomically：非图片抛出、不动旧封面、不留 tmp', () async {
      final String dest = p.join(dir.path, 'cover.jpg');
      await writeCoverBytesAtomically(bytes: minimalJpeg(), destPath: dest);
      await expectLater(
        writeCoverBytesAtomically(
          bytes: '<html>404</html>'.codeUnits,
          destPath: dest,
        ),
        throwsA(isA<CoverImageInvalidException>()),
      );
      expect(File(dest).readAsBytesSync(), minimalJpeg());
      expect(
        dir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['cover.jpg'],
      );
    });

    test('copyCoverFileAtomically：源是截断 JPEG 时抛出', () async {
      final File src = File(p.join(dir.path, 'src.jpg'))
        ..writeAsBytesSync(minimalJpeg().sublist(0, 18));
      await expectLater(
        copyCoverFileAtomically(
          source: src,
          destPath: p.join(dir.path, 'cover.jpg'),
        ),
        throwsA(isA<CoverImageInvalidException>()),
      );
      expect(File(p.join(dir.path, 'cover.jpg')).existsSync(), isFalse);
    });

    test('stagedCoverPath 保留扩展名在末尾（ffmpeg 按扩展名选编码器）', () {
      final String staged = stagedCoverPath(p.join(dir.path, 'abc.jpg'));
      expect(p.extension(staged), '.jpg');
      expect(p.basename(staged), startsWith('abc.tmp.'));
      expect(p.dirname(staged), dir.path);
    });

    test('publishStagedCoverFile：完整图片发布到 dest，staged 消失', () async {
      final String dest = p.join(dir.path, 'cover.jpg');
      final File staged = File(stagedCoverPath(dest))
        ..writeAsBytesSync(minimalJpeg());
      await publishStagedCoverFile(staged: staged, destPath: dest);
      expect(File(dest).readAsBytesSync(), minimalJpeg());
      expect(staged.existsSync(), isFalse);
    });

    test('publishStagedCoverFile：半截文件抛出、删 staged、旧封面保留', () async {
      final String dest = p.join(dir.path, 'cover.jpg');
      await writeCoverBytesAtomically(bytes: minimalJpeg(), destPath: dest);
      final File staged = File(stagedCoverPath(dest))
        ..writeAsBytesSync(minimalJpeg().sublist(0, 18));
      await expectLater(
        publishStagedCoverFile(staged: staged, destPath: dest),
        throwsA(isA<CoverImageInvalidException>()),
      );
      expect(staged.existsSync(), isFalse, reason: '坏的 staged 文件必须清掉');
      expect(File(dest).readAsBytesSync(), minimalJpeg(), reason: '旧封面不动');
    });
  });
}
