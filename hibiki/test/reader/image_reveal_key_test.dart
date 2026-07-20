import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/image_reveal_key.dart';
import 'package:path/path.dart' as p;

/// BUG-898：阅读器 reveal key 与图片库磁盘 File 归一到同一稳定 key 的守护测试。
///
/// 稳定 key = extractDir 相对、percent-decode、正斜杠路径。normalize（阅读器回传）与
/// fromFile（图片库）必须对「同一张图」产出逐字相等的 key，否则书内↔图片库无法同步。
void main() {
  group('ImageRevealKey.normalize', () {
    test('hoshi.local https 绝对 URL 剥 /epub/ 得相对路径', () {
      expect(
        ImageRevealKey.normalize(
            'https://hoshi.local/epub/OEBPS/images/foo.jpg'),
        'OEBPS/images/foo.jpg',
      );
    });

    test('percent 编码解码（%20 → 空格），与磁盘真实文件名对齐', () {
      expect(
        ImageRevealKey.normalize(
            'https://hoshi.local/epub/OEBPS/images/foo%20bar.jpg'),
        'OEBPS/images/foo bar.jpg',
      );
    });

    test('macOS/iOS 自定义 scheme 变体同样剥前缀', () {
      expect(
        ImageRevealKey.normalize('hoshi-resource://hoshi.local/epub/cover.svg'),
        'cover.svg',
      );
    });

    test('已是相对路径原样归一（改造后的 JS 常态）', () {
      expect(ImageRevealKey.normalize('OEBPS/images/foo.jpg'),
          'OEBPS/images/foo.jpg');
    });

    test('../ 折叠到规范相对路径', () {
      expect(
        ImageRevealKey.normalize(
            'https://hoshi.local/epub/OEBPS/text/../images/x.jpg'),
        'OEBPS/images/x.jpg',
      );
    });

    test('空串返回 null', () {
      expect(ImageRevealKey.normalize(''), isNull);
    });

    test('反斜杠归一为正斜杠', () {
      expect(ImageRevealKey.normalize(r'OEBPS\images\foo.jpg'),
          'OEBPS/images/foo.jpg');
    });
  });

  group('ImageRevealKey.fromFile', () {
    test('extractDir 相对磁盘路径 → 正斜杠 key（跨平台）', () {
      final String extractDir = p.join('root', 'book', 'extract');
      final String file = p.join(extractDir, 'OEBPS', 'images', 'foo.jpg');
      expect(ImageRevealKey.fromFile(file, extractDir), 'OEBPS/images/foo.jpg');
    });

    test('extractDir 外的文件（../ 越界）返回 null', () {
      final String extractDir = p.join('root', 'book', 'extract');
      final String outside = p.join('root', 'other', 'foo.jpg');
      expect(ImageRevealKey.fromFile(outside, extractDir), isNull);
    });
  });

  group('两端一致性（同一张图 normalize == fromFile）', () {
    test('阅读器 URL key 与图片库 File key 对同一图逐字相等', () {
      // 图片库看到的磁盘文件（原生分隔符，用 p.join 构造保证跨平台）。
      final String extractDir = p.join('data', 'book', 'extract');
      final String file = p.join(extractDir, 'OEBPS', 'images', 'foo bar.jpg');
      // 阅读器 JS 看到的资源 URL（percent-encoded）。
      const String url = 'https://hoshi.local/epub/OEBPS/images/foo%20bar.jpg';
      final String? fromLib = ImageRevealKey.fromFile(file, extractDir);
      final String? fromReader = ImageRevealKey.normalize(url);
      expect(fromLib, 'OEBPS/images/foo bar.jpg');
      expect(fromReader, fromLib, reason: '两端 key 必须逐字相等才能共享持久化揭开状态');
    });
  });

  group('ImageRevealKey.shouldBlur（阅读器/图片库共用遮罩判据）', () {
    test('总开关关 → 从不遮罩（图片库始终原图）', () {
      expect(
        ImageRevealKey.shouldBlur(
            blurEnabled: false, revealKey: 'x', revealed: <String>{}),
        isFalse,
      );
    });

    test('已揭开 → 不遮罩（双向同步：DB 已含即不遮）', () {
      expect(
        ImageRevealKey.shouldBlur(
            blurEnabled: true, revealKey: 'x', revealed: <String>{'x'}),
        isFalse,
      );
    });

    test('开 + 未揭 → 遮罩', () {
      expect(
        ImageRevealKey.shouldBlur(
            blurEnabled: true, revealKey: 'x', revealed: <String>{}),
        isTrue,
      );
    });

    test('无归一 key → 不遮罩（不参与防剧透）', () {
      expect(
        ImageRevealKey.shouldBlur(
            blurEnabled: true, revealKey: null, revealed: <String>{}),
        isFalse,
      );
    });
  });
}
