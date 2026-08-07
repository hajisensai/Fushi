import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';

/// 设置 schema 缓存（见 `settings_schema.dart` 的 `_SettingsSchemaCache`）。
///
/// 背景：`SettingsContext.refresh` 恒为宿主 `setState`，于是任何一次开关翻转 / 滑条
/// tick / 搜索框击键都会重跑宿主 `build`；而此前四个消费点（设置主页、详情页、
/// 阅读器快捷面板、视频快捷面板）每次 build 都各自把 13 个分类、46 个 section、
/// 230 个 item 连同上千个闭包整树重建一遍——视频面板还是每个 group 一次。实测桌面
/// JIT 单次全量构造 ~1.27ms，拖滑条时逐帧纯浪费。
///
/// 缓存成立的前提是**这棵树是纯的**：所有对 appModel / 平台 / 同步状态的读取都写在
/// item 闭包里（渲染时求值），构造期唯一动态输入是 i18n locale。本文件两头钉：
/// 行为侧钉「命中同一实例 + 换 locale 自动重建 + 共享树只读」，源码侧钉那个纯度
/// 前提（分类构建函数零参、树里没有构造期读动态状态的口子）——前提一破，缓存就会
/// 悄悄发陈旧数据，这是本改动唯一的真风险。
void main() {
  Future<SettingsContext> makeContext(WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_schema_cache_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tempDir,
      )
      ..wireDatabaseForTesting(db);

    late SettingsContext sctx;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    return sctx;
  }

  group('schema 缓存行为', () {
    testWidgets('同一 locale 下重复构造命中同一棵树（不再逐次全量重建）', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      resetSettingsSchemaCache();

      final List<SettingsDestination> first = buildSettingsSchema(sctx);
      final List<SettingsDestination> second = buildSettingsSchema(sctx);

      expect(identical(first, second), isTrue,
          reason: '第二次调用必须命中缓存，而不是重新构造 230 个 item');
      // destination 实例本身也必须是同一批（否则渲染器的 KeyedSubtree / Element
      // 复用会因每帧换新对象而失去意义）。
      for (int i = 0; i < first.length; i++) {
        expect(identical(first[i], second[i]), isTrue);
      }
    });

    testWidgets('reader / video 投影分组同样只算一次', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      resetSettingsSchemaCache();

      expect(identical(collectReaderItems(sctx), collectReaderItems(sctx)),
          isTrue);
      expect(
          identical(collectVideoItems(sctx), collectVideoItems(sctx)), isTrue);
    });

    testWidgets('显式复位后重建，且内容等价', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      resetSettingsSchemaCache();
      final List<SettingsDestination> before = buildSettingsSchema(sctx);

      resetSettingsSchemaCache();
      final List<SettingsDestination> after = buildSettingsSchema(sctx);

      expect(identical(before, after), isFalse, reason: '复位后必须真的重建');
      expect(
        after.map((SettingsDestination d) => d.id).toList(),
        before.map((SettingsDestination d) => d.id).toList(),
        reason: '重建出来的分类序列必须与缓存那棵一致',
      );
    });

    testWidgets('切界面语言自动失效：title 跟着换语言', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      final AppLocale original = LocaleSettings.currentLocale;
      addTearDown(() => LocaleSettings.setLocale(original));

      LocaleSettings.setLocale(AppLocale.en);
      resetSettingsSchemaCache();
      final List<SettingsDestination> en = buildSettingsSchema(sctx);
      final String enTitle = en.first.title;

      LocaleSettings.setLocale(AppLocale.ja);
      final List<SettingsDestination> ja = buildSettingsSchema(sctx);

      expect(identical(en, ja), isFalse,
          reason: 'locale 是缓存键：换语言必须重建，否则设置页会卡在旧语言');
      expect(ja.first.title, isNot(enTitle),
          reason: 'i18n 在构造期求值，重建后 title 必须是新语言的');

      // 切回去同样要跟随（不是「只认第一次切换」）。
      LocaleSettings.setLocale(AppLocale.en);
      expect(buildSettingsSchema(sctx).first.title, enTitle);
    });

    testWidgets('共享树是只读的：调用方改不动，污染不了其它面板', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      resetSettingsSchemaCache();

      expect(
          () => buildSettingsSchema(sctx).removeLast(), throwsUnsupportedError);
      final Map<ReaderGroup, List<SettingsItem>> reader =
          collectReaderItems(sctx);
      expect(() => reader.remove(ReaderGroup.layout), throwsUnsupportedError);
      final List<SettingsItem>? layout = reader[ReaderGroup.layout];
      expect(layout, isNotNull);
      expect(() => layout!.clear(), throwsUnsupportedError);
      expect(() => collectVideoItems(sctx).clear(), throwsUnsupportedError);
    });
  });

  group('纯度前提（行为侧）', () {
    /// 整棵树的静态文案不得随运行期状态变化。
    ///
    /// 这条守卫是被真实反例逼出来的：诊断分区那三行（错误日志 / 崩溃转储 / 调试
    /// 日志）原本把实时条数插进 `title`，于是整棵 schema 事实上是个状态载体——只能
    /// 靠「每次 setState 全量重建」来刷新，崩溃转储那行还顺带每帧做一次同步目录
    /// 扫描。零参守卫拦不住这类：`ErrorLogService.instance` 不需要任何参数就能读到
    /// 运行期状态。故这里直接钉行为：改变全局状态 → 重建 → 所有静态 title/subtitle
    /// 必须逐字不变。动态文案一律走 `titleBuilder`（渲染时求值）。
    testWidgets('改变运行期状态后重建，静态文案逐字不变', (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      await ErrorLogService.instance.clear();
      addTearDown(() => ErrorLogService.instance.clear());

      List<String> staticText() {
        resetSettingsSchemaCache();
        return <String>[
          for (final SettingsDestination d in buildSettingsSchema(sctx))
            for (final SettingsSection s in d.sections)
              for (final SettingsItem i in s.items)
                '${i.id} :: ${i.title} :: ${i.subtitle ?? ''}',
        ];
      }

      final List<String> before = staticText();
      expect(before, isNotEmpty);

      ErrorLogService.instance.log('SettingsSchemaCache.test', 'boom');

      expect(staticText(), before,
          reason: '有 item 把运行期状态插进了静态 title——那会让缓存发陈旧文案。'
              '实时文案请改用 SettingsItem.titleBuilder（渲染时求值）。');
    });

    testWidgets('诊断计数走 titleBuilder：静态 title 不动，resolveTitle 跟着动',
        (WidgetTester tester) async {
      final SettingsContext sctx = await makeContext(tester);
      await ErrorLogService.instance.clear();
      addTearDown(() => ErrorLogService.instance.clear());
      resetSettingsSchemaCache();

      SettingsItem errorLogRow() => buildSettingsSchema(sctx)
          .expand((SettingsDestination d) => d.sections)
          .expand((SettingsSection s) => s.items)
          .firstWhere((SettingsItem i) => i.id == 'diagnostics.error_log');

      final SettingsItem row = errorLogRow();
      final String staticTitle = row.title;
      final String empty = row.resolveTitle(sctx);

      ErrorLogService.instance.log('SettingsSchemaCache.test', 'boom');

      // 同一个缓存实例（没重建），但解析出来的标题必须已经跟上。
      expect(identical(errorLogRow(), row), isTrue);
      expect(row.title, staticTitle, reason: '静态 title 是常量，不该动');
      expect(row.resolveTitle(sctx), isNot(empty),
          reason: '计数变了，渲染用的标题必须跟着变——否则用户看不到新日志条数');
    });
  });

  group('纯度前提（源码侧）', () {
    String schemaSource() =>
        File('lib/src/settings/settings_schema.dart').readAsStringSync();

    test('分类构建调用全部零参——传了 context 就意味着构造期读动态状态', () {
      // 真相源函数名与 destination 调用后缀都放在这条注释里，好让「把断言字面量
      // 塞进注释」的变异也骗不过下面的结构化扫描：_buildDestinations /
      // buildXxxDestination()。
      final String body = methodBody(
        schemaSource(),
        'List<SettingsDestination> _buildDestinations',
      );
      final RegExp call = RegExp(r'build(\w+)Destination\(([^)]*)\)');
      final Iterable<RegExpMatch> matches = call.allMatches(maskComments(body));
      expect(matches.length, greaterThanOrEqualTo(12),
          reason: '扫描没抓到分类调用，守卫本身塌了');
      for (final RegExpMatch match in matches) {
        expect(match.group(2)!.trim(), isEmpty,
            reason: 'build${match.group(1)}Destination 收了参数：schema 缓存假设'
                '构造期只依赖 locale，一旦分类构建读 SettingsContext，缓存就会'
                '发陈旧数据。要读动态状态请写进 item 闭包。');
      }
    });

    test('这 13 个分类构建函数的定义签名也是零参', () {
      // 只钉 `_buildDestinations()` 真正调用的那批，不搞「凡 build*Destination
      // 都得零参」的宽扫描——`buildReaderGroupDestination` /
      // `buildVideoGroupDestination` / `buildReaderQuickSettingsDestination` 是
      // 读缓存的投影包装器，收参数是对的，它们不参与构造期求值。
      final String body = methodBody(
        schemaSource(),
        'List<SettingsDestination> _buildDestinations',
      );
      final Set<String> called = RegExp(r'build(\w+)Destination\(')
          .allMatches(maskComments(body))
          .map((RegExpMatch m) => 'build${m.group(1)}Destination')
          .toSet();
      expect(called.length, greaterThanOrEqualTo(12),
          reason: '扫描没抓到分类调用，守卫本身塌了');

      final List<String> sources = <String>['lib/src/settings', 'lib/src/sync']
          .map((String dir) => Directory(dir))
          .expand((Directory dir) => dir.listSync())
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .map((File f) => maskComments(f.readAsStringSync()))
          .toList();

      for (final String name in called) {
        final RegExp definition = RegExp(
            '^SettingsDestination $name' r'\(([^)]*)\)',
            multiLine: true);
        final Iterable<RegExpMatch> hits =
            sources.expand((String src) => definition.allMatches(src));
        expect(hits, isNotEmpty, reason: '找不到 $name 的定义，守卫本身塌了');
        for (final RegExpMatch match in hits) {
          expect(match.group(1)!.trim(), isEmpty,
              reason: '$name 收了参数：schema 缓存假设构造期只依赖 locale，'
                  '一旦分类构建读 SettingsContext，缓存就会发陈旧数据。'
                  '要读动态状态请写进 item 闭包。');
        }
      }
    });

    test('热重载复位钩子仍挂在 app 根上', () {
      // 缓存按 locale 命中，改 schema 源码不会改 locale——debug 热重载下必须由
      // reassemble 主动丢弃，否则改了设置项却看不到效果。
      final String main =
          maskComments(File('lib/main.dart').readAsStringSync());
      final String body = methodBody(main, 'void reassemble()');
      expect(body.contains('resetSettingsSchemaCache()'), isTrue,
          reason: '热重载不清 schema 缓存会让设置改动看不出效果');
    });
  });
}
