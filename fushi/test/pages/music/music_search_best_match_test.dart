import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart';
import 'package:fushi_core/fushi_core.dart' show MusicArtistRow;
import 'package:fushi_music/fushi_music.dart';

/// 综合搜索「最佳匹配」规则（docs/specs/2026-10-28-music-plugins.md §4 `searchBest`）：
/// 插件给的最佳匹配优先；没给时只看第一个有在线艺人结果的插件的**第一个**艺人（名字或别名
/// 匹配才用），不在全部结果里按名字全等挑——用户报 `zutomayo` 选中了排在后面的同名小号。
void main() {
  const MusicPluginManifest demo = MusicPluginManifest(
    id: 'moe.example.music',
    name: '示例音乐',
    version: '0.4.0',
    api: 1,
    capabilities: <String>['search', 'searchBest'],
    searchTypes: <String>['artist'],
    permissions: <String>[],
    networkDomains: <String>[],
  );
  const MusicPluginManifest other = MusicPluginManifest(
    id: 'moe.example.other',
    name: 'Other',
    version: '1.0.0',
    api: 1,
    capabilities: <String>['search'],
    searchTypes: <String>['artist'],
    permissions: <String>[],
    networkDomains: <String>[],
  );
  const MusicPluginArtist ztmy = MusicPluginArtist(
    id: '15021101',
    name: 'ずっと真夜中でいいのに。',
    aliases: <String>['ZUTOMAYO', 'ZTMY', 'ずとまよ', '永远是深夜有多好｡'],
    stats: MusicPluginArtistStats(trackCount: 332, fanCount: 793789),
  );
  const MusicPluginArtist smurf = MusicPluginArtist(
    id: '30397178',
    name: 'ZUTOMAYO',
  );
  const MusicPluginPlaylist hot = MusicPluginPlaylist(
    id: '8668352551',
    title: '听ずっと真夜中でいいのに。热门精选',
  );
  final MusicArtistRow localSame = MusicArtistRow(
    artistUid: 'local-1',
    name: 'zutomayo',
    addedAt: 0,
  );

  List<Object> items(List<MusicSearchBestItem> r) =>
      r.map((MusicSearchBestItem b) => b.item).toList();

  test('插件给了最佳匹配：艺人 + 歌单两张卡，插件顺序靠前的说了算', () {
    final List<MusicSearchBestItem> r = pickMusicSearchBest(
      query: 'zutomayo',
      pluginBest: <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[
        (plugin: demo, best: MusicPluginSearchBest.none),
        (
          plugin: demo,
          best: const MusicPluginSearchBest(artist: ztmy, playlist: hot),
        ),
      ],
      onlineArtists: <({MusicPluginManifest plugin, List<Object> artists})>[
        (plugin: demo, artists: <Object>[smurf, ztmy]),
      ],
      localArtists: <MusicArtistRow>[localSame],
      albums: const <MusicSearchBestItem>[],
      tracks: const <MusicSearchBestItem>[],
    );
    expect(items(r), <Object>[ztmy, hot]);
    expect(r.first.plugin, demo);
  });

  test('只有歌单的最佳匹配：单卡', () {
    final List<MusicSearchBestItem> r = pickMusicSearchBest(
      query: 'x',
      pluginBest: <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[
        (plugin: demo, best: const MusicPluginSearchBest(playlist: hot)),
      ],
      onlineArtists:
          const <({MusicPluginManifest plugin, List<Object> artists})>[],
      localArtists: const <MusicArtistRow>[],
      albums: const <MusicSearchBestItem>[],
      tracks: const <MusicSearchBestItem>[],
    );
    expect(items(r), <Object>[hot]);
  });

  test('回退：第一个艺人按别名匹配就用它', () {
    final List<MusicSearchBestItem> r = pickMusicSearchBest(
      query: 'ZUTOMAYO',
      pluginBest:
          const <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[],
      onlineArtists: <({MusicPluginManifest plugin, List<Object> artists})>[
        (plugin: demo, artists: <Object>[ztmy, smurf]),
      ],
      localArtists: <MusicArtistRow>[localSame],
      albums: const <MusicSearchBestItem>[],
      tracks: const <MusicSearchBestItem>[],
    );
    expect(items(r), <Object>[ztmy]);
  });

  test('回退：同名小号排在后面不会被选中，第一个艺人不匹配时看本地同名', () {
    final List<MusicSearchBestItem> r = pickMusicSearchBest(
      query: 'zutomayo',
      pluginBest:
          const <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[],
      onlineArtists: <({MusicPluginManifest plugin, List<Object> artists})>[
        (
          plugin: demo,
          artists: <Object>[
            const MusicPluginArtist(id: '1', name: 'ZUTOMAYOa'),
            smurf,
          ],
        ),
        // 第二个插件的第一个艺人同名也不看：只认第一个有结果的插件。
        (plugin: other, artists: <Object>[smurf]),
      ],
      localArtists: <MusicArtistRow>[localSame],
      albums: const <MusicSearchBestItem>[],
      tracks: const <MusicSearchBestItem>[],
    );
    expect(items(r), <Object>[localSame]);
  });

  test('回退：都不匹配时取第一首歌，不拿排后面的同名艺人', () {
    const MusicPluginTrack song = MusicPluginTrack(id: 't', title: '秒針を噛む');
    final List<MusicSearchBestItem> r = pickMusicSearchBest(
      query: 'zutomayo',
      pluginBest:
          const <({MusicPluginManifest plugin, MusicPluginSearchBest best})>[],
      onlineArtists: <({MusicPluginManifest plugin, List<Object> artists})>[
        (
          plugin: demo,
          artists: <Object>[
            const MusicPluginArtist(id: '1', name: 'ZUTOMAYOa'),
            smurf,
          ],
        ),
      ],
      localArtists: const <MusicArtistRow>[],
      albums: const <MusicSearchBestItem>[],
      tracks: <MusicSearchBestItem>[(plugin: demo, item: song)],
    );
    expect(items(r), <Object>[song]);
  });

  test('别名匹配按归一化（大小写 / 全半角）', () {
    expect(musicPluginArtistMatchesQuery(ztmy, 'ztmy'), isTrue);
    expect(musicPluginArtistMatchesQuery(ztmy, 'ＺＴＭＹ'), isTrue);
    expect(musicPluginArtistMatchesQuery(ztmy, 'zutomayo band'), isFalse);
    expect(musicPluginArtistMatchesQuery(ztmy, ''), isFalse);
  });
}
