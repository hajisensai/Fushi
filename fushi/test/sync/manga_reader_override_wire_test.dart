import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

void main() {
  test('manga reader sidecar parser tolerates malformed fields', () {
    final parsed = parseMangaReaderSidecar(<String, Object?>{
      'overrides': <String, Object?>{'mode': 'pagedVertical'},
      'updatedAt': '42',
      'deleted': false,
    });
    expect(parsed.overrides['mode'], 'pagedVertical');
    expect(parsed.updatedAt, 42);
    expect(parsed.deleted, isFalse);
    expect(parseMangaReaderSidecar(null).updatedAt, -1);
  });

  test('RemoteBookInfo wire round-trips sparse override and tombstone', () {
    const RemoteBookInfo source = RemoteBookInfo(
      title: 'Manga',
      hasContent: false,
      format: 'manga',
      mangaReaderOverrides: <String, Object?>{'mode': 'longStripGaps'},
      mangaReaderOverrideUpdatedAt: 99,
      mangaReaderOverrideDeleted: true,
    );
    final RemoteBookInfo copy = RemoteBookInfo.fromJson(source.toJson());
    expect(copy.mangaReaderOverrides['mode'], 'longStripGaps');
    expect(copy.mangaReaderOverrideUpdatedAt, 99);
    expect(copy.mangaReaderOverrideDeleted, isTrue);
  });
}
