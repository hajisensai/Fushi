import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/builtin_tags.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('TODO-1166 built-in star rating tags', () {
    test('constants: 5 star tags named 1..5 + star, colors 1:1', () {
      expect(kBuiltInStarTagNames, hasLength(5));
      expect(kBuiltInStarTagColors, hasLength(5));
      for (int i = 0; i < 5; i++) {
        // "<n><U+2B50 star>" e.g. "1⭐".
        expect(kBuiltInStarTagNames[i], '${i + 1}⭐');
      }
    });

    test('fresh pool: seeds exactly 1..5 stars in ascending sortOrder',
        () async {
      final FushiDatabase db = await _openDb();

      final int added = await seedStarRatingTags(db);
      expect(added, 5);

      final List<BookTagRow> tags = await db.getAllTags(); // sortOrder asc
      expect(tags.map((BookTagRow t) => t.name).toList(), kBuiltInStarTagNames);
      expect(tags.map((BookTagRow t) => t.colorValue).toList(),
          kBuiltInStarTagColors);
      // sortOrder strictly ascending in seed order.
      for (int i = 1; i < tags.length; i++) {
        expect(tags[i].sortOrder, greaterThan(tags[i - 1].sortOrder));
      }
    });

    test('idempotent: second call adds nothing, no duplicate rows', () async {
      final FushiDatabase db = await _openDb();

      expect(await seedStarRatingTags(db), 5);
      expect(await seedStarRatingTags(db), 0);

      final List<BookTagRow> tags = await db.getAllTags();
      expect(tags, hasLength(5));
      expect(tags.map((BookTagRow t) => t.name).toSet(),
          kBuiltInStarTagNames.toSet());
    });

    test('only-add: preserves user tags + edited star color, never deletes',
        () async {
      final FushiDatabase db = await _openDb();

      // A user-created tag and one pre-existing star with a custom color.
      final int userId = await db.createTag('MyShelf', 0xFF123456);
      await db.createTag(kBuiltInStarTagNames[2], 0xFF00FF00); // 3-star, custom

      final int added = await seedStarRatingTags(db);
      expect(added, 4); // the 4 missing stars; 3-star already present

      final List<BookTagRow> tags = await db.getAllTags();
      final Map<String, BookTagRow> byName = <String, BookTagRow>{
        for (final BookTagRow t in tags) t.name: t
      };

      // User tag untouched.
      expect(byName.containsKey('MyShelf'), isTrue);
      expect(byName['MyShelf']!.id, userId);
      expect(byName['MyShelf']!.colorValue, 0xFF123456);

      // Pre-existing 3-star keeps its user-edited color (not overwritten).
      expect(byName[kBuiltInStarTagNames[2]]!.colorValue, 0xFF00FF00);

      // All 5 stars present, and no star row was deleted.
      for (final String name in kBuiltInStarTagNames) {
        expect(byName.containsKey(name), isTrue, reason: 'missing $name');
      }
      expect(tags, hasLength(6)); // 5 stars + 1 user tag
    });
  });
}
