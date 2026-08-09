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
