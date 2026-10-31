// 反馈 biLEesNqWb：浏览器扩展选了非激活配置 B，「在复习里打开」B 的笔记时编辑页必须读 B 的复习副本 /
// 媒体目录，编辑页再压的页面（修改历史 / 改笔记类型）与抽屉（预览）也一样——路由建在导航器的
// overlay 里、不在编辑页子树下，不带作用域就会落回根作用域（App 激活配置 A 的复习）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:material_ui/material_ui.dart';

/// 显示当前作用域里复习媒体目录的名字；[child] 给了就有一个按钮把它压成下一页（沿用作用域）。
class _MediaProbe extends ConsumerWidget {
  const _MediaProbe({required this.label, this.next});

  final String label;
  final Widget? next;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SrsMediaStore? media = ref.watch(srsMediaStoreProvider).valueOrNull;
    final Widget? nextPage = next;
    return Scaffold(
      body: Column(
        children: <Widget>[
          Text('$label:${media?.root.path ?? '-'}'),
          if (nextPage != null)
            TextButton(
              key: const ValueKey<String>('push-next'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => srsInheritProviderScope(context, nextPage),
                ),
              ),
              child: const Text('next'),
            ),
        ],
      ),
    );
  }
}

void main() {
  setUp(debugResetSrsNoteEditorLock);

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // 根作用域 = App 激活配置 A。
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => SrsMediaStore(Directory('media-A')),
          ),
        ],
        child: MaterialApp(
          navigatorKey: key,
          home: const _MediaProbe(label: 'home'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('带覆盖打开：编辑页与它再压的页面都读所选配置的复习', (WidgetTester tester) async {
    final NavigatorState nav = await pumpApp(tester);
    expect(find.text('home:media-A'), findsOneWidget);

    expect(
      await srsPushNoteEditor(
        nav,
        'n1',
        overrides: <Override>[
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => SrsMediaStore(Directory('media-B')),
          ),
        ],
        pageBuilder: (String id) => const _MediaProbe(
          label: 'editor',
          next: _MediaProbe(label: 'history'),
        ),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.text('editor:media-B'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('push-next')));
    await tester.pumpAndSettle();
    expect(
      find.text('history:media-B'),
      findsOneWidget,
      reason: '编辑页压出的页面沿用 B 的作用域，不落回根作用域的 A',
    );
  });

  testWidgets('不带覆盖：仍是 App 激活配置的复习（原样）', (WidgetTester tester) async {
    final NavigatorState nav = await pumpApp(tester);
    await srsPushNoteEditor(
      nav,
      'n2',
      pageBuilder: (String id) => const _MediaProbe(
        label: 'editor',
        next: _MediaProbe(label: 'history'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('editor:media-A'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('push-next')));
    await tester.pumpAndSettle();
    expect(find.text('history:media-A'), findsOneWidget);
  });
}
