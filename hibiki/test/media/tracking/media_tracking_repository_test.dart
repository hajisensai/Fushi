import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  late MediaTrackingRepository repository;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
  });

  tearDown(() => db.close());

  test('EPUB TOC progress counts logical chapters instead of spine files', () {
    final int progress = estimateCompletedBookChapters(
      chaptersJson: '''
[
  {"href":"text/nav.xhtml"},
  {"href":"text/chapter-1.xhtml"},
  {"href":"text/illustration.xhtml"},
  {"href":"text/chapter-2.xhtml"}
]
''',
      tocJson: '''
[
  {"title":"目次","href":"text/nav.xhtml"},
  {"title":"第一話","href":"text/chapter-1.xhtml"},
  {"title":"第二話","href":"text/chapter-2.xhtml"}
]
''',
      sectionIndex: 2,
      sectionCompleted: false,
      bookCompleted: false,
      fallbackProgress: 17,
    );

    expect(progress, 1);
  });

  test('completed EPUB reports all logical TOC chapters', () {
    final int progress = estimateCompletedBookChapters(
      chaptersJson: '[{"href":"text/a.xhtml"},{"href":"text/b.xhtml"}]',
      tocJson:
          '[{"title":"序章","href":"text/a.xhtml"},{"title":"終章","href":"text/b.xhtml"}]',
      sectionIndex: 1,
      sectionCompleted: true,
      bookCompleted: true,
      fallbackProgress: 2,
    );

    expect(progress, 2);
  });

  test('mapping upsert keeps the stable local identity unique', () async {
    final int first = await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book-a',
      mediaTitle: 'A',
      kind: TrackingKind.novel,
      subjectId: 1,
      subjectName: 'Remote A',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 1,
    );
    final int second = await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book-a',
      mediaTitle: 'A revised',
      kind: TrackingKind.manga,
      subjectId: 2,
      subjectName: 'Remote B',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );

    expect(second, first);
    expect(await repository.listMappings(), hasLength(1));
    final MediaTrackingMappingRow row =
        (await repository.listMappings()).single;
    expect(row.subjectId, 2);
    expect(row.kind, 'manga');
  });

  test('automatic mapping never overwrites an existing manual choice',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'manual-book',
      mediaTitle: 'Manual',
      kind: TrackingKind.novel,
      subjectId: 10,
      subjectName: 'Chosen manually',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );

    final MediaTrackingMappingRow row = await repository.saveMappingIfAbsent(
      mediaType: TrackingMediaType.book,
      mediaKey: 'manual-book',
      mediaTitle: 'Automatic',
      kind: TrackingKind.manga,
      subjectId: 99,
      subjectName: 'Guessed automatically',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 3,
    );

    expect(row.subjectId, 10);
    expect(row.subjectName, 'Chosen manually');
    expect(row.progressMode, TrackingProgressMode.chapter.value);
  });

  test('outbox merges with max progress and completed OR', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      mediaTitle: 'Anime',
      kind: TrackingKind.anime,
      subjectId: 99,
      subjectName: 'Anime remote',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );

    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      localProgress: 4,
      completed: false,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '9',
      localProgress: 2,
      completed: true,
    );

    final PendingTrackingUpdate update = (await repository.dueUpdates()).single;
    expect(update.outbox.progress, 5);
    expect(update.outbox.completed, isTrue);
    expect(await repository.pendingCount(), 1);
  });

  test('successful delete is optimistic and does not remove a newer event',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      mediaTitle: 'Book',
      kind: TrackingKind.novel,
      subjectId: 10,
      subjectName: 'Remote',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 2,
      completed: false,
    );
    final MediaTrackingOutboxRow stale =
        (await repository.dueUpdates()).single.outbox;
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 3,
      completed: false,
    );

    await repository.markSucceeded(stale);

    expect(await repository.pendingCount(), 1);
    expect((await repository.dueUpdates()).single.outbox.progress, 3);
  });
}
