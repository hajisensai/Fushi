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

  test('save with ttuCharOffset then same-section null preserves it', () async {
    await repo.save(
      ttuBookId: 42,
      sectionIndex: 3,
      normCharOffset: 100,
      ttuCharOffset: 500,
    );
    var pos = await repo.findByTtuBookId(42);
    expect(pos, isNotNull);
    expect(pos!.ttuCharOffset, equals(500));

    await repo.save(
      ttuBookId: 42,
      sectionIndex: 3,
      normCharOffset: 200,
    );
    pos = await repo.findByTtuBookId(42);
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(3));
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.ttuCharOffset, equals(500),
        reason: 'same-section null save may preserve ttuCharOffset');
  });

  test('cross-section null save invalidates local ttuCharOffset', () async {
    await repo.save(
      ttuBookId: 42,
      sectionIndex: 3,
      normCharOffset: 100,
      ttuCharOffset: 500,
    );

    await repo.save(
      ttuBookId: 42,
      sectionIndex: 4,
      normCharOffset: 200,
    );
    final pos = await repo.findByTtuBookId(42);
    expect(pos, isNotNull);
    expect(pos!.sectionIndex, equals(4), reason: 'sectionIndex should update');
    expect(pos.normCharOffset, equals(200),
        reason: 'normCharOffset should update');
    expect(pos.ttuCharOffset, isNull,
        reason: 'section-local ttuCharOffset must not survive section changes');
  });

  test('save with ttuCharOffset then save with new value updates it', () async {
    await repo.save(
      ttuBookId: 42,
      sectionIndex: 3,
      normCharOffset: 100,
      ttuCharOffset: 500,
    );
    await repo.save(
      ttuBookId: 42,
      sectionIndex: 5,
      normCharOffset: 300,
      ttuCharOffset: 800,
    );
    final pos = await repo.findByTtuBookId(42);
    expect(pos!.ttuCharOffset, equals(800));
  });

  test('DB default -1 maps to model null for old data', () async {
    await db.into(db.readerPositions).insert(ReaderPositionsCompanion.insert(
          ttuBookId: 99,
          sectionIndex: 0,
          normCharOffset: 50,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    final pos = await repo.findByTtuBookId(99);
    expect(pos, isNotNull);
    expect(pos!.ttuCharOffset, isNull,
        reason: 'DB -1 should map to model null');
  });
}
