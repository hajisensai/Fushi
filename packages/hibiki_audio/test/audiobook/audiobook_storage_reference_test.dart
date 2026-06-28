import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/audiobook/audiobook_storage.dart';
import 'package:path/path.dart' as p;

/// TODO-935 ①A：「引用 vs 已复制」按路径与持久根从属关系派生，无额外标记列。
/// 这里固化派生判据与断链检测，确保删源守卫/重新定位入口的前提稳定。
void main() {
  // 用平台无关的绝对根构造路径，避免 Windows/POSIX 分隔符差异。
  final String root =
      p.join(p.rootPrefix(p.current), 'app', 'docs', 'audiobooks');

  group('isReferencedPath', () {
    test('复制导入（持久根之内）判为非引用', () {
      final String copied = p.join(root, 'abc12345', '01.m4a');
      expect(
        AudiobookStorage.isReferencedPath(filePath: copied, persistRoot: root),
        isFalse,
      );
    });

    test('引用导入（持久根之外）判为引用', () {
      final String referenced =
          p.join(p.rootPrefix(p.current), 'media', 'audio', '01.m4a');
      expect(
        AudiobookStorage.isReferencedPath(
            filePath: referenced, persistRoot: root),
        isTrue,
      );
    });

    test('持久根本身不判为引用（保守）', () {
      expect(
        AudiobookStorage.isReferencedPath(filePath: root, persistRoot: root),
        isFalse,
      );
    });

    test('空路径保守返回 false（按已复制处理，不误删源）', () {
      expect(
        AudiobookStorage.isReferencedPath(filePath: '', persistRoot: root),
        isFalse,
      );
      expect(
        AudiobookStorage.isReferencedPath(
            filePath: p.join(root, 'x.m4a'), persistRoot: ''),
        isFalse,
      );
    });
  });

  group('anyReferenced', () {
    test('全部在持久根内 → false', () {
      expect(
        AudiobookStorage.anyReferenced(
          paths: <String>[
            p.join(root, 'h', '1.m4a'),
            p.join(root, 'h', '2.m4a'),
          ],
          persistRoot: root,
        ),
        isFalse,
      );
    });

    test('任一在持久根外 → true', () {
      expect(
        AudiobookStorage.anyReferenced(
          paths: <String>[
            p.join(root, 'h', '1.m4a'),
            p.join(p.rootPrefix(p.current), 'ext', '2.m4a'),
          ],
          persistRoot: root,
        ),
        isTrue,
      );
    });

    test('空列表 → false', () {
      expect(
        AudiobookStorage.anyReferenced(
            paths: const <String>[], persistRoot: root),
        isFalse,
      );
    });
  });

  group('missingPaths / hasMissingPaths（注入假存在谓词）', () {
    bool fakeExists(String path) => path.endsWith('present.m4a');

    test('挑出断链路径，保持原序', () {
      final List<String> paths = <String>[
        '/a/present.m4a',
        '/a/gone.m4a',
        '/b/present.m4a',
        '/b/missing.m4a',
      ];
      expect(
        AudiobookStorage.missingPaths(paths, exists: fakeExists),
        <String>['/a/gone.m4a', '/b/missing.m4a'],
      );
      expect(
        AudiobookStorage.hasMissingPaths(paths, exists: fakeExists),
        isTrue,
      );
    });

    test('全部存在 → 无断链', () {
      final List<String> paths = <String>['/a/present.m4a', '/b/present.m4a'];
      expect(AudiobookStorage.missingPaths(paths, exists: fakeExists), isEmpty);
      expect(
          AudiobookStorage.hasMissingPaths(paths, exists: fakeExists), isFalse);
    });

    test('空列表 → 无断链', () {
      expect(AudiobookStorage.hasMissingPaths(const <String>[]), isFalse);
    });
  });
}
