// T1 finding F4: "Don't track the series" never appeared for a manga series
// made by the series rule (a `playlist` with origin `rule`, members keyed by
// the book's uid while tracking keys books by bookKey).
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

void main() {
  late FushiDatabase db;
  late MediaTrackingRepository repository;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
  });

  tearDown(() => db.close());

  Future<void> addBook(String bookKey, String uid) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/books/$bookKey.cbz',
      extractDir: '/books/$bookKey',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
      uid: Value<String>(uid),
    ),
  );

  /// The rule-made series card of the shelf, holding [uids].
  Future<int> ruleSeries(List<String> uids) async {
    final int id = await db.createMediaCollection(
      'Ajin',
      collectionType: 'playlist',
      origin: CollectionOrigin.rule,
    );
    for (final String uid in uids) {
      await db.addToCollection(id, MediaKind.epub, uid, userIntent: false);
    }
    return id;
  }

  test(
    'a rule-made series is the series of its volumes, by book key',
    () async {
      await addBook('Ajin (HD Scan) Ajin 02', 'book_1794');
      final int series = await ruleSeries(<String>['book_1794']);

      final TrackingSeriesRef? ref = (await repository.loadSeriesIndex())
          .seriesOf(TrackingMediaType.book.value, 'Ajin (HD Scan) Ajin 02');
      expect(ref?.type, TrackingMediaType.bookCollection);
      expect(ref?.key, '$series');

      final List<MediaCollectionRow> sheet = await repository
          .bookSeriesCollections('Ajin (HD Scan) Ajin 02');
      expect(sheet.map((MediaCollectionRow c) => c.id), <int>[series]);
    },
  );

  test('an ignored series covers its volumes, also one added later', () async {
    await addBook('Ajin 01', 'book_1');
    final int series = await ruleSeries(<String>['book_1']);
    await repository.addIgnored(
      mediaType: TrackingMediaType.bookCollection,
      mediaKey: '$series',
      mediaTitle: 'Ajin',
    );
    expect(
      (await repository.loadIgnoreIndex()).covers(
        TrackingMediaType.book.value,
        'Ajin 01',
      ),
      isTrue,
    );

    await addBook('Ajin 03', 'book_3');
    await db.addToCollection(
      series,
      MediaKind.epub,
      'book_3',
      userIntent: false,
    );
    final TrackingIgnoreIndex index = await repository.loadIgnoreIndex();
    expect(index.covers(TrackingMediaType.book.value, 'Ajin 03'), isTrue);
    expect(
      index.covers(TrackingMediaType.bookChapter.value, 'Ajin 03'),
      isTrue,
    );
  });

  test('the series card wins over a reading list holding the volume; a '
      'volume only in a reading list has that list as its card', () async {
    await addBook('Ajin 01', 'book_1');
    await addBook('Other 01', 'book_9');
    final int list = await db.createMediaCollection(
      'Reading list',
      collectionType: 'playlist',
    );
    await db.addToCollection(list, MediaKind.epub, 'book_1');
    await db.addToCollection(list, MediaKind.epub, 'book_9');
    final int series = await ruleSeries(<String>['book_1']);

    final TrackingSeriesIndex index = await repository.loadSeriesIndex();
    expect(
      index.seriesOf(TrackingMediaType.book.value, 'Ajin 01')?.key,
      '$series',
    );
    expect(
      index.seriesOf(TrackingMediaType.book.value, 'Other 01')?.key,
      '$list',
    );
    expect(
      (await repository.bookSeriesCollections('Ajin 01')).first.id,
      series,
    );
  });
}
