import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_panel_navigation.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';

void main() {
  test('panel cursor advances and resets at boundaries', () {
    final MangaPanelNavigationCursor cursor = MangaPanelNavigationCursor();
    const List<PanelRect> panels = <PanelRect>[
      PanelRect(left: 0, top: 0, right: 0.5, bottom: 0.5),
      PanelRect(left: 0.5, top: 0.5, right: 1, bottom: 1),
    ];
    expect(cursor.move(panels, forward: true), panels[0]);
    expect(cursor.move(panels, forward: true), panels[1]);
    expect(cursor.move(panels, forward: true), isNull);
    cursor.reset();
    expect(cursor.index, -1);
    expect(cursor.move(panels, forward: false), panels[1]);
  });

  test('focus script carries normalized rectangle and page index', () {
    final String script = mangaFocusPanelJavascript(
      3,
      const PanelRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9),
    );
    expect(script, contains('__mangaFocusPanel'));
    expect(script, contains('0.1'));
    expect(script, contains('0.9'));
    expect(script, contains('__mangaFocusPanel(3'));
  });

  test('sidecar URL encodes path segments independently', () {
    expect(
      mokuroSidecarUri('series name/part 1', 'Vol 01|special').toString(),
      'https://mokuro.moe/mokuro-reader/series%20name/part%201/Vol%2001%7Cspecial.mokuro',
    );
  });

  test('sidecar identity parses the Mihon chapter URL', () {
    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'test.mokuro',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: 'series',
        title: 'Series',
        raw: <String, Object?>{},
      ),
      chapters: <OnlineMangaChapter>[],
    );
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: 'https://mokuro.moe/mokuro-reader/series%20name/Vol%2001.cbz',
      name: 'ignored display title',
      raw: <String, Object?>{},
    );
    final MokuroSidecarIdentity? identity = mokuroSidecarIdentity(
      entry,
      chapter,
    );
    expect(identity?.seriesPath, 'series name');
    expect(identity?.volumeName, 'Vol 01');
  });
}
