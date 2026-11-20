/// 旧版本保留副本（迁移后原位封存的协议 3 `srs.db`）与彻底清除字节层收尾的 app 侧入口（D32；规划 §6 K2 合并条件）：
///
/// - 设置 › 存储「删除旧版本保留副本」（`settings_schema_storage.dart`）：显示大小与到期时刻，确认后立即删；
/// - 牌组彻底清除（`srs_deck_list_page.dart`）：选项说明写明保留副本里仍有原文，并给「同时立即删除」；
/// - 同步与历史页、牌组列表：`scrub_state` 报收尾出错时提示「清除的内容在磁盘上还没抹干净：<原因>」。
///
/// 到期规则与删除的核对全在内核（`native/fushi_fsrs/src/store/gen4/retained.rs`）；ctl / 服务端 admin 走同一个执行端
/// （engine `srs_ctl_routes.dart` 的 `/api/admin/srs/retained*`）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsCoreException,
        SrsNativeRetainedCopyBackend,
        SrsRetainedCopyBackend,
        SrsRetainedCopyDeletion,
        SrsRetainedCopyState;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart'
    show srsSyncRoundsSucceeded;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 保留副本命令的执行端（测试覆写成假的）。
final Provider<SrsRetainedCopyBackend> srsRetainedCopyBackendProvider =
    Provider<SrsRetainedCopyBackend>(
      (Ref ref) => const SrsNativeRetainedCopyBackend(),
    );

/// 复习库所在目录（保留副本命令按它）；主库还没开好 = null。
String? srsLibraryDirOf(AppModel app) =>
    app.isDatabaseOpen ? app.srsStorage.directory : null;

/// 本机的保留副本：所在库目录 + 状态。
typedef SrsRetainedCopyInfo = ({String dir, SrsRetainedCopyState state});

/// 当前的保留副本（设置行、牌组彻底清除共用）：状态命令在后台 isolate 跑（内核要打开两个 SQLite 文件）。主库没开好
/// = null；读不了（新代库坏了等，内核报错）记日志、按没有处理——它只决定提示文字和入口显不显示，不能让删牌组 / 设置页
/// 跟着用不了（删除本身同样会被内核拒绝）。
///
/// 只在会改变它的事件之后重读，不跟复习库的修订号（每次评分 / 编辑 / 同步拉入都跳一次，跟着它就每跳都起一个后台
/// isolate 打开两个库文件，而结果几乎从不变）。会改变它的只有：
/// - 复习库换了（迁移完成、换 profile、到期自动删都发生在开库时）：watch [srsStoreProvider]；
/// - 删除：删的调用方 invalidate；
/// - 第一次同步成功（到期时刻从「迁移 + 30 天」改成「首次同步 + 14 天」）：副本在、还没记下首次同步时听
///   [srsSyncRoundsSucceeded]（只按这一次读到的状态决定），下一轮成功的同步之后重读一次（设置页开着时日期跟着变）；记下了之后再成功也不重读。没人看时
///   自动释放，下次进设置页现读。
/// 读的过程中 [Ref.keepAlive] 撑住：删牌组那条路是 `read(.future)`，没有监听者也要等它读完。
///
/// 监听在 provider 体的**同步开头**挂上、同一处登记 `onDispose` 摘掉，两者成对、都在第一个 `await` 之前：读的过程中
/// 被 invalidate（换库、删除的调用方）时这一次构建的 dispose 照样把它摘掉。读完才决定要不要重读（`awaitingFirstSync`），
/// 不在读完之后再挂——那时这次构建可能已经被废弃，`onDispose` 会抛、监听就永远摘不掉，之后每一轮成功的同步都让元素
/// 重读一次（第六波第二轮复核）。
final AutoDisposeFutureProvider<SrsRetainedCopyInfo?> srsRetainedCopyProvider =
    FutureProvider.autoDispose<SrsRetainedCopyInfo?>((
      AutoDisposeFutureProviderRef<SrsRetainedCopyInfo?> ref,
    ) async {
      final KeepAliveLink loading = ref.keepAlive();
      bool awaitingFirstSync = false;
      void onRoundSucceeded() {
        if (awaitingFirstSync) ref.invalidateSelf();
      }

      srsSyncRoundsSucceeded.addListener(onRoundSucceeded);
      ref.onDispose(
        () => srsSyncRoundsSucceeded.removeListener(onRoundSucceeded),
      );
      try {
        final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
        if (store == null) return null;
        final String? dir = srsLibraryDirOf(ref.read(appProvider));
        if (dir == null) return null;
        try {
          final SrsRetainedCopyState state = await ref
              .read(srsRetainedCopyBackendProvider)
              .state(dir, nowMs: DateTime.now().millisecondsSinceEpoch);
          // 副本在、新代还没同步成功过：到期时刻会在第一次同步成功时从「迁移 + 30 天」改成「首次同步 + 14 天」。
          // 开着设置页时等下一轮成功的同步重读一次（重读之后记下了首次同步就不再听）。
          awaitingFirstSync = state.present && state.firstSyncAtMs == null;
          return (dir: dir, state: state);
        } on SrsCoreException catch (e, stack) {
          ErrorLogService.instance.log('srs.retained_copy.state', e, stack);
          return null;
        }
      } finally {
        loading.close();
      }
    });

/// 设置行的副标题：大小 + 到期时刻（或「删除前一直保留」）；上一次自动删没做成时换成原因。
String srsRetainedCopyStatusText(BuildContext context, SrsRetainedCopyState s) {
  final String size = FushiByteFormat.bytes(s.bytes);
  final String? error = s.error;
  if (error != null) {
    return t.srs_retained_copy_status_error(size: size, error: error);
  }
  final int? due = s.dueAtMs;
  if (due == null) return t.srs_retained_copy_status_kept(size: size);
  return t.srs_retained_copy_status_due(
    size: size,
    date: MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.fromMillisecondsSinceEpoch(due)),
  );
}

/// 删除并报结果（toast）：删成了 = true。核对不过（内核报错）原样报给用户，什么都没动。
Future<bool> deleteSrsRetainedCopy(
  SrsRetainedCopyBackend backend,
  String dir,
) async {
  final SrsRetainedCopyDeletion d;
  try {
    d = await backend.delete(dir);
  } on SrsCoreException catch (e) {
    FushiToast.show(
      msg: t.srs_retained_copy_failed(error: e.message),
      severity: ToastSeverity.error,
    );
    return false;
  }
  if (d.deleted) {
    FushiToast.show(
      msg: t.srs_retained_copy_deleted(
        size: FushiByteFormat.bytes(d.freedBytes),
      ),
      severity: ToastSeverity.success,
    );
    return true;
  }
  FushiToast.show(
    msg: d.reason == 'migrating'
        ? t.srs_retained_copy_busy
        : t.srs_retained_copy_absent,
    severity: ToastSeverity.warning,
  );
  return false;
}

/// 设置里的入口：确认（不可撤销，说明后果）→ 删 → 重读 [srsRetainedCopyProvider]。没有保留副本 / 主库没开好 =
/// 提示没有，什么都不做。
Future<void> confirmAndDeleteSrsRetainedCopy(BuildContext context) async {
  // 容器先取出来：确认框开着时设置页可能被关掉，之后不能再碰 context 上的 ref。
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final SrsRetainedCopyInfo? info = await container.read(
    srsRetainedCopyProvider.future,
  );
  if (!context.mounted) return;
  if (info == null || !info.state.present) {
    FushiToast.show(
      msg: t.srs_retained_copy_absent,
      severity: ToastSeverity.warning,
    );
    return;
  }
  final SrsRetainedCopyState s = info.state;
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.srs_retained_copy_title,
    message: t.srs_retained_copy_confirm_body(
      size: FushiByteFormat.bytes(s.bytes),
    ),
    confirmLabel: t.srs_retained_copy_confirm_action,
    icon: FushiIcons.delete,
    destructive: true,
  );
  if (!ok) return;
  await deleteSrsRetainedCopy(
    container.read(srsRetainedCopyBackendProvider),
    info.dir,
  );
  container.invalidate(srsRetainedCopyProvider);
}

/// 彻底清除字节层收尾的状态（内核 `scrub_state`）：随复习库的修订号重读；库没就绪 = null。
final FutureProvider<SrsScrubState?> srsScrubStateProvider =
    FutureProvider<SrsScrubState?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      return store.scrubState();
    });

/// 收尾出错的原因（[srsScrubStateProvider] 的 `error`）；没出错 / 还没读到 = null。
final Provider<String?> srsScrubErrorProvider = Provider<String?>(
  (Ref ref) => ref.watch(srsScrubStateProvider).valueOrNull?.error,
);

/// 收尾出错时的提示：「清除的内容在磁盘上还没抹干净：<原因>」。没出错时零高度。出现 / 消失时高度与淡入淡出一起做。
///
/// [gapBelow]：放进带间距的列表（牌组列表横幅是 `ListView.separated`）时由提示**自己**带下方间距、列表在它后面不再
/// 插间距——零高度的一项照样占一条间距，会把下面的内容整体往下推一截（第六波 ①）；间距放进提示里，就随提示一起
/// 展开 / 收起。不带间距的列表（同步与历史页）用默认 0。
class SrsScrubErrorNotice extends ConsumerWidget {
  const SrsScrubErrorNotice({super.key, this.gapBelow = 0});

  final double gapBelow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? error = ref.watch(srsScrubErrorProvider);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    return FushiAnimatedSize(
      duration: duration,
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        child: error == null
            ? const SizedBox(
                key: ValueKey<String>('srs-scrub-ok'),
                width: double.infinity,
              )
            : Padding(
                key: const ValueKey<String>('srs-scrub-error'),
                padding: EdgeInsets.only(bottom: gapBelow),
                child: FushiInlineNotice(
                  severity: FushiNoticeSeverity.warning,
                  message: t.srs_scrub_error_notice(reason: error),
                ),
              ),
      ),
    );
  }
}

/// 牌组删除对话框里「彻底清除」选项的说明：本机有保留副本时写明它里面仍有升级前的原文、怎么删（规划 §6 K2 ①）；
/// 会不会自动到期分开说（这一版之前的开发构建迁出来的库没有到期时刻，只能手动删）。
String srsPurgeOptionHint(SrsRetainedCopyState? s) {
  if (s == null || !s.present) return t.srs_deck_delete_purge_hint;
  return s.dueAtMs == null
      ? t.srs_deck_delete_purge_retained_kept_hint
      : t.srs_deck_delete_purge_retained_hint;
}

/// 彻底清除时保留副本的去向（牌组列表的彻底清除选项之后问）。
enum SrsPurgeRetainedChoice { keep, deleteNow }

/// 彻底清除之前：本机有保留副本时说明它里面仍有原文，让用户选「只清除」或「同时立即删除保留副本」。没有保留副本
/// （或没有库目录）= 直接 [SrsPurgeRetainedChoice.keep]；用户取消 = null（整次删除不做）。
Future<SrsPurgeRetainedChoice?> askSrsPurgeRetainedCopy(
  BuildContext context,
  SrsRetainedCopyState? s,
) async {
  if (s == null || !s.present) return SrsPurgeRetainedChoice.keep;
  return showFushiChoiceDialog<SrsPurgeRetainedChoice>(
    context: context,
    title: t.srs_deck_delete_purge_retained_title,
    message: t.srs_deck_delete_purge_retained_body(
      size: FushiByteFormat.bytes(s.bytes),
    ),
    icon: FushiIcons.delete,
    options: <FushiChoiceOption<SrsPurgeRetainedChoice>>[
      FushiChoiceOption<SrsPurgeRetainedChoice>(
        value: SrsPurgeRetainedChoice.keep,
        label: t.srs_deck_delete_purge_retained_keep,
        subtitle: s.dueAtMs == null
            ? t.srs_deck_delete_purge_retained_keep_kept_hint
            : t.srs_deck_delete_purge_retained_keep_hint,
        icon: FushiIcons.delete,
      ),
      FushiChoiceOption<SrsPurgeRetainedChoice>(
        value: SrsPurgeRetainedChoice.deleteNow,
        label: t.srs_deck_delete_purge_retained_delete,
        subtitle: t.srs_deck_delete_purge_retained_delete_hint,
        icon: FushiIcons.deleteSweep,
      ),
    ],
  );
}

/// [askSrsPurgeRetainedCopy] 选了立即删除：清除做完后调。删成了 = true（调用方重读 [srsRetainedCopyProvider]）。
Future<bool> settleSrsPurgeRetainedCopy(
  SrsPurgeRetainedChoice choice,
  SrsRetainedCopyBackend backend,
  String? dir,
) async {
  if (choice != SrsPurgeRetainedChoice.deleteNow || dir == null) return false;
  return deleteSrsRetainedCopy(backend, dir);
}
