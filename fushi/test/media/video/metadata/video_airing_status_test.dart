import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

void main() {
  test('TMDB TV / movie status raw strings normalize', () {
    expect(normalizeVideoAiringStatus('Returning Series'),
        VideoAiringStatus.airing);
    expect(normalizeVideoAiringStatus('Ended'), VideoAiringStatus.finished);
    expect(normalizeVideoAiringStatus('Canceled'), VideoAiringStatus.cancelled);
    expect(normalizeVideoAiringStatus('In Production'),
        VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('Planned'), VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('Pilot'), VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('Released'), VideoAiringStatus.finished);
    expect(normalizeVideoAiringStatus('Post Production'),
        VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('Rumored'), VideoAiringStatus.upcoming);
  });

  test('Jikan (MAL) status raw strings normalize', () {
    expect(normalizeVideoAiringStatus('Currently Airing'),
        VideoAiringStatus.airing);
    expect(normalizeVideoAiringStatus('Finished Airing'),
        VideoAiringStatus.finished);
    expect(normalizeVideoAiringStatus('Not yet aired'),
        VideoAiringStatus.upcoming);
  });

  test('AniList status raw strings normalize', () {
    expect(normalizeVideoAiringStatus('RELEASING'), VideoAiringStatus.airing);
    expect(normalizeVideoAiringStatus('FINISHED'), VideoAiringStatus.finished);
    expect(normalizeVideoAiringStatus('NOT_YET_RELEASED'),
        VideoAiringStatus.upcoming);
    expect(
        normalizeVideoAiringStatus('CANCELLED'), VideoAiringStatus.cancelled);
    expect(normalizeVideoAiringStatus('HIATUS'), VideoAiringStatus.hiatus);
  });

  test('case, surrounding whitespace, underscores and hyphens are tolerated',
      () {
    expect(normalizeVideoAiringStatus('  returning   series \n'),
        VideoAiringStatus.airing);
    expect(normalizeVideoAiringStatus('not-yet-aired'),
        VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('Not_Yet__Released'),
        VideoAiringStatus.upcoming);
    expect(normalizeVideoAiringStatus('POST-PRODUCTION'),
        VideoAiringStatus.upcoming);
    expect(
        normalizeVideoAiringStatus('cancelled'), VideoAiringStatus.cancelled);
  });

  test('unknown or empty strings and null are not guessed', () {
    expect(normalizeVideoAiringStatus(null), isNull);
    expect(normalizeVideoAiringStatus(''), isNull);
    expect(normalizeVideoAiringStatus('   '), isNull);
    expect(normalizeVideoAiringStatus('Airing'), isNull);
    expect(normalizeVideoAiringStatus('Ongoing'), isNull);
    expect(normalizeVideoAiringStatus('Finished Airing Soon'), isNull);
  });

  test('VideoMetadataWork.airingStatus reads the raw status column', () {
    VideoMetadataWork work(String? status) => VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Test',
        status: status);
    expect(work('Currently Airing').airingStatus, VideoAiringStatus.airing);
    expect(work('Currently Airing').status, 'Currently Airing',
        reason: '原串不改写：wire / NFO / DB 列都按原串消费');
    expect(work('RELEASING').airingStatus, VideoAiringStatus.airing);
    expect(work('Ended').airingStatus, VideoAiringStatus.finished);
    expect(work('???').airingStatus, isNull);
    expect(work(null).airingStatus, isNull);
  });
}
