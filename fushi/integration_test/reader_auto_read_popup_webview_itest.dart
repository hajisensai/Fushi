import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi/src/lookup/lookup_audio_playback.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// BUG-5278 端到端：阅读器查词的**自动发音**必须交给本次查词那一层弹窗 WebView 的
/// `<audio>` 播，而不是回落宿主播放器（桌面 media_kit）。
///
/// 旧实现用「最上层**可见**弹窗」当播放目标，而自动发音触发时本层还挂在「等首帧渲染
/// 再翻出」上、不可见 → 拿到 null → 每次都回落 media_kit（每播重建 mpv，首次还要先
/// 排完静音预热）——用户感知为「第一次自动发音要等一会」。只有真 app + 真 WebView2
/// 才能回答「这一刻本层的 WebView 在不在、能不能播」，故在这一层测。
///
/// 夹具：生成词典（猫 / ねこ）+ 现建的极小本地音频库（Yomitan 本地音频服务器同构的
/// entries / android 两张表，blob 是一段全零 PCM WAV，不出声）。
///
/// 跑法（fushi/ 下，离屏不抢焦点）：
///   .\tool\run_windows_itest.ps1 integration_test/reader_auto_read_popup_webview_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-5278: reader auto-read plays through the lookup popup <audio>',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      final List<(LookupAudioRoute, String)> routes =
          <(LookupAudioRoute, String)>[];
      debugLookupAudioRouteObserver = (LookupAudioRoute r, String label) =>
          routes.add((r, label));
      addTearDown(() => debugLookupAudioRouteObserver = null);

      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(await seedDictionary(tester), isTrue);

      final File audioDb = await _writeLocalAudioFixture();
      await appModel.setAudioSourceConfigs(<AudioSourceConfig>[
        AudioSourceConfig.localAudio(
          label: 'fixture',
          path: audioDb.path,
          enabled: true,
        ),
      ]);
      expect(ReaderFushiSource.instance.autoReadOnLookup, isTrue);
      await appModel.database.setPref(
        'src:reader_fushi:view_mode',
        'pagination',
      );
      await appModel.database.setPref(
        'src:reader_fushi:writing_mode',
        'horizontal-tb',
      );
      await ReaderFushiSource.readerSettings?.refreshFromDb();

      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: EpubGenerator().generate(),
        fileName: 'bug5278_auto_read.epub',
      );
      final ReaderFushiSource source = ReaderFushiSource.instance;
      final MediaItem item = MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: bookKey,
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 0,
        canDelete: false,
        canEdit: true,
      );
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => source.buildLaunchPage(item: item),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      const Key contentReadyKey = ValueKey<String>('fushi_content_ready');
      for (int i = 0; i < 140; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(contentReadyKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      final Future<dynamic> Function(String source)? runInWebView =
          ReaderFushiPage.debugEvaluateJavascript;
      expect(runInWebView, isNotNull);
      final Map<String, dynamic> pts =
          jsonDecode(await runInWebView!(_wordPointJs()) as String)
              as Map<String, dynamic>;
      expect(pts['ok'], isTrue, reason: 'need a visible 猫 point: $pts');
      final double x = (pts['x'] as num).toDouble();
      final double y = (pts['y'] as num).toDouble();
      final dynamic readerState = tester.state(find.byType(ReaderFushiPage));
      bool dictShown() => readerState.isDictionaryShown as bool;

      // 冷查词（本次启动第一次）+ 复查：两轮都必须走弹窗 <audio>。
      for (int round = 0; round < 2; round++) {
        routes.clear();
        await runInWebView(_dispatchClickJs(x, y));
        for (int i = 0; i < 600 && (routes.isEmpty || !dictShown()); i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        debugPrint(
          '[bug5278] round $round routes=$routes shown=${dictShown()}',
        );
        expect(dictShown(), isTrue, reason: 'round $round must show a popup');
        expect(
          routes,
          <(LookupAudioRoute, String)>[(LookupAudioRoute.webView, '猫')],
          reason:
              'round $round: auto-read must play through the lookup popup '
              '<audio>, not fall back to the host player',
        );
        await tester.pump(const Duration(seconds: 1));
        readerState.clearDictionaryResult();
        for (int i = 0; i < 100 && dictShown(); i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        // 去重窗口（800ms）外再查同一个词。
        await tester.pump(const Duration(seconds: 2));
      }

      navigator.pop();
      await tester.pump(const Duration(seconds: 2));
    },
  );
}

/// Yomitan 本地音频服务器同构的极小库：一条「猫 / ねこ」，blob 是 0.3s 全零 WAV。
Future<File> _writeLocalAudioFixture() async {
  final Directory dir = await getTemporaryDirectory();
  final File file = File('${dir.path}/bug5278_local_audio.db');
  if (file.existsSync()) file.deleteSync();
  final Database db = sqlite3.open(file.path);
  try {
    db.execute(
      'CREATE TABLE entries (expression TEXT, reading TEXT, source TEXT, '
      'file TEXT, display TEXT)',
    );
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.execute('INSERT INTO entries VALUES (?, ?, ?, ?, ?)', <Object?>[
      '猫',
      'ねこ',
      'nhk16',
      'neko.wav',
      '猫',
    ]);
    db.execute('INSERT INTO android VALUES (?, ?, ?)', <Object?>[
      'neko.wav',
      'nhk16',
      _silentWav(),
    ]);
  } finally {
    db.dispose();
  }
  return file;
}

Uint8List _silentWav() {
  const int sampleRate = 22050;
  const int samples = sampleRate * 3 ~/ 10;
  const int dataSize = samples * 2;
  final ByteData bd = ByteData(44 + dataSize);
  void ascii(int o, String s) {
    for (int i = 0; i < s.length; i++) {
      bd.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataSize, Endian.little);
  return bd.buffer.asUint8List();
}

/// 找一个可见的 "猫"（生成 EPUB 正文重复出现）返回视口坐标。
String _wordPointJs() => r'''
(function() {
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node = walker.nextNode();
  while (node) {
    var text = node.nodeValue || '';
    var idx = text.indexOf('猫');
    while (idx !== -1) {
      var range = document.createRange();
      range.setStart(node, idx);
      range.setEnd(node, idx + 1);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (r.width > 2 && r.height > 2 && r.right > 0 && r.bottom > 0 &&
            r.left < window.innerWidth && r.top < window.innerHeight) {
          return JSON.stringify({ok: true,
            x: Math.max(1, Math.min(window.innerWidth - 1, (r.left + r.right) / 2)),
            y: Math.max(1, Math.min(window.innerHeight - 1, (r.top + r.bottom) / 2))});
        }
      }
      idx = text.indexOf('猫', idx + 1);
    }
    node = walker.nextNode();
  }
  return JSON.stringify({ok: false, error: 'no visible 猫'});
})()
''';

/// 派发一次真实单击（pointerdown/up + click），走生产 onTap 全链。
String _dispatchClickJs(double x, double y) =>
    '''
(function() {
  var px = $x, py = $y;
  var target = document.elementFromPoint(px, py) || document.body;
  function fire(type, buttons, button) {
    var init = {
      bubbles: true, cancelable: true, view: window,
      clientX: px, clientY: py, button: button, buttons: buttons
    };
    var ev;
    try { ev = new PointerEvent(type, Object.assign({pointerType:'mouse', pointerId: 7, isPrimary:true}, init)); }
    catch (e) { ev = new MouseEvent(type, init); }
    target.dispatchEvent(ev);
  }
  fire('pointerdown', 1, 0);
  fire('pointerup', 0, 0);
  var click = new MouseEvent('click', {
    bubbles: true, cancelable: true, view: window,
    clientX: px, clientY: py, button: 0, detail: 1
  });
  target.dispatchEvent(click);
  return 'dispatched';
})()
''';
