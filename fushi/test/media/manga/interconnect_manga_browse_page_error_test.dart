/// BUG-2515：对端漫画库浏览页的错误态必须走本地化文案；一台都没配对时给「去配对」
/// 而不是永远失败的「重试」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_browse_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

class _FailingBackend extends Fake implements InterconnectSyncBackend {
  _FailingBackend(this.error);

  final Exception error;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => throw error;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => ProviderScope(
    child: TranslationProvider(child: MaterialApp(home: child)),
  );

  testWidgets('未配对：本地化句子 + 「去配对」，裸 SyncAuthError 不上屏、没有「重试」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        InterconnectMangaBrowsePage(
          backend: _FailingBackend(
            SyncAuthError(
              'Fushi server credentials not configured',
              kind: SyncAuthFailureKind.pairingNotConfigured,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.sync_err_not_paired), findsOneWidget);
    expect(find.textContaining('SyncAuthError'), findsNothing);
    expect(find.textContaining('credentials not configured'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('interconnect_manga_pair')),
      findsOneWidget,
    );
    expect(find.text(t.manga_source_interconnect_pair_action), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('interconnect_manga_retry')),
      findsNothing,
    );
  });

  testWidgets('普通失败：友好包装 + 「重试」', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        InterconnectMangaBrowsePage(
          backend: _FailingBackend(SyncBackendError('peer offline')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('interconnect_manga_retry')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('interconnect_manga_pair')),
      findsNothing,
    );
    expect(find.textContaining('peer offline'), findsOneWidget);
  });
}
