import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-933：制卡媒体的 sha256 文件名与 base64 编码从 UI isolate 卸到后台 isolate。
/// 这里锁定「异步 helper 的结果与同步计算逐字节一致」（大媒体真走 [Isolate.run]），
/// 并用源码扫描守卫防止调用点回退到会阻塞 UI 的同步版本。
void main() {
  group('BUG-933 制卡媒体后台 isolate 卸载', () {
    // 大于阈值（64KB）→ 真正走 Isolate.run；小于阈值 → 同步分支。两条都要与直算一致。
    final Uint8List big = Uint8List.fromList(
      List<int>.generate(200 * 1024, (int i) => (i * 31 + 7) & 0xff),
    );
    final Uint8List small = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

    test('fushiAnkiMediaEncodeForUploadAsync：文件名+base64 与同步计算一致（大媒体走隔离）',
        () async {
      final encoded = await fushiAnkiMediaEncodeForUploadAsync(
        prefix: 'hibiki_audio_',
        bytes: big,
        sourceName: 'clip.mp3',
      );
      expect(
        encoded.filename,
        fushiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_audio_',
          bytes: big,
          sourceName: 'clip.mp3',
        ),
      );
      expect(encoded.base64Data, base64Encode(big));
    });

    test('fushiAnkiMediaEncodeForUploadAsync：小媒体走同步分支也一致', () async {
      final encoded = await fushiAnkiMediaEncodeForUploadAsync(
        prefix: 'hibiki_cover_',
        bytes: small,
        sourceName: 'x.jpg',
      );
      expect(
        encoded.filename,
        fushiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_cover_',
          bytes: small,
          sourceName: 'x.jpg',
        ),
      );
      expect(encoded.base64Data, base64Encode(small));
    });

    test('fushiAnkiMediaFilenameForBytesAsync 与同步版逐字节一致（大/小两路）', () async {
      expect(
        await fushiAnkiMediaFilenameForBytesAsync(
          prefix: 'hibiki_audio_',
          bytes: big,
          sourceName: 'clip.mp3',
        ),
        fushiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_audio_',
          bytes: big,
          sourceName: 'clip.mp3',
        ),
      );
      expect(
        await fushiAnkiMediaFilenameForBytesAsync(
          prefix: 'hibiki_audio_',
          bytes: small,
          sourceName: 'clip.mp3',
        ),
        fushiAnkiMediaFilenameForBytes(
          prefix: 'hibiki_audio_',
          bytes: small,
          sourceName: 'clip.mp3',
        ),
      );
    });

    test('fushiAnkiBase64EncodeAsync 与 base64Encode 一致（大/小两路）', () async {
      expect(await fushiAnkiBase64EncodeAsync(big), base64Encode(big));
      expect(await fushiAnkiBase64EncodeAsync(small), base64Encode(small));
    });
  });

  group('BUG-933 源码守卫：制卡媒体路径不得同步跑 CPU 重活', () {
    File _pkgFile(String relative) {
      // 测试 cwd 为包目录（packages/fushi_anki）。
      final File f = File(relative);
      expect(f.existsSync(), isTrue,
          reason: '找不到 $relative（cwd=${Directory.current.path}）');
      return f;
    }

    test('ankidroid/anki_repository.dart 不直接调用同步 sha256/ base64', () {
      final String src =
          _pkgFile('lib/src/ankidroid/anki_repository.dart').readAsStringSync();
      // 同步文件名/编码会在 UI isolate 对整段媒体跑纯 Dart 循环 → 卡顿。必须走
      // ...Async 变体（Async 后缀不匹配 `(` 前的裸调用）。
      expect(
        RegExp(r'fushiAnkiMediaFilenameForBytes\(').hasMatch(src),
        isFalse,
        reason: 'AnkiDroid 应改用 fushiAnkiMediaFilenameForBytesAsync',
      );
      expect(
        RegExp(r'\bbase64Encode\(').hasMatch(src),
        isFalse,
        reason: 'AnkiDroid 媒体走 platform channel，不该在此 base64 编码',
      );
    });

    test('ankiconnect_repository.dart 本机走 path、远端才走后台 base64', () {
      final String src =
          _pkgFile('lib/src/ankiconnect/ankiconnect_repository.dart')
              .readAsStringSync();
      expect(
        RegExp(r'fushiAnkiMediaEncodeForUploadAsync\(').allMatches(src).length,
        1,
        reason: '合并编码 helper 只保留 API 定义；本机媒体不得再构造整份 base64',
      );
      expect(
        src,
        contains('service.canReadLocalMediaPaths'),
        reason: '本机/远端 AnkiConnect 必须分流',
      );
      expect(
        src,
        contains('path: file.absolute.path'),
        reason: '本机 Anki 应直接读取临时媒体路径，避免巨大 JSON',
      );
      expect(
        RegExp(r'fushiAnkiBase64EncodeAsync\(').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '远端 AnkiConnect 仍须保留后台 base64 回退',
      );
      expect(
        RegExp(r'fushiAnkiMediaFilenameForBytesAsync\(').hasMatch(src),
        isTrue,
        reason: '远端音频文件名应走后台 sha256',
      );
    });
  });
}
