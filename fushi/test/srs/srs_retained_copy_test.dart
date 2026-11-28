// 旧版本保留副本与清除字节层收尾的 app 侧入口（srs_retained_copy.dart；D32、规划 §6 K2 合并条件 ①②）：
// - 彻底清除选项的说明：本机有保留副本时写明里面仍有升级前的原文、怎么删；没有时用原说明；
// - 彻底清除之后问保留副本的去向：有副本才问、两个选项、取消 = null；选「立即删除」才调执行端；
// - 设置行副标题：大小 + 到期日 / 一直保留 / 自动删出错的原因；
// - scrub_state 的 error 非空时提示「清除的内容在磁盘上还没抹干净：<原因>」，没出错时不出现。
// 执行端是假的，不碰原生库（原生命令由 Rust retained_tests.rs 与 fushi_srs srs_retained_copy_test.dart 覆盖）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/srs/srs_retained_copy.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsScrubState;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

const SrsRetainedCopyState sealed = SrsRetainedCopyState(
  kind: SrsRetainedCopyKind.sealed,
  bytes: 3 * 1024 * 1024,
  migratedAtMs: 0,
  dueAtMs: 1767225600000,
);

class _Backend implements SrsRetainedCopyBackend {
  final List<String> deleted = <String>[];

  @override
  Future<SrsRetainedCopyState> state(String dir, {required int nowMs}) async =>
      sealed;

  @override
  Future<SrsRetainedCopyDeletion> delete(String dir) async {
    deleted.add(dir);
    return const SrsRetainedCopyDeletion(deleted: true, freedBytes: 1);
  }
}

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    // 每次一个新的 ProviderScope：同一个 scope 换 overrides 不会重建已读过的 provider。
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('the purge option names the retained copy only when there is one', () {
    expect(srsPurgeOptionHint(sealed), t.srs_deck_delete_purge_retained_hint);
    expect(
      srsPurgeOptionHint(sealed),
      allOf(contains('retained copy'), contains('Settings › Storage')),
    );
    // 没有到期时刻（这一版之前的开发构建迁出来的库）：不说「到期自动删除」。
    expect(
      srsPurgeOptionHint(
        SrsRetainedCopyState(kind: sealed.kind, bytes: sealed.bytes),
      ),
      t.srs_deck_delete_purge_retained_kept_hint,
    );
    expect(
      t.srs_deck_delete_purge_retained_kept_hint,
      isNot(contains('automatically')),
    );
    expect(srsPurgeOptionHint(null), t.srs_deck_delete_purge_hint);
    expect(
      srsPurgeOptionHint(
        const SrsRetainedCopyState(kind: SrsRetainedCopyKind.tombstone),
      ),
      t.srs_deck_delete_purge_hint,
    );
  });

  testWidgets('without a retained copy the purge goes on without asking', (
    WidgetTester tester,
  ) async {
    SrsPurgeRetainedChoice? got;
    await pump(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async => got = await askSrsPurgeRetainedCopy(
            context,
            const SrsRetainedCopyState(kind: SrsRetainedCopyKind.absent),
          ),
          child: const Text('go'),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(got, SrsPurgeRetainedChoice.keep);
    expect(find.text(t.srs_deck_delete_purge_retained_title), findsNothing);
  });

  testWidgets(
    'with a retained copy the purge asks; deleting now calls the backend',
    (WidgetTester tester) async {
      final _Backend backend = _Backend();
      SrsPurgeRetainedChoice? got;
      await pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async =>
                got = await askSrsPurgeRetainedCopy(context, sealed),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text(t.srs_deck_delete_purge_retained_title), findsOneWidget);
      expect(
        find.text(
          t.srs_deck_delete_purge_retained_body(
            size: FushiByteFormat.bytes(sealed.bytes),
          ),
        ),
        findsOneWidget,
      );
      expect(find.text(t.srs_deck_delete_purge_retained_keep), findsOneWidget);
      await tester.tap(find.text(t.srs_deck_delete_purge_retained_delete));
      await tester.pumpAndSettle();
      expect(got, SrsPurgeRetainedChoice.deleteNow);

      expect(
        await settleSrsPurgeRetainedCopy(
          SrsPurgeRetainedChoice.keep,
          backend,
          'D:/lib',
        ),
        isFalse,
      );
      expect(backend.deleted, isEmpty);
      expect(await settleSrsPurgeRetainedCopy(got!, backend, 'D:/lib'), isTrue);
      expect(backend.deleted, <String>['D:/lib']);
    },
  );

  testWidgets('the settings subtitle shows size and expiry, or the error', (
    WidgetTester tester,
  ) async {
    late BuildContext ctx;
    await pump(
      tester,
      Builder(
        builder: (BuildContext context) {
          ctx = context;
          return const SizedBox();
        },
      ),
    );
    final String size = FushiByteFormat.bytes(sealed.bytes);
    expect(
      srsRetainedCopyStatusText(ctx, sealed),
      t.srs_retained_copy_status_due(
        size: size,
        date: MaterialLocalizations.of(ctx).formatMediumDate(
          DateTime.fromMillisecondsSinceEpoch(sealed.dueAtMs!),
        ),
      ),
    );
    expect(
      srsRetainedCopyStatusText(
        ctx,
        SrsRetainedCopyState(kind: sealed.kind, bytes: sealed.bytes),
      ),
      t.srs_retained_copy_status_kept(size: size),
    );
    expect(
      srsRetainedCopyStatusText(
        ctx,
        SrsRetainedCopyState(
          kind: sealed.kind,
          bytes: sealed.bytes,
          dueAtMs: 1,
          error: 'disk full',
        ),
      ),
      t.srs_retained_copy_status_error(size: size, error: 'disk full'),
    );
  });

  testWidgets('a scrub error is shown; nothing otherwise', (
    WidgetTester tester,
  ) async {
    Future<void> withState(SrsScrubState? s) => pump(
      tester,
      const SrsScrubErrorNotice(),
      overrides: <Override>[
        srsScrubStateProvider.overrideWith((Ref ref) async => s),
      ],
    );
    await withState((due: true, error: 'database or disk is full'));
    expect(
      find.text(t.srs_scrub_error_notice(reason: 'database or disk is full')),
      findsOneWidget,
    );
    expect(
      t.srs_scrub_error_notice(reason: 'x'),
      'Purged content is not yet wiped from disk: x',
    );
    await withState((due: true, error: null));
    expect(find.byKey(const ValueKey<String>('srs-scrub-error')), findsNothing);
    await withState(null);
    expect(find.byKey(const ValueKey<String>('srs-scrub-error')), findsNothing);
  });
}
