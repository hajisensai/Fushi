import 'dart:async';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/video/iptv_playlist_import_dialog.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

// HBK-AUDIT-037 / BUG-2994：导入进行中（ImportFlowMixin.importing）对话框不能被
// 返回键 / 点遮罩关掉——没有取消通道，关掉只会让用户以为导入停了。导入结束后
// 恢复可关闭。真实对话框 + 真实 mixin，动作用受控 Completer 挂起，不碰文件/网络。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  final Map<String, Widget Function(FushiDatabase db)> dialogs =
      <String, Widget Function(FushiDatabase db)>{
        'manga': (FushiDatabase db) => MangaImportDialog(db: db),
        'video': (FushiDatabase db) =>
            VideoImportDialog(repo: VideoBookRepository(db)),
        'iptv': (FushiDatabase db) =>
            IptvPlaylistImportDialog(repo: VideoBookRepository(db)),
      };

  for (final MapEntry<String, Widget Function(FushiDatabase db)> entry
      in dialogs.entries) {
    testWidgets('${entry.key} import stays open while its action is pending', (
      WidgetTester tester,
    ) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final Completer<void> gate = Completer<void>();
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      final Widget dialog = entry.value(db);
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigator,
              theme: ThemeData(
                useMaterial3: true,
                splashFactory: NoSplash.splashFactory,
              ),
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (BuildContext context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (BuildContext _) => dialog,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final Finder finder = find.byWidget(dialog);
      final ImportFlowMixin<StatefulWidget> flow =
          tester.state(finder) as ImportFlowMixin<StatefulWidget>;
      final Future<void> pending = flow.runImport(
        logTag: 'busy-pop-guard-test',
        action: () => gate.future,
      );
      await tester.pump();
      expect(flow.importing, isTrue);

      // 返回键（系统返回 / Esc 都走 maybePop）。
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(
        finder,
        findsOneWidget,
        reason: 'Back must not hide a running import.',
      );
      // 点遮罩（对话框外的左上角）。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        finder,
        findsOneWidget,
        reason: 'Barrier must not hide a running import.',
      );

      gate.complete();
      await pending;
      await tester.pumpAndSettle();
      expect(flow.importing, isFalse);
      expect(finder, findsOneWidget);

      // 导入结束后恢复可关闭。
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(finder, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
