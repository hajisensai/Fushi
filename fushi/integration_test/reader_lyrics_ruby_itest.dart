// 歌词模式振假名：正文带 <ruby> 的 EPUB + 命中区间 cue → 歌词页画出 <ruby><rt>。
// 证据：live WebView 里 `.cue ruby` 计数 + WebView 真像素截图。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/media_fixtures.dart' show generateSilentAudio;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _chapterHref = 'text/ch01.xhtml';

/// 三句正文；第二句带 ruby（与用户截图同句）。
const List<String> _plain = <String>[
  '磁力砲異常なし、熱線砲準備よし、スクリーン入光量調整ずみ——',
  '艦長はひときわひびく声で、共通信号の発信を命じた。',
  '停船せよ。',
];
const String _chapterBody =
    '<p>磁力砲異常なし、熱線砲準備よし、スクリーン入光量調整ずみ——</p>'
    '<p><ruby>艦長<rt>かんちょう</rt></ruby>はひときわひびく声で、'
    '<ruby>共通信号<rt>きょうつうしんごう</rt></ruby>の発信を命じた。</p>'
    '<p><ruby>停船<rt>ていせん</rt></ruby>せよ。</p>';

Uint8List _buildRubyEpub() {
  const String opf =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">urn:uuid:lyrics-ruby-itest</dc:identifier>'
      '<dc:title>Lyrics Ruby Itest</dc:title><dc:language>ja</dc:language>'
      '</metadata>'
      '<manifest><item id="ch01" href="$_chapterHref" media-type="application/xhtml+xml"/>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>'
      '<spine><itemref idref="ch01"/></spine></package>';
  const String nav =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>nav</title></head><body><nav epub:type="toc"><ol>'
      '<li><a href="$_chapterHref">第一章</a></li></ol></nav></body></html>';
  const String chapter =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>'
      '<body>$_chapterBody</body></html>';
  const String container =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
      '</rootfiles></container>';
  final Archive archive = Archive();
  void add(String name, String text, {bool store = false}) {
    final List<int> bytes = utf8.encode(text);
    final ArchiveFile f = ArchiveFile(name, bytes.length, bytes);
    if (store) f.compress = false;
    archive.addFile(f);
  }

  add('mimetype', 'application/epub+zip', store: true);
  add('META-INF/container.xml', container);
  add('OEBPS/content.opf', opf);
  add('OEBPS/nav.xhtml', nav);
  add('OEBPS/$_chapterHref', chapter);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

List<AudioCue> _cues(String bookKey) {
  final List<AudioCue> out = <AudioCue>[];
  int cursor = 0;
  for (int i = 0; i < _plain.length; i++) {
    final int len = AudioTextNormalizer.normalize(_plain[i]).length;
    out.add(
      AudioCue()
        ..bookKey = bookKey
        ..chapterHref = _chapterHref
        ..sentenceIndex = i
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: 0,
          normCharStart: cursor,
          normCharEnd: cursor + len,
        )
        ..text = _plain[i]
        ..startMs = i * 3000
        ..endMs = i * 3000 + 2500
        ..audioFileIndex = 0,
    );
    cursor += len;
  }
  return out;
}

bool _keyShown(String key) =>
    find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (condition()) return;
  }
  fail(reason);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lyrics mode renders book ruby as furigana', (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'lyrics-ruby',
      body: () async {
        await launchFushiTestApp();
        expect(
          await waitForHome(tester),
          isTrue,
          reason: 'home must render before seeding',
        );
        final AppModel appModel = await readyAppModel(tester);
        await appModel.setExperimentalFocusNavigationEnabled(true);
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        final bool originalLyricsMode = ReaderFushiSource.instance.lyricsMode;
        addTearDown(() async {
          await ReaderFushiSource.instance.setLyricsMode(originalLyricsMode);
        });
        await ReaderFushiSource.instance.setLyricsMode(false);
        ReaderFushiSource.instance.setPreference<bool>(
          key: 'lyrics_mode_hint_shown',
          value: true,
        );

        await showBooksTab(tester);
        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: _buildRubyEpub(),
          fileName: 'Lyrics Ruby Itest.epub',
        );
        final Directory tmp = await getTemporaryDirectory();
        final File audio = await generateSilentAudio(
          outPath: '${tmp.path}${Platform.pathSeparator}$bookKey.m4a',
          duration: const Duration(seconds: 9),
        );
        final AudiobookRepository repo = AudiobookRepository(appModel.database);
        await repo.replaceAlignment(
          bookKey: bookKey,
          format: 'srt',
          path: audio.path,
        );
        await repo.replaceAudio(
          bookKey: bookKey,
          audioPaths: <String>[audio.path],
        );
        await repo.saveCues(bookKey: bookKey, cues: _cues(bookKey));
        debugPrint('[lyrics-ruby] seeded book=$bookKey');

        await openBookViaProductionPath(tester, bookKey);
        await _pumpUntil(
          tester,
          () => _keyShown('fushi_webview'),
          reason: 'reader WebView must mount',
        );
        await _pumpUntil(
          tester,
          () => _keyShown('fushi_content_ready'),
          reason: 'reader content must become ready',
        );
        for (int i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          final AudiobookPlayerController? c =
              appModel.audiobookSession.controller;
          if (c != null && c.chapterCueCount > 0) break;
        }
        expect(
          appModel.audiobookSession.controller?.chapterCueCount ?? 0,
          greaterThan(0),
          reason: 'audiobook controller must attach with cues',
        );

        await ReaderFushiPage.debugOpenQuickSettings!();
        await tester.pump(const Duration(seconds: 1));
        final Finder lyricsToggle = find.byKey(
          const ValueKey<String>('fushi_lyrics_mode_toggle'),
        );
        expect(lyricsToggle, findsOneWidget);
        final FocusDriver driver = FocusDriver(tester);
        expect(await driver.requestFocusInside(lyricsToggle), isTrue);
        expect(await driver.activateIntent(), isTrue);
        await _pumpUntil(
          tester,
          () => ReaderFushiSource.instance.lyricsMode,
          reason: 'lyrics mode must turn on',
          polls: 10,
        );
        await _pumpUntil(
          tester,
          () => _keyShown('fushi_lyrics_ready'),
          reason: 'lyrics page must report ready',
        );
        await tester.pump(const Duration(seconds: 2));

        final dynamic
        probe = await ReaderFushiPage.debugEvaluateJavascript?.call(
          "JSON.stringify({cues: document.querySelectorAll('.cue').length,"
          " rubies: document.querySelectorAll('.cue ruby').length,"
          " rts: Array.from(document.querySelectorAll('.cue rt')).map(e => e.textContent),"
          " texts: Array.from(document.querySelectorAll('.cue')).map(e => e.textContent)})",
        );
        debugPrint('[lyrics-ruby] probe=$probe');
        final Map<String, dynamic> parsed =
            jsonDecode(probe is String ? probe : jsonEncode(probe))
                as Map<String, dynamic>;
        expect(parsed['cues'], 3);
        expect(parsed['rubies'], 3, reason: '三处 ruby 都该画出来');
        expect(parsed['rts'], <String>['かんちょう', 'きょうつうしんごう', 'ていせん']);

        final ObserveShot shot = await captureReaderWebView('lyrics-ruby');
        debugPrint(
          '[lyrics-ruby] webview shot saved=${shot.saved} nonBlank=${shot.nonBlank} path=${shot.path}',
        );
        expect(shot.saved, isTrue, reason: 'WebView 真像素截图必须落盘');
      },
    );
  });
}
