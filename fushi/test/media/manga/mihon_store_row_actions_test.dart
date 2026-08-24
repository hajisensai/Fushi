import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1805：仓库请求成功但目录为空时，页面上只剩一张干净的卡片配零插件，
/// 用户拿不到任何线索。上游把 legacy `index.min.json` 掏空成「你的 app 太旧」
/// 占位哨兵之后，这是最常见的失败形态。
///
/// BUG-1806：仓库地址没有编辑入口（`indexUrl` 是主键，只能删了重加）。
const String _kStoreUrl = 'https://repo.example/index.json';

void main() {
  late Directory root;
  late FushiDatabase database;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('hibiki-mihon-store-row-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: _kStoreUrl,
        name: 'Fixture repository',
        format: MihonStoreFormat.currentJson.name,
        signingKey: const Value<String?>('aabb'),
      ),
    );
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: _StubRuntime(),
    );
    await manager.reload();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(body: MihonExtensionsPage(manager: manager)),
        ),
      ),
    );
    await tester.pump();
  }

  /// 取仓库卡片副标题的完整文本（副标题恒以仓库地址开头）。
  String storeSubtitle(WidgetTester tester) {
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((Text text) => text.data ?? '')
        .firstWhere(
          (String data) => data.startsWith(_kStoreUrl),
          orElse: () => throw StateError('未找到仓库卡片副标题'),
        );
  }

  group('BUG-1805 空目录不再静默', () {
    testWidgets('仓库返回 0 条扩展时副标题给出明确说明', (WidgetTester tester) async {
      manager.available = const <MihonAvailableExtension>[];
      await pump(tester);

      expect(
        storeSubtitle(tester),
        contains(t.mihon_store_zero_extensions),
        reason: '零扩展必须有可读原因，不能只显示一行干净的 URL',
      );
    });

    testWidgets('仓库有扩展时不显示零扩展提示', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[_extension()];
      await pump(tester);

      expect(storeSubtitle(tester), _kStoreUrl);
      expect(find.textContaining(t.mihon_store_zero_extensions), findsNothing);
    });

    testWidgets('已有 lastError 时优先显示真实错误，不被零扩展提示顶掉',
        (WidgetTester tester) async {
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: _kStoreUrl,
          name: 'Fixture repository',
          format: MihonStoreFormat.currentJson.name,
          signingKey: const Value<String?>('aabb'),
          lastError: const Value<String?>('STORE_HTTP_404'),
        ),
      );
      await manager.reload();
      manager.available = const <MihonAvailableExtension>[];
      await pump(tester);

      final String subtitle = storeSubtitle(tester);
      expect(subtitle, contains('STORE_HTTP_404'));
      expect(subtitle, isNot(contains(t.mihon_store_zero_extensions)));
    });

    testWidgets('停用的仓库不报零扩展——它本来就不该拉', (WidgetTester tester) async {
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: _kStoreUrl,
          name: 'Fixture repository',
          format: MihonStoreFormat.currentJson.name,
          signingKey: const Value<String?>('aabb'),
          enabled: const Value<bool>(false),
        ),
      );
      await manager.reload();
      manager.available = const <MihonAvailableExtension>[];
      await pump(tester);

      expect(storeSubtitle(tester), _kStoreUrl);
    });
  });

  group('BUG-1806 仓库地址可编辑', () {
    testWidgets('卡片上有编辑入口，点开预填当前地址', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[_extension()];
      await pump(tester);

      final Finder edit = find.byIcon(Icons.edit_outlined);
      expect(edit, findsOneWidget, reason: 'BUG-1806 之前只有删除按钮');

      await tester.tap(edit);
      await tester.pumpAndSettle();

      expect(find.text(t.mihon_store_edit), findsWidgets);
      final EditableText field =
          tester.widget<EditableText>(find.byType(EditableText).last);
      expect(
        field.controller.text,
        _kStoreUrl,
        reason: '改地址的典型场景是换路径，不该让用户从零重打长 URL',
      );
    });

    testWidgets('编辑框声明 URL 键盘类型（BUG-1804 同源）', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[_extension()];
      await pump(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      final EditableText field =
          tester.widget<EditableText>(find.byType(EditableText).last);
      expect(
        field.keyboardType,
        TextInputType.url,
        reason: '普通文本键盘下中文输入法会把 :/. 转全角，地址必被拒',
      );
    });

    testWidgets('新增仓库对话框同样是 URL 键盘', (WidgetTester tester) async {
      manager.available = <MihonAvailableExtension>[_extension()];
      await pump(tester);

      // 空态里另有一个同图标的添加按钮，这里要的是工具栏那个。
      await tester.tap(find.byIcon(Icons.add_link).first);
      await tester.pumpAndSettle();

      final EditableText field =
          tester.widget<EditableText>(find.byType(EditableText).last);
      expect(field.keyboardType, TextInputType.url);
    });
  });
}

MihonAvailableExtension _extension() => const MihonAvailableExtension(
      storeUrl: _kStoreUrl,
      name: 'Sample extension',
      packageName: 'org.example.sample',
      apkUrl: 'https://repo.example/sample.apk',
      iconUrl: '',
      libVersion: '1.4',
      versionCode: 1,
      versionName: '1.0.0',
      language: 'en',
      contentWarning: 0,
      sources: <MihonAvailableSource>[
        MihonAvailableSource(
          id: '1',
          name: 'Sample source',
          language: 'en',
          baseUrl: 'https://sample.example',
        ),
      ],
    );

class _StubRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
