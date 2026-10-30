import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';

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
