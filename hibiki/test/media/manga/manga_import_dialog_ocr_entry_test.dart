/// 漫画 P3：漫画导入对话框「OCR 导入漫画」入口 gating。
///
/// ## 换宿主（漫画/书籍导入分家）
///
/// 入口原先挂在**书籍**导入框上——那是漫画和书挤在同一个对话框时代的产物。分家后
/// OCR 入口随漫画域迁到 [MangaImportDialog]，本测试整体跟着换宿主；下面的 gating
/// 判据（两端都亮、两端 probeCalls 都必须是 0）逐条保留，一条没放宽。
///
/// ## 判据换靶（PR#474，BUG-1164）
///
/// 旧判据是「移动端默认隐藏，探测到具备 `capabilities.mangaOcr.supported` 的
/// 已配对 host 后才亮出入口」。它防的是**在移动端亮出一个点了必然失败的入口**
/// ——当时移动端一条可用引擎都没有（内置 ONNX 与外部 mokuro CLI 都是桌面工具），
/// 唯一出路是借已配对 host 代跑。
///
/// PR#474 引入 Google Lens 引擎后这个前提消失了：`MangaModule.openOcrImportWizard`
/// 无条件注入 `lensRunner: GoogleLensMangaOcrService()`（只有 `externalRunner`
/// 还带 desktop 三元），移动端在向导里就有可用引擎。继续沿用旧判据会**藏起一个
/// 真能用的功能**，所以判据换靶而不是放宽：
///
/// - 两端都必须亮出入口（能力已全平台可用）；
/// - 两端 `probeCalls` 都必须是 0 —— 入口不再依赖探测，也**不许**为了决定渲染
///   一个按钮而偷偷发一次局域网探测请求。这条比旧判据更严（旧判据允许移动端发
///   一次探测），把「渲染决策不产生网络副作用」钉死。
///
/// 已配对 host 代跑本身没有下线：runner 仍经构造注入并透传给向导，由用户在
/// 向导里显式选 `pairedHost` 引擎时才使用。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/manga_import_dialog.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner({this.target});

  final MangaOcrRemoteTarget? target;
  int probeCalls = 0;

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    probeCalls += 1;
    return target;
  }

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrRemoteEvent>.empty();
}

const MangaOcrRemoteTarget _capableTarget = MangaOcrRemoteTarget(
  baseUrl: 'http://192.168.1.2:1234',
  capability: MangaOcrRemoteCapability(supported: true, modelsReady: true),
);

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool desktop,
    required _FakeRemoteRunner runner,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: MangaImportDialog(
                db: db,
                mangaOcrRemoteRunner: runner,
                ocrEntryDesktopOverride: desktop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: OCR entry always visible, no probe needed',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: null);
    await pumpDialog(tester, desktop: true, runner: runner);
    expect(find.text(t.manga_ocr_wizard_title), findsOneWidget);
    expect(runner.probeCalls, 0, reason: '桌面入口不依赖探测');
  });

  testWidgets('mobile: entry is visible because Lens works on every platform',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: _capableTarget);
    await pumpDialog(tester, desktop: false, runner: runner);
    expect(find.text(t.manga_ocr_wizard_title), findsOneWidget);
    expect(runner.probeCalls, 0, reason: '入口不再依赖探测，渲染决策不得产生网络副作用');
  });

  testWidgets('mobile: entry stays visible without any paired host',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: null);
    await pumpDialog(tester, desktop: false, runner: runner);
    expect(find.text(t.manga_ocr_wizard_title), findsOneWidget,
        reason: '没有已配对 host 也有 Google Lens 可用，不能藏起入口');
    expect(runner.probeCalls, 0);
  });
}
