// 保留副本入口的页面接线（D32；规划 §6 K2 ①）：helper 本身见 srs_retained_copy_test.dart，这里测它们真的挂在页面上。
// - 牌组列表删牌组：有保留副本时「彻底清除」的说明写明副本里仍有原文；选彻底清除后再问副本去向，选立即删除 = 执行端
//   被调到、状态重读；
// - 状态读不了（内核报错）不挡删牌组：provider 记日志、按没有处理（不抛），删除照常走完；
// - 设置 › 存储「删除旧版本保留副本」行：有副本时出现、副标题报大小与到期，没有时隐藏；点它 = 确认后删、状态重读。
// 执行端是假的，不碰保留副本的原生命令（由 Rust retained_tests.rs 覆盖）；牌组库是真的临时库。
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_retained_copy.dart';
import 'package:fushi/src/srs/srs_storage_host.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart'
    show srsSyncRoundsSucceeded;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

const String _kDir = 'D:/lib';

const SrsRetainedCopyState _sealed = SrsRetainedCopyState(
  kind: SrsRetainedCopyKind.sealed,
  bytes: 3 * 1024 * 1024,
  migratedAtMs: 0,
  dueAtMs: 1767225600000,
);

class _Backend implements SrsRetainedCopyBackend {
  _Backend({this.refuseState});

  final String? refuseState;
  final List<String> deleted = <String>[];
  int states = 0;

  /// 内核记下的新代第一次同步成功时刻；null = 还没同步成功过（[_sealed] 的形状）。
  int? firstSyncAtMs;

  /// 给了 = 状态命令卡在这里，直到测试放行（模拟后台 isolate 读的过程）。
  Completer<void>? gate;

  /// 给了 = 状态命令固定报它（模拟别的副本形状，例如坏了的 unreadable）。
  SrsRetainedCopyState? fixed;

  @override
  Future<SrsRetainedCopyState> state(String dir, {required int nowMs}) async {
    states++;
    final Completer<void>? waitFor = gate;
    if (waitFor != null) await waitFor.future;
    final String? why = refuseState;
    if (why != null) throw SrsCoreException(-1, why);
    final SrsRetainedCopyState? pinned = fixed;
    if (pinned != null) return pinned;
    if (deleted.isNotEmpty) {
      return const SrsRetainedCopyState(kind: SrsRetainedCopyKind.tombstone);
    }
    final int? first = firstSyncAtMs;
    return first == null
        ? _sealed
        : SrsRetainedCopyState(
            kind: SrsRetainedCopyKind.sealed,
            bytes: _sealed.bytes,
            migratedAtMs: 0,
            firstSyncAtMs: first,
            dueAtMs: first + const Duration(days: 14).inMilliseconds,
          );
  }

  @override
  Future<SrsRetainedCopyDeletion> delete(String dir) async {
    deleted.add(dir);
    return const SrsRetainedCopyDeletion(deleted: true, freedBytes: 1);
  }
}

/// 主库已开、复习库目录 = [_kDir] 的 app（保留副本 provider 按它取目录）。
class _OpenAppModel extends SrsTestAppModel {
  @override
  bool get isDatabaseOpen => true;

  @override
  SrsStorageHost get srsStorage => SrsStorageHost(
    dbDirectory: _kDir,
    isMainProcess: false,
    legacyDatabase: () => throw UnimplementedError(),
  );
}

ThemeData _theme() => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  designSystem: FushiDesignSystem.material,
  glass: FushiGlassMaterial.off,
  glassDesign: false,
);

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  required _Backend backend,
  required Widget home,
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = _OpenAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith((Ref ref) async => null),
        srsRwkvServiceProvider.overrideWith((Ref ref) async => null),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        srsReviewChromeFloatingProvider.overrideWithValue(false),
        srsRetainedCopyBackendProvider.overrideWithValue(backend),
        ...overrides,
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: _theme(),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: home,
        ),
      ),
    ),
  );
  await srsSettle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<SrsDbStore> _storeWithDeck(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    openSrsTestStore,
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.runAsync(() => store.ensureDeckPath('Spark'));
  return store;
}

Future<bool> _hasSpark(WidgetTester tester, SrsDbStore store) async {
  final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
  return tree.decks.any((SrsDeckView d) => tree.fullName(d.id) == 'Spark');
}

/// 右键牌组行 →「删除牌组」→ 删除方式对话框。
Future<void> _openDeleteDialog(WidgetTester tester) async {
  // 宽屏上牌组名不止出现在树的行里（右栏也写着它）：逐个右键，出牌组菜单的那个才是行。
  final Finder menuDelete = find.text(t.srs_deck_delete);
  final int candidates = find.text('Spark').evaluate().length;
  for (int i = 0; i < candidates && menuDelete.evaluate().isEmpty; i++) {
    await tester.tap(
      find.text('Spark').at(i),
      buttons: kSecondaryButton,
      warnIfMissed: false,
    );
    await srsSettle(tester);
  }
  await tester.tap(menuDelete.last);
  await srsSettle(tester);
  expect(find.text(t.srs_deck_delete_purge), findsOneWidget);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    debugResetSrsFirstSyncAsked();
  });

  testWidgets('删牌组：有保留副本时彻底清除写明副本里仍有原文，再问去向；选立即删除 = 执行端删、状态重读', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend();
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: const SrsDeckListPage(),
    );
    await _openDeleteDialog(tester);
    expect(find.text(t.srs_deck_delete_purge_retained_hint), findsOneWidget);
    expect(find.text(t.srs_deck_delete_purge_hint), findsNothing);

    await tester.tap(find.text(t.srs_deck_delete_purge));
    await srsSettle(tester);
    expect(find.text(t.srs_deck_delete_purge_retained_title), findsOneWidget);
    expect(
      find.text(
        t.srs_deck_delete_purge_retained_body(
          size: FushiByteFormat.bytes(_sealed.bytes),
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(t.srs_deck_delete_purge_retained_delete));
    await srsSettle(tester);
    expect(backend.deleted, <String>[_kDir]);
    // 下一次读到的是删过之后的状态（不是删之前缓存的 sealed）。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(SrsDeckListPage)),
    );
    final SrsRetainedCopyInfo? after = (await tester
        .runAsync<SrsRetainedCopyInfo?>(
          () => container.read(srsRetainedCopyProvider.future),
        ));
    expect(after?.state.kind, SrsRetainedCopyKind.tombstone);
    expect(await _hasSpark(tester, store), isFalse, reason: '彻底清除照常做完');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('删牌组：保留副本状态读不了（内核报错）不挡删除，按没有处理、不再问去向', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend(refuseState: 'srs4.db is broken');
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: const SrsDeckListPage(),
    );
    await _openDeleteDialog(tester);
    expect(backend.states, greaterThan(0));
    expect(find.text(t.srs_deck_delete_purge_hint), findsOneWidget);
    await tester.tap(find.text(t.srs_deck_delete_purge));
    await srsSettle(tester);
    expect(find.text(t.srs_deck_delete_purge_retained_title), findsNothing);
    expect(await _hasSpark(tester, store), isFalse);
    expect(backend.deleted, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('设置 › 存储：有保留副本时出现「删除旧版本保留副本」并报大小；点它确认后删，删完行隐藏', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend();
    final SettingsActionItem item = buildStorageDestination().sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsActionItem>()
        .singleWhere(
          (SettingsActionItem i) => i.id == 'storage.srs_retained_copy',
        );
    bool? visible;
    String? subtitle;
    late SettingsContext ctx;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            ctx = SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            visible = item.visible!(ctx);
            subtitle = item.subtitleBuilder!(ctx);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(visible, isTrue);
    expect(subtitle, srsRetainedCopyStatusText(ctx.context, _sealed));

    // onTap 先等状态（已读好），再弹确认框。
    unawaited(Future<void>.sync(() => item.onTap(ctx)));
    await srsSettle(tester);
    expect(find.text(t.srs_retained_copy_confirm_action), findsOneWidget);
    await tester.tap(find.text(t.srs_retained_copy_confirm_action));
    await srsSettle(tester);
    expect(backend.deleted, <String>[_kDir]);
    expect(visible, isFalse, reason: '删完状态重读，行隐藏');
    expect(subtitle, isNull);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // BUG-5079：保留副本坏了（内核报 unreadable）以前在 UI 上和「没有」一样，用户毫无提示。现在设置 › 存储出现一条
  // 状态行说明退回旧版本的路没了、当前数据不受影响；删除行不出现（内核不删它）。正常的封存副本不出这条状态行。
  testWidgets('设置 › 存储：保留副本坏了时出现损坏提示行、不出删除行；封存的副本不出提示行', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend()
      ..fixed = const SrsRetainedCopyState(
        kind: SrsRetainedCopyKind.unreadable,
      );
    final List<SettingsItem> items = buildStorageDestination().sections
        .expand((SettingsSection s) => s.items)
        .toList();
    final SettingsStatusItem warning = items
        .whereType<SettingsStatusItem>()
        .singleWhere(
          (SettingsStatusItem i) =>
              i.id == 'storage.srs_retained_copy_unreadable',
        );
    final SettingsActionItem delete = items
        .whereType<SettingsActionItem>()
        .singleWhere(
          (SettingsActionItem i) => i.id == 'storage.srs_retained_copy',
        );
    expect(warning.title, t.srs_retained_copy_unreadable_title);
    expect(warning.subtitle, t.srs_retained_copy_unreadable_status);
    expect(warning.onAction, isNull, reason: '内核不删坏了的副本，不给动作');
    bool? warningVisible;
    bool? deleteVisible;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            final SettingsContext ctx = SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            warningVisible = warning.visible!(ctx);
            deleteVisible = delete.visible!(ctx);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(warningVisible, isTrue);
    expect(deleteVisible, isFalse);
    await _unmount(tester);

    backend.fixed = _sealed;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            final SettingsContext ctx = SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            warningVisible = warning.visible!(ctx);
            deleteVisible = delete.visible!(ctx);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(warningVisible, isFalse);
    expect(deleteVisible, isTrue);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // 第五波复核遗留：牌组列表横幅最前的清除收尾提示。出错时显示原因；没出错时根本不挂（横幅是带间距的列表，零高度的
  // 一项也占一条间距，把牌组树往下推——srs_pages_test 手机首页的最后一行就是这样被挤出屏幕的）。
  testWidgets('牌组列表：清除收尾出错时横幅提示原因（连同下方间距展开）；没出错时零高度、后面不留间距', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    SrsScrubState scrub = (due: true, error: 'database or disk is full');
    await _pump(
      tester,
      store: store,
      backend: _Backend(),
      home: const SrsDeckListPage(),
      overrides: <Override>[
        srsScrubStateProvider.overrideWith((Ref ref) async => scrub),
      ],
    );
    final Finder notice = find.text(
      t.srs_scrub_error_notice(reason: 'database or disk is full'),
    );
    expect(notice, findsOneWidget);
    // 零高度时 sliver 把它算作不可见，查找要带 skipOffstage: false。
    final Finder slot = find.byType(SrsScrubErrorNotice, skipOffstage: false);
    // 列表里紧跟在提示后面的那一项（列表项都包在 FushiStaggeredEntrance 里，按序号找下一个）的顶边。
    double nextTop() {
      final FushiStaggeredEntrance own = tester.widget<FushiStaggeredEntrance>(
        find
            .ancestor(
              of: slot,
              matching: find.byType(
                FushiStaggeredEntrance,
                skipOffstage: false,
              ),
            )
            .first,
      );
      final Finder next = find
          .descendant(
            of: find
                .ancestor(
                  of: slot,
                  matching: find.byType(ListView, skipOffstage: false),
                )
                .first,
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is FushiStaggeredEntrance && w.index == own.index + 1,
            ),
          )
          .first;
      return tester.getTopLeft(next).dy;
    }

    final double gap =
        tester.getBottomLeft(slot).dy - tester.getBottomLeft(notice).dy;
    expect(gap, greaterThan(0), reason: '出错时间距由提示自己带');
    expect(nextTop(), tester.getBottomLeft(slot).dy, reason: '列表不在它后面另插间距');

    scrub = (due: false, error: null);
    ProviderScope.containerOf(
      tester.element(find.byType(SrsDeckListPage)),
    ).invalidate(srsScrubStateProvider);
    await srsSettle(tester);
    expect(notice, findsNothing);
    expect(tester.getSize(slot).height, 0, reason: '没出错时零高度');
    expect(
      nextTop(),
      tester.getTopLeft(slot).dy,
      reason: '零高度的提示项后面不留一条空白（第六波 ①：会把牌组树往下推出屏）',
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // 第五波复核遗留：保留副本状态（后台 isolate 打开两个库文件）不跟复习库修订号重读；没人看就释放，下次进页面现读。
  testWidgets('保留副本状态：修订号怎么跳都不重读；没人看时释放，再看时现读一次', (WidgetTester tester) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend();
    final ValueNotifier<bool> watching = ValueNotifier<bool>(true);
    addTearDown(watching.dispose);
    SrsRetainedCopyState? seen;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: watching,
          builder: (BuildContext context, bool on, Widget? _) => on
              ? Consumer(
                  builder: (BuildContext context, WidgetRef ref, Widget? _) {
                    seen = ref
                        .watch(srsRetainedCopyProvider)
                        .valueOrNull
                        ?.state;
                    return const SizedBox();
                  },
                )
              : const SizedBox(),
        ),
      ),
    );
    expect(seen?.kind, SrsRetainedCopyKind.sealed);
    expect(backend.states, 1);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    for (int i = 0; i < 3; i++) {
      container.read(srsRevisionProvider.notifier).state++;
      await srsSettle(tester);
    }
    expect(backend.states, 1, reason: '评分 / 编辑 / 同步拉入不改变保留副本');

    watching.value = false;
    await srsSettle(tester);
    watching.value = true;
    await srsSettle(tester);
    expect(backend.states, 2, reason: '释放之后再看 = 现读');
    expect(seen?.kind, SrsRetainedCopyKind.sealed);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // 第六波复核：第一次同步成功之后到期时刻改成「首次同步 + 14 天」；设置页开着时日期要跟着变（等下一轮成功的同步重读
  // 一次），记下首次同步之后再成功也不重读。
  testWidgets('保留副本状态：还没记下首次同步时，下一轮成功的同步之后重读一次；记下之后不再重读', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend();
    SrsRetainedCopyState? seen;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            seen = ref.watch(srsRetainedCopyProvider).valueOrNull?.state;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen?.firstSyncAtMs, isNull);
    expect(backend.states, 1);

    backend.firstSyncAtMs = 1767225600000;
    srsSyncRoundsSucceeded.value++;
    await srsSettle(tester);
    expect(backend.states, 2, reason: '第一次同步成功之后重读');
    expect(seen?.firstSyncAtMs, 1767225600000);
    expect(
      seen?.dueAtMs,
      1767225600000 + const Duration(days: 14).inMilliseconds,
    );

    srsSyncRoundsSucceeded.value++;
    await srsSettle(tester);
    expect(backend.states, 2, reason: '记下首次同步之后再成功不重读');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // 第六波第二轮复核：读状态的过程中 provider 被 invalidate（换库、删除的调用方），以前读完才挂的同步监听摘不掉
  // （这次构建已经废弃，onDispose 抛），之后每一轮成功的同步都让它重读一次。
  testWidgets('保留副本状态：读的过程中被 invalidate 不留下同步监听；记下首次同步之后再成功不重读', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _storeWithDeck(tester);
    final _Backend backend = _Backend();
    SrsRetainedCopyState? seen;
    await _pump(
      tester,
      store: store,
      backend: backend,
      home: Scaffold(
        body: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            seen = ref.watch(srsRetainedCopyProvider).valueOrNull?.state;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(backend.states, 1);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );

    final Completer<void> gate = Completer<void>();
    backend.gate = gate;
    container.invalidate(srsRetainedCopyProvider);
    await srsSettle(tester);
    expect(backend.states, 2, reason: '重读开始，卡在状态命令里');
    // 读还没完就被 invalidate，紧接着放行：那次构建在下一次重建之前读完（已经废弃）。
    container.invalidate(srsRetainedCopyProvider);
    backend.gate = null;
    gate.complete();
    await srsSettle(tester);
    expect(backend.states, 3, reason: '废弃之后重新读一次');
    expect(seen?.firstSyncAtMs, isNull);

    backend.firstSyncAtMs = 1767225600000;
    srsSyncRoundsSucceeded.value++;
    await srsSettle(tester);
    expect(backend.states, 4, reason: '第一次同步成功之后只重读一次');
    expect(seen?.firstSyncAtMs, 1767225600000);
    for (int i = 0; i < 3; i++) {
      srsSyncRoundsSucceeded.value++;
      await srsSettle(tester);
    }
    expect(backend.states, 4, reason: '废弃的那次构建不能留下监听');
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}
