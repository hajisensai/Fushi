import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  late HibikiDatabase db;
  late ReaderPositionRepository repo;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = ReaderPositionRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('save with charOffset then same-section null preserves it', () async {
    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );
    var pos = await repo.findByBookKey('book-42');
    expect(pos, isNotNull);
    expect(pos!.charOffset, equals(500));

    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 3,
      normCharOffset: 200,
    );
    pos = await repo.findByBookKey('book-42');
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(3));
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.charOffset, equals(500),
        reason: 'same-section null save may preserve charOffset');
  });

  test('cross-section null save invalidates local charOffset', () async {
    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );

    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 4,
      normCharOffset: 200,
    );
    final pos = await repo.findByBookKey('book-42');
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(4), reason: 'sectionIndex should update');
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.charOffset, isNull,
        reason: 'section-local charOffset must not survive section changes');
  });

  test('save with charOffset then save with new value updates it', () async {
    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 3,
      normCharOffset: 100,
      charOffset: 500,
    );
    await repo.save(
      bookKey: 'book-42',
      sectionIndex: 5,
      normCharOffset: 300,
      charOffset: 800,
    );
    final pos = await repo.findByBookKey('book-42');
    expect(pos!.charOffset, equals(800));
  });

  test('DB default -1 maps to model null for old data', () async {
    await db.into(db.readerPositions).insert(ReaderPositionsCompanion.insert(
          bookKey: 'book-99',
          sectionIndex: 0,
          normCharOffset: 50,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    final pos = await repo.findByBookKey('book-99');
    expect(pos, isNotNull);
    expect(pos!.charOffset, isNull,
        reason: 'DB -1 should map to model null');
  });

  test('findByTtuBookId returns null for absent book', () async {
    expect(await repo.findByBookKey('book-999'), isNull);
  });

  test('delete removes position', () async {
    await repo.save(
      bookKey: 'book-10',
      sectionIndex: 1,
      normCharOffset: 500,
    );
    await repo.delete('book-10');
    expect(await repo.findByBookKey('book-10'), isNull);
  });

  test('save→restore round-trip preserves all model fields', () async {
    await repo.save(
      bookKey: 'book-7',
      sectionIndex: 5,
      normCharOffset: 3000,
      charOffset: 250,
    );
    final pos = await repo.findByBookKey('book-7');
    expect(pos, isNotNull);
    expect(pos!.bookKey, 'book-7');
    expect(pos.sectionIndex, 5);
    expect(pos.normCharOffset, 3000);
    expect(pos.charOffset, 250);
    expect(pos.updatedAt, greaterThan(0));
    expect(pos.id, isNotNull);
  });

  test('normCharOffset boundary: chapter start (0)', () async {
    await repo.save(bookKey: 'book-1', sectionIndex: 0, normCharOffset: 0);
    final pos = await repo.findByBookKey('book-1');
    expect(pos!.normCharOffset, 0);
  });

  test('normCharOffset boundary: chapter end (10000)', () async {
    await repo.save(bookKey: 'book-2', sectionIndex: 0, normCharOffset: 10000);
    final pos = await repo.findByBookKey('book-2');
    expect(pos!.normCharOffset, 10000);
  });

  test('multiple books have independent positions', () async {
    await repo.save(bookKey: 'book-1', sectionIndex: 3, normCharOffset: 1000);
    await repo.save(bookKey: 'book-2', sectionIndex: 7, normCharOffset: 5000);

    final pos1 = await repo.findByBookKey('book-1');
    final pos2 = await repo.findByBookKey('book-2');
    expect(pos1!.sectionIndex, 3);
    expect(pos2!.sectionIndex, 7);
  });

  test('first save with null charOffset keeps DB default', () async {
    await repo.save(bookKey: 'book-50', sectionIndex: 0, normCharOffset: 100);
    final pos = await repo.findByBookKey('book-50');
    expect(pos!.charOffset, isNull,
        reason:
            'first save without charOffset → DB default -1 → model null');
  });
}
