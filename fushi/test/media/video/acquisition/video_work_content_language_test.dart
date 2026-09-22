// AI 下视频：「跟随作品语言」解析的四档证据。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_work_content_language.dart';

VideoMediaReference _reference({
  required String title,
  String? originalTitle,
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '1',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: title,
  originalTitle: originalTitle,
);

VideoMetadataWork _work({
  String? originalLanguage,
  List<String> countries = const <String>[],
}) => VideoMetadataWork(
  provider: VideoMetadataProviderKind.tmdb,
  kind: VideoMetadataMediaKind.tv,
  title: 'Show',
  originalLanguage: originalLanguage,
  countries: countries,
);

void main() {
  test('originalLanguage 优先，且经归一（jpn → ja）', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(originalLanguage: 'jpn', countries: <String>['KR']),
      _reference(title: 'Show', originalTitle: '쇼'),
    );
    expect(result.code, 'ja');
    expect(result.evidence, VideoWorkLanguageEvidence.originalLanguage);
  });

  test('originalLanguage 为空串时落到制作国', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(originalLanguage: '  ', countries: <String>['jp']),
      _reference(title: 'Show'),
    );
    expect(result.code, 'ja');
    expect(result.evidence, VideoWorkLanguageEvidence.countries);
  });

  test('制作国唯一可判 → countries；同语言多国不算冲突', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(countries: <String>['CN', 'HK', 'TW']),
      _reference(title: 'Show'),
    );
    expect(result.code, 'zh');
    expect(result.evidence, VideoWorkLanguageEvidence.countries);
  });

  test('未知国家被忽略，剩下唯一可判国家仍判', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(countries: <String>['FR', 'US']),
      _reference(title: 'Show'),
    );
    expect(result.code, 'en');
    expect(result.evidence, VideoWorkLanguageEvidence.countries);
  });

  test('多国冲突不判，落到标题文字', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(countries: <String>['JP', 'US']),
      _reference(title: 'Show', originalTitle: 'ショー'),
    );
    expect(result.code, 'ja');
    expect(result.evidence, VideoWorkLanguageEvidence.titleScript);
  });

  test('标题含假名 → ja（originalTitle 优先于 title）', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      null,
      _reference(title: 'Frieren', originalTitle: '葬送のフリーレン'),
    );
    expect(result.code, 'ja');
    expect(result.evidence, VideoWorkLanguageEvidence.titleScript);
  });

  test('标题含谚文 → ko', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(),
      _reference(title: '오징어 게임'),
    );
    expect(result.code, 'ko');
    expect(result.evidence, VideoWorkLanguageEvidence.titleScript);
  });

  test('仅汉字标题不判 → unknown', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      _work(),
      _reference(title: 'Show', originalTitle: '進撃巨人'),
    );
    expect(result.code, isNull);
    expect(result.evidence, VideoWorkLanguageEvidence.none);
    expect(identical(result, VideoWorkContentLanguage.unknown), isTrue);
  });

  test('片假名中点「・」单独不算日语证据', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      null,
      _reference(title: '哈利・波特'),
    );
    expect(result.code, isNull);
    expect(result.evidence, VideoWorkLanguageEvidence.none);
  });

  test('全无证据 → unknown', () {
    final VideoWorkContentLanguage result = resolveVideoWorkContentLanguage(
      null,
      _reference(title: 'Show'),
    );
    expect(result.evidence, VideoWorkLanguageEvidence.none);
    expect(result.code, isNull);
  });
}
