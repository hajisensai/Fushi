import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

void main() {
  test('duplicate rows collapse, conflicting MAL IDs are not auto-selected',
      () async {
    int calls = 0;
    final AnimeIdentityMapping mapping = AnimeIdentityMapping(
      httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
        calls++;
        return http.Response(
            '[{"anidb_id":1,"mal_id":2},{"anidb_id":1,"mal_id":"2"},'
            '{"anidb_id":3,"mal_id":4},{"anidb_id":3,"mal_id":5},'
            '{"anidb_id":1,"mal_id":0},{"anidb_id":1,"mal_id":2.5}]',
            200);
      })),
    );
    expect((await mapping.lookupAnidb(1)).confirmedMalId, 2);
    final AnimeIdentityMappingResult ambiguous = await mapping.lookupAnidb(3);
    expect(ambiguous.isAmbiguous, isTrue);
    expect(ambiguous.confirmedMalId, isNull);
    expect((await mapping.lookupAnidb(6)).confirmedMalId, isNull);
    expect(calls, 1);
  });

  test('expires catalog and rejects oversized or malformed catalog', () async {
    DateTime now = DateTime(2026);
    int calls = 0;
    final AnimeIdentityMapping mapping = AnimeIdentityMapping(
      now: () => now,
      maxResponseBytes: 64,
      httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
        calls++;
        return http.Response(calls == 1 ? '[]' : 'x' * 65, 200);
      })),
    );
    await mapping.lookupAnidb(1);
    now = now.add(const Duration(days: 2));
    await expectLater(mapping.lookupAnidb(1), throwsFormatException);
    expect(calls, 2);
  });
}
