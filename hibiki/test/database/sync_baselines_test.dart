import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  setUp(() => db = HibikiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('getSyncBaseline returns null when absent', () async {
    expect(await db.getSyncBaseline('BookA', 'progress'), isNull);
  });

  test('set then get round-trips and upserts', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    expect(await db.getSyncBaseline('BookA', 'progress'), 1000);
    await db.setSyncBaseline('BookA', 'progress', 2000);
    expect(await db.getSyncBaseline('BookA', 'progress'), 2000);
  });

  test('dimension is part of the key', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    expect(await db.getSyncBaseline('BookA', 'audiobook'), isNull);
  });

  test('deleteSyncBaselines removes all dimensions for asset', () async {
    await db.setSyncBaseline('BookA', 'progress', 1000);
    await db.deleteSyncBaselines('BookA');
    expect(await db.getSyncBaseline('BookA', 'progress'), isNull);
  });
}
