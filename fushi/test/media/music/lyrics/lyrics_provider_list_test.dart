import 'package:test/test.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';

void main() {
  const LyricsProviderEntry a = LyricsProviderEntry(id: 'a', enabled: true);
  const LyricsProviderEntry b = LyricsProviderEntry(id: 'b', enabled: false);
  const LyricsProviderEntry c = LyricsProviderEntry(id: 'c', enabled: true);

  test('round trips through JSON', () {
    final String raw = serializeLyricsProviders(<LyricsProviderEntry>[a, b]);
    expect(parseLyricsProviders(raw), <LyricsProviderEntry>[a, b]);
  });

  test('tolerates bad JSON, wrong shapes, bad and duplicate items', () {
    expect(parseLyricsProviders(null), isEmpty);
    expect(parseLyricsProviders(''), isEmpty);
    expect(parseLyricsProviders('{oops'), isEmpty);
    expect(parseLyricsProviders('{"id":"a"}'), isEmpty);
    expect(
      parseLyricsProviders(
        '[1,{"id":""},{"enabled":true},{"id":"a"},{"id":"a","enabled":false}]',
      ),
      <LyricsProviderEntry>[a],
    );
  });

  test('merge drops uninstalled and appends new installs enabled at end', () {
    expect(
      mergeLyricsProviders(
        <LyricsProviderEntry>[b, a],
        <String>['a', 'c', 'b'],
      ),
      <LyricsProviderEntry>[b, a, c],
    );
    expect(
      mergeLyricsProviders(<LyricsProviderEntry>[a, b], <String>['b']),
      <LyricsProviderEntry>[b],
    );
    expect(
      mergeLyricsProviders(const <LyricsProviderEntry>[], <String>['c']),
      <LyricsProviderEntry>[c],
    );
  });

  group('mergeLyricsSourceList（LRCLIB 与插件同一份有序列表）', () {
    const LyricsProviderEntry lrclib = LyricsProviderEntry(
      id: MusicLyricsSource.lrclib,
      enabled: true,
    );

    test('旧偏好没有 LRCLIB：补在最前并启用，存量查询顺序不变', () {
      expect(
        mergeLyricsSourceList(<LyricsProviderEntry>[b, a], <String>['a', 'b']),
        <LyricsProviderEntry>[lrclib, b, a],
      );
      expect(
        mergeLyricsSourceList(const <LyricsProviderEntry>[], const <String>[]),
        <LyricsProviderEntry>[lrclib],
      );
    });

    test('用户排过的 LRCLIB 位置与停用照存，插件照常并集', () {
      const LyricsProviderEntry off = LyricsProviderEntry(
        id: MusicLyricsSource.lrclib,
        enabled: false,
      );
      expect(
        mergeLyricsSourceList(
          <LyricsProviderEntry>[a, off, b],
          <String>['a', 'c'],
        ),
        <LyricsProviderEntry>[a, off, c],
      );
      expect(
        enabledLyricsProviderIds(
          mergeLyricsSourceList(
            <LyricsProviderEntry>[c, lrclib],
            <String>['c'],
          ),
        ),
        <String>['c', MusicLyricsSource.lrclib],
      );
    });
  });

  test('reorder and toggle', () {
    expect(
      reorderLyricsProviders(<LyricsProviderEntry>[a, b, c], 2, 0),
      <LyricsProviderEntry>[c, a, b],
    );
    expect(
      reorderLyricsProviders(<LyricsProviderEntry>[a, b], 0, 5),
      <LyricsProviderEntry>[a, b],
    );
    expect(
      toggleLyricsProvider(<LyricsProviderEntry>[a, b], 'b', true)[1].enabled,
      isTrue,
    );
    expect(enabledLyricsProviderIds(<LyricsProviderEntry>[a, b, c]), <String>[
      'a',
      'c',
    ]);
  });
}
