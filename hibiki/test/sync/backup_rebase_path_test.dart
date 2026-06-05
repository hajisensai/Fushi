import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';

void main() {
  group('rebasePath', () {
    test('replaces the old root prefix with the new root (posix)', () {
      expect(
        rebasePath('/old/app/hoshi_books/MyBook/original.epub',
            '/old/app/hoshi_books', '/new/app/hoshi_books'),
        '/new/app/hoshi_books/MyBook/original.epub',
      );
    });

    test('replaces the old root prefix (windows backslash)', () {
      expect(
        rebasePath(r'C:\OldA\hoshi_books\Bk\cover.jpg', r'C:\OldA\hoshi_books',
            r'D:\NewB\hoshi_books'),
        r'D:\NewB\hoshi_books\Bk\cover.jpg',
      );
    });

    test('returns the path unchanged when it is not under the old root', () {
      expect(
        rebasePath('/somewhere/else/x.epub', '/old/app/hoshi_books',
            '/new/app/hoshi_books'),
        '/somewhere/else/x.epub',
      );
    });

    test('maps the root itself to the new root', () {
      expect(
        rebasePath('/old/app/hoshi_books', '/old/app/hoshi_books',
            '/new/app/hoshi_books'),
        '/new/app/hoshi_books',
      );
    });

    test('tolerates a trailing separator on the old root', () {
      expect(
        rebasePath('/old/hoshi_books/Bk/f.epub', '/old/hoshi_books/',
            '/new/hoshi_books'),
        '/new/hoshi_books/Bk/f.epub',
      );
    });

    test('does not treat a sibling sharing a name prefix as under the root',
        () {
      // "/old/hoshi_books_extra" must NOT match root "/old/hoshi_books".
      expect(
        rebasePath('/old/hoshi_books_extra/f.epub', '/old/hoshi_books',
            '/new/hoshi_books'),
        '/old/hoshi_books_extra/f.epub',
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
        booksRoot: '/old/app/hoshi_books',
        audiobooksRoot: '/old/app/audiobooks',
      );
      final back = BackupMeta.fromJson(m.toJson());
      expect(back.booksRoot, '/old/app/hoshi_books');
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
