import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';

void main() {
  group('rebasePath', () {
    test('replaces the old root prefix with the new root (posix)', () {
      expect(
        rebasePath('/old/app/fushi_books/MyBook/original.epub',
            '/old/app/fushi_books', '/new/app/fushi_books'),
        '/new/app/fushi_books/MyBook/original.epub',
      );
    });

    test('replaces the old root prefix (windows backslash)', () {
      expect(
        rebasePath(r'C:\OldA\fushi_books\Bk\cover.jpg', r'C:\OldA\fushi_books',
            r'D:\NewB\fushi_books'),
        r'D:\NewB\fushi_books\Bk\cover.jpg',
      );
    });

    // BUG-3811（反馈 XDtB1kYT0C）：Windows 备份合并到 Android。POSIX 上 `\` 是普通
    // 文件名字符，保留源分隔符 = `/data/.../audiobooks\d4515d05\a.m4b` 这一个不存在
    // 的文件名，音频永远解析不到。
    test('a Windows source path rebased onto a POSIX root uses only "/"', () {
      expect(
        rebasePath(
          r'C:\Users\u\AppData\Roaming\fushi\audiobooks\d4515d05\a.m4b',
          r'C:\Users\u\AppData\Roaming\fushi\audiobooks',
          '/data/user/0/app.fushi/app_flutter/audiobooks',
        ),
        '/data/user/0/app.fushi/app_flutter/audiobooks/d4515d05/a.m4b',
      );
    });

    test('a mixed-separator Windows source path onto a POSIX root', () {
      expect(
        rebasePath(r'C:\Old\fushi_books\Bk/OEBPS\cover.jpg',
            r'C:\Old\fushi_books', '/new/fushi_books/'),
        '/new/fushi_books/Bk/OEBPS/cover.jpg',
      );
    });

    test('a Windows target keeps the source sub-path bytes verbatim', () {
      // Windows 两种分隔符都认；不改字节 = DataRootMigrator 等同机调用方零变化。
      expect(
        rebasePath(r'C:\Old\fushi_books\Bk/f.epub', r'C:\Old\fushi_books',
            r'D:\New\fushi_books'),
        r'D:\New\fushi_books\Bk/f.epub',
      );
      expect(
        rebasePath('/old/audiobooks/u1/a.mp3', '/old/audiobooks',
            r'D:\New\audiobooks'),
        r'D:\New\audiobooks/u1/a.mp3',
      );
    });

    test('returns the path unchanged when it is not under the old root', () {
      expect(
        rebasePath('/somewhere/else/x.epub', '/old/app/fushi_books',
            '/new/app/fushi_books'),
        '/somewhere/else/x.epub',
      );
    });

    test('maps the root itself to the new root', () {
      expect(
        rebasePath('/old/app/fushi_books', '/old/app/fushi_books',
            '/new/app/fushi_books'),
        '/new/app/fushi_books',
      );
    });

    test('tolerates a trailing separator on the old root', () {
      expect(
        rebasePath('/old/fushi_books/Bk/f.epub', '/old/fushi_books/',
            '/new/fushi_books'),
        '/new/fushi_books/Bk/f.epub',
      );
    });

    test('does not treat a sibling sharing a name prefix as under the root',
        () {
      // "/old/fushi_books_extra" must NOT match root "/old/fushi_books".
      expect(
        rebasePath('/old/fushi_books_extra/f.epub', '/old/fushi_books',
            '/new/fushi_books'),
        '/old/fushi_books_extra/f.epub',
      );
    });
  });

  group('BackupMeta content roots', () {
    test('round-trips booksRoot/audiobooksRoot through json', () {
      final m = BackupMeta(
        appVersion: '1.0',
        schemaVersion: 16,
        createdAt: DateTime(2026, 6, 5),
        bookCount: 2,
        statsCount: 0,
        booksRoot: '/old/app/fushi_books',
        audiobooksRoot: '/old/app/audiobooks',
      );
      final back = BackupMeta.fromJson(m.toJson());
      expect(back.booksRoot, '/old/app/fushi_books');
      expect(back.audiobooksRoot, '/old/app/audiobooks');
    });

    test('tolerates a legacy (db-only) backup with no roots → null', () {
      final legacy = BackupMeta.fromJson(<String, dynamic>{
        'appVersion': '0.9',
        'schemaVersion': 14,
        'createdAt': DateTime(2026).toIso8601String(),
      });
      expect(legacy.booksRoot, isNull);
      expect(legacy.audiobooksRoot, isNull);
      // And a meta without roots must not emit the keys.
      expect(legacy.toJson().containsKey('booksRoot'), isFalse);
      expect(legacy.toJson().containsKey('audiobooksRoot'), isFalse);
    });
  });
}
