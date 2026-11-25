// 复习模块页面测试：界面操作触发写库之后，按真实的「写完了」信号推进，再读库 / 断言。
//
// 页面的写入是内核命令，在 worker isolate 上真实往返（packages/fushi_engine/lib/srs/srs_db_store.dart 的
// `_coreSync2`）。固定几轮 `_settle` 只给了一段固定的真实时间：全量并发跑、机器满载时 worker 排不上 CPU，
// 写入还没回来就去读库，间歇读到旧值（PR #3440 查明的三条间歇红）。这里只等产品自己发出的信号，不睡固定时长、
// 不重试；信号超时明确 fail。
//
// 两种信号，按页面怎么通知写入选：
// - [srsSettleUntilWritten]：页面在写命令返回（已提交）之后才 `bumpSrsRevision`，[srsRevisionProvider] 越过
//   操作前的值 = 整个页面操作写完了。绝大多数页面写入走这条。
// - [srsSettleUntilStoreWritten]：页面刻意不发修订号的写入（牌组收起 / 展开、复习页评分 / 撤销），等
//   [SrsDbStore.revision]——它只由内核提交后的回包赋值，越过操作前的值 = 这次写命令已落库。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart'
    show FushiIconButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

/// 等信号的上限：远大于任何正常写入，只用来让真卡死的用例明确报红而不是挂到测试超时。
const Duration _kWriteTimeout = Duration(minutes: 2);

/// 页面所在的 Riverpod 容器（读 [srsRevisionProvider] / 重读中的 provider 用）。
ProviderContainer srsPageContainer(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(
        find
            .descendant(
              of: find.byType(UncontrolledProviderScope),
              matching: find.byWidgetPredicate((Widget _) => true),
            )
            .first,
      ),
      listen: false,
    );

/// 页面当前的修订号：在触发写入的界面操作之前记下，交给 [srsSettleUntilWritten]。
int srsPageRevision(WidgetTester tester) =>
    srsPageContainer(tester).read(srsRevisionProvider);

/// 浮动工具栏上 [key] 那一项此刻可不可按（`FushiToolbarItem.onPressed` 非空）。
///
/// 页面在一次写入的整个流程里（写库 → 发修订号 → 重读）置忙、把撤销等动作的回调置空；修订号到了不代表流程走完，
/// 紧接着点下一个动作要先等它重新可按，否则这一下点在忙态上被吞掉。
bool srsToolbarItemEnabled(WidgetTester tester, Key key) => find
    .descendant(
      of: find.byKey(key).first,
      matching: find.byWidgetPredicate(
        (Widget w) =>
            (w is FushiIconButtonControl && w.onPressed != null) ||
            (w is FushiIconButton && w.onTap != null) ||
            (w is IconButton && w.onPressed != null) ||
            (w is InkResponse && w.onTap != null),
      ),
      matchRoot: true,
    )
    .evaluate()
    .isNotEmpty;

/// 推进一步：让后台 isolate 的回包有机会送达（真实时间），再推进界面一帧。
Future<void> _step(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump(const Duration(milliseconds: 60));
}

/// 推进直到 [done] 成立；[_kWriteTimeout] 墙钟内不成立就以 [what] 报红。
Future<void> srsPumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required String what,
}) async {
  final Stopwatch waited = Stopwatch()..start();
  while (!done()) {
    if (waited.elapsed > _kWriteTimeout) {
      fail('两分钟内没有等到：$what');
    }
    await _step(tester);
  }
}

/// 收尾：信号到了之后再推进 [rounds] 步，让写完触发的重建、动画落定（不是在等写入）。
Future<void> _settleAfter(WidgetTester tester, int rounds) async {
  for (int i = 0; i < rounds; i++) {
    await _step(tester);
  }
}

/// 等页面上一个操作发起的写入落库（之后再从库里读断言）。
///
/// [before] 是操作前 [srsPageRevision] 的值。写完后要按新数据重读的 provider（如牌组列表）放进 [reloads]，
/// 也等它们读完；[until] 是写完之后界面还要到达的状态（如重读后某行出现），同样等到为止。
Future<void> srsSettleUntilWritten(
  WidgetTester tester,
  int before, {
  List<ProviderListenable<AsyncValue<Object?>>> reloads =
      const <ProviderListenable<AsyncValue<Object?>>>[],
  bool Function()? until,
  int settleRounds = 12,
}) async {
  final ProviderContainer container = srsPageContainer(tester);
  await srsPumpUntil(
    tester,
    () => container.read(srsRevisionProvider) > before,
    what: '页面的写入落库（srsRevisionProvider 停在 $before）',
  );
  for (final ProviderListenable<AsyncValue<Object?>> p in reloads) {
    await srsPumpUntil(
      tester,
      () => !container.read(p).isLoading,
      what: '写入后重读完 $p',
    );
  }
  if (until != null) {
    await srsPumpUntil(tester, until, what: '写入后界面到达预期状态');
  }
  await _settleAfter(tester, settleRounds);
}

/// 执行触发写入的界面操作 [action]（点保存 / 确认……），再按 [srsSettleUntilWritten] 等它落库。
Future<void> srsUntilWritten(
  WidgetTester tester,
  Future<void> Function() action, {
  List<ProviderListenable<AsyncValue<Object?>>> reloads =
      const <ProviderListenable<AsyncValue<Object?>>>[],
  bool Function()? until,
  int settleRounds = 12,
}) async {
  final int before = srsPageRevision(tester);
  await action();
  await srsSettleUntilWritten(
    tester,
    before,
    reloads: reloads,
    until: until,
    settleRounds: settleRounds,
  );
}

/// 执行触发写入的界面操作 [action]，再按 [srsSettleUntilStoreWritten] 等 [store] 落库。
Future<void> srsUntilStoreWritten(
  WidgetTester tester,
  SrsDbStore store,
  Future<void> Function() action, {
  bool Function()? until,
  int settleRounds = 12,
}) async {
  final int before = store.revision;
  await action();
  await srsSettleUntilStoreWritten(
    tester,
    store,
    before,
    until: until,
    settleRounds: settleRounds,
  );
}

/// 等 [store] 上一次由界面操作发起的写命令落库：页面不发修订号的写入用（见文件头）。
///
/// [before] 是操作前 [SrsDbStore.revision] 的值；[until] 是落库之后界面还要到达的状态（如复习页换到下一张）。
Future<void> srsSettleUntilStoreWritten(
  WidgetTester tester,
  SrsDbStore store,
  int before, {
  bool Function()? until,
  int settleRounds = 12,
}) async {
  await srsPumpUntil(
    tester,
    () => store.revision > before,
    what: '写命令落库（SrsDbStore.revision 停在 $before）',
  );
  if (until != null) {
    await srsPumpUntil(tester, until, what: '落库后界面到达预期状态');
  }
  await _settleAfter(tester, settleRounds);
}
