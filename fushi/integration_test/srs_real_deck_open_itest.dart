// 真实牌组打开探针（Windows 离屏 runner，手动跑）：把一份真实库与 SRS 媒体播种进隔离根，
// 打开指定牌组的复习页，按时间线记下「页面出现 → 卡面 WebView 建好 → 外壳就绪 →
// 卡片内容进 DOM」，并抓卡面截图。用来复现「卡面空白 / 打开很慢」（BUG-3575）。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_real_deck_open_itest.dart `
//     -DartDefine @('FUSHI_PROBE_SRS_SEED=C:/path/seed', 'FUSHI_PROBE_SRS_DECK=<deckId>')
//
// 种子目录：fushi.db（连 -wal / -shm）+ srs_media/。只读拷贝，不碰真库。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _seed = String.fromEnvironment('FUSHI_PROBE_SRS_SEED');
const String _deck = String.fromEnvironment('FUSHI_PROBE_SRS_DECK');

const String _stateScript = '''
(function(){
  var r = document.getElementById('fushi-card-root');
  var t = r ? r.textContent.replace(/\\s+/g, ' ').trim() : '';
  return JSON.stringify({
    shell: typeof window.__fushiSrsSetCard,
    root: r ? r.innerHTML.length : -1,
    text: t.slice(0, 60),
    bg: getComputedStyle(document.body).backgroundColor,
    url: location.href.slice(0, 40),
    ready: document.readyState,
  });
})()
''';

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    final String rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      Directory(p.join(to.path, rel)).createSync(recursive: true);
    } else if (e is File) {
      e.copySync(p.join(to.path, rel));
    }
  }
}

/// 探针行同时写进隔离根里的文件：runner 卡住被杀时 stdout 会丢。
void _log(String line) {
  debugPrint(line);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_open_probe.txt'),
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实牌组：打开复习页到卡片内容上屏的时间线', (WidgetTester tester) async {
    final Directory support = fushiTestDirectory('app-support')!;
    for (final String name in <String>[
      'fushi.db',
      'fushi.db-wal',
      'fushi.db-shm',
    ]) {
      final File f = File(p.join(_seed, name));
      if (f.existsSync()) f.copySync(p.join(support.path, name));
    }
    _copyTree(
      Directory(p.join(_seed, 'srs_media')),
      Directory(p.join(support.path, 'srs_media')),
    );

    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await tester.pump(const Duration(seconds: 1));
    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    _log('[srs-open] canSchedule=${store.canSchedule}');

    expect(store.canSchedule, isTrue, reason: '排程内核不可用时复习页不出卡面');

    /// 打开一次复习页，按时间线记到卡片内容进 DOM，返回毫秒（没等到返回 -1）。
    Future<int> openOnce(String label) async {
      final Stopwatch clock = Stopwatch()..start();
      String at() => '${clock.elapsedMilliseconds} ms';
      SrsWebCardFace.debugController = null;
      SrsReviewPage.debugPhase = (String phase) =>
          _log('[srs-open] $label phase $phase @ ${at()}');
      SrsWebCardFace.debugMediaServed = (Uri url, int bytes, int ms) => _log(
        '[srs-open] $label media ${url.pathSegments.isEmpty ? url : url.pathSegments.last} '
        '$bytes B $ms ms @ ${at()}',
      );
      unawaited(
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                SrsReviewPage(deckId: _deck, deckName: 'probe'),
          ),
        ),
      );
      InAppWebViewController? controller;
      String last = '';
      int content = -1;
      while (clock.elapsed < const Duration(seconds: 90)) {
        await tester.pump(const Duration(milliseconds: 50));
        if (controller == null && SrsWebCardFace.debugController != null) {
          controller = SrsWebCardFace.debugController;
          _log('[srs-open] $label webview created @ ${at()}');
        }
        if (controller == null) continue;
        Object? state;
        try {
          state = await controller
              .evaluateJavascript(source: _stateScript)
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          state = 'eval error: $e';
        }
        final String s = '$state';
        if (s != last) {
          _log('[srs-open] $label state @ ${at()}: $s');
          last = s;
        }
        if (s.contains('"root":') &&
            !s.contains('"root":-1') &&
            !s.contains('"root":0,') &&
            !s.contains('"text":""')) {
          content = clock.elapsedMilliseconds;
          _log('[srs-open] $label CONTENT @ ${at()}');
          // 留 5 s 让卡面把字体 / 媒体请求发完（swap 字体在文字首帧之后才到）。
          final Stopwatch tail = Stopwatch()..start();
          while (tail.elapsed < const Duration(seconds: 5)) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          break;
        }
      }
      final Uint8List? png = await controller?.takeScreenshot();
      if (png != null) {
        final String path =
            '${observeScreenshotDir().path}/srs-real-deck-open-$label.png';
        await File(path).writeAsBytes(png, flush: true);
        _log('[srs-open] $label screenshot $path');
      }
      SrsReviewPage.debugPhase = null;
      SrsWebCardFace.debugMediaServed = null;
      appModel.navigatorKey.currentState!.pop();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return content;
    }

    // 冷：主页一出现就开（启动后的后台任务还在跑）；热：静置 90 s 后再开。
    final int cold = await openOnce('cold');
    final Stopwatch idle = Stopwatch()..start();
    while (idle.elapsed < const Duration(seconds: 90)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final int warm = await openOnce('warm');
    _log('[srs-open] cold=$cold ms warm=$warm ms');
    expect(cold, greaterThanOrEqualTo(0), reason: '冷开 90 s 内卡面应出现内容');
    expect(warm, greaterThanOrEqualTo(0), reason: '热开 90 s 内卡面应出现内容');
  }, skip: _seed.isEmpty || _deck.isEmpty);
}
