import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/sync/aggregate_merge_service.dart';
import 'package:test/test.dart';

/// v179 收藏句的远端来源身份（[FavoriteSentence.originSourceId]，BUG-5379）跨设备
/// 不丢：wire JSON 往返保留、旧条目字节不变；同步 / 备份合并时一侧记着、一侧没记
/// （旧版本设备同步过来的同一条收藏）取记着的那一侧，两种参数顺序结果一致。
void main() {
  FavoriteSentence fav({String? origin, int createdUs = 1700000000000000}) =>
      FavoriteSentence(
        id: 'hl_$createdUs',
        text: 'そうか',
        bookTitle: 'Ep 3',
        createdAt: DateTime.fromMicrosecondsSinceEpoch(createdUs),
        bookKey: '1234',
        normCharOffset: 61000,
        source: kFavoriteSentenceSourceVideo,
        originSourceId: origin,
      );

  test('wire JSON 往返保留来源；没有来源的不写该字段', () {
    final FavoriteSentence withOrigin = fav(origin: 'plex:m1|a1');
    expect(withOrigin.toJson()['originSourceId'], 'plex:m1|a1');
    expect(
      FavoriteSentence.fromJson(withOrigin.toJson()).originSourceId,
      'plex:m1|a1',
    );
    expect(fav().toJson().containsKey('originSourceId'), isFalse);
    expect(FavoriteSentence.fromJson(fav().toJson()).originSourceId, isNull);
  });

  test('改色副本不丢来源', () {
    final FavoriteSentence recolored = fav(
      origin: 'jellyfin:http://a|u',
    ).withColor('pink', DateTime.fromMicrosecondsSinceEpoch(1800000000000000));
    expect(recolored.originSourceId, 'jellyfin:http://a|u');
  });

  test('合并：一侧记着来源，结果带来源（与参数顺序无关）', () {
    final FavoriteSentence oldDevice = fav();
    // 同一条收藏（同内容键），记着来源的一侧 createdAt 更晚：身份仍取早的那条。
    final FavoriteSentence newDevice = fav(
      origin: 'plex:m1|a1',
      createdUs: 1700000000000001,
    );
    for (final List<FavoriteSentence> sides in <List<FavoriteSentence>>[
      <FavoriteSentence>[oldDevice, newDevice],
      <FavoriteSentence>[newDevice, oldDevice],
    ]) {
      final FavoriteSentence merged =
          AggregateMergeService.mergeFavoriteSentences(
            <FavoriteSentence>[sides[0]],
            <FavoriteSentence>[sides[1]],
          ).single;
      expect(merged.id, oldDevice.id);
      expect(merged.originSourceId, 'plex:m1|a1');
    }
  });
}
