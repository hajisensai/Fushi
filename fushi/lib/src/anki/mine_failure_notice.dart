import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 回包这一刻「发起这次制卡的那个查词弹窗还在屏上」的判据（宿主自己的生命周期真值）。
///
/// * app 内 WebView 弹窗：State 仍挂载 + 同一份文档 + 这一层仍在弹窗栈里且未停驻
///   （[DictionaryPopupController.isEntryOnScreen]）。
/// * app 外覆盖窗（桌面 / gal 卡片 / 网页视频全局查词）：发起时的查词 route 仍是当前
///   route 且未作废（关窗、换词都会作废它）。
///
/// 「还是不是同一次查词」的后一半由 popup.js 自己判：发起的那颗按钮已被重渲染摘掉
/// （换词 / 原地跳转 / 热槽复用）时回 `mineFailureUnseen`，见 [MineFailureNotice.reportUnseen]。
typedef MineOriginOnScreen = bool Function();

/// 失败提示的 toast 出口。生产是 [FushiToast.showMine]；测试经
/// [MineFailureNotice.debugToastSink] 换成计数器（widget 测试里 FushiToast 没有全局
/// navigatorKey，永远进不了树，断言 toast 文案恒假/恒真）。
typedef MineFailureToastSink =
    void Function(String message, MineToastStatus status);

/// BUG-3652 续：弹窗发起的制卡失败，**恰好一次**告诉用户。
///
/// #2438 把失败原因随回包交给弹窗就地说（`MinePopupResult.failed(message:)`），宿主
/// 只在被收下时弹 toast——解决了同一次失败报两遍。但回包回来时弹窗可能已经不在了
/// （阅读器制卡排队 / AnkiConnect 慢，用户先关了弹窗、弹窗被导航销毁或换了词），
/// 那句原因就无处可说，比改动前（至少有 toast）更糟。
///
/// 这里是唯一的落点：
/// * 弹窗仍在且仍是那一次 → 回包原样交给弹窗，弹窗就地说，宿主不弹 toast；
/// * 弹窗已不在 → 宿主 toast 一次，回包去掉 `message` 并标 `hostReported`，万一那份
///   文档还活着（停驻热槽），popup.js 也不会再说第二遍；
/// * 弹窗还在但发起的按钮已被换掉 → popup.js 不画提示、回 `mineFailureUnseen`，
///   由 [reportUnseen] toast 一次。
abstract final class MineFailureNotice {
  static MineFailureToastSink _toastSink = _showToast;

  static void _showToast(String message, MineToastStatus status) =>
      FushiToast.showMine(msg: message, status: status);

  /// 测试注入点；传 null 复原生产出口。
  @visibleForTesting
  static set debugToastSink(MineFailureToastSink? sink) =>
      _toastSink = sink ?? _showToast;

  /// popup.js 回包里「宿主已经说过了，弹窗别再说」的标记。
  static const String hostReportedKey = 'hostReported';

  /// [reply] 是一次没被收下、且带着要让用户看到的原因的制卡结果吗。
  ///
  /// 被收下（`ankiConnect` 成功 / `queued` 进队列）由宿主自己的成功 toast 负责；没有
  /// `message` 的未成功结果（用户在已制卡操作单里取消、宿主没接制卡）没有要说的话。
  static bool isReportableFailure(Map<String, Object?> reply) {
    if (reply['ankiConnect'] == true || reply['queued'] == true) return false;
    if (reply[hostReportedKey] == true) return false;
    final Object? message = reply['message'];
    return message is String && message.isNotEmpty;
  }

  /// 回包交给弹窗之前调：弹窗已不在（[originOnScreen] 为假）时宿主 toast 一次，
  /// 并改写回包让 popup.js 不再重复。其余情况原样返回。
  ///
  /// 先过「制卡提示」开关（[MineNotices.shown]）：用户关掉了「重复卡片提示」时，重复
  /// 结果既不 toast、也不让弹窗就地说——回包去掉 `message` 并标 `hostReported`
  /// （= 宿主已对这条提示作出裁决，popup.js 什么都不画）。`duplicate` 位原样保留，
  /// 按钮照旧按真实状态画成已制卡 ✓。此前弹窗就地提示不经开关，关掉后「重复卡片，
  /// 未导出」照样冒出来（反馈 3aFpRYC6a1 / jYEPxVSrts）。
  static Map<String, Object?> settle(
    Map<String, Object?> reply, {
    required bool originOnScreen,
  }) {
    // 不看有没有 message：宿主没带原因时 popup.js 会退回通用的「导出卡片失败」，
    // 被关掉的重复提示一样不能让它说。
    if (_isMutedDuplicate(reply)) return _withoutMessage(reply);
    if (originOnScreen || !isReportableFailure(reply)) return reply;
    _toast(reply['message']! as String, duplicate: reply['duplicate'] == true);
    return _withoutMessage(reply);
  }

  /// 没被收下、因为卡已在 Anki 里、且用户关了「重复卡片提示」。失败（非重复）恒说。
  static bool _isMutedDuplicate(Map<String, Object?> reply) =>
      reply['ankiConnect'] != true &&
      reply['queued'] != true &&
      reply['duplicate'] == true &&
      !MineNotices.shown(MineToastStatus.duplicate);

  static Map<String, Object?> _withoutMessage(Map<String, Object?> reply) =>
      <String, Object?>{
        for (final MapEntry<String, Object?> e in reply.entries)
          if (e.key != 'message') e.key: e.value,
        hostReportedKey: true,
      };

  static MineToastStatus _statusOf(bool duplicate) =>
      duplicate ? MineToastStatus.duplicate : MineToastStatus.failed;

  /// popup.js `mineFailureUnseen` 桥：弹窗收到失败回包时，发起制卡的那颗按钮已经
  /// 不在页面上（换词 / 原地跳转 / 热槽复用重渲染），提示无处可画，交回宿主 toast。
  /// [args] 是 JS 传来的 `{message, duplicate}`；缺字段 / 形状不对时什么都不做。
  static void reportUnseen(Object? args) {
    if (args is! Map) return;
    final Object? message = args['message'];
    if (message is! String || message.isEmpty) return;
    _toast(message, duplicate: args['duplicate'] == true);
  }

  /// 同样先过开关：测试替换的 [_toastSink] 也只收到用户真会看见的提示。
  static void _toast(String message, {required bool duplicate}) {
    final MineToastStatus status = _statusOf(duplicate);
    if (!MineNotices.shown(status)) return;
    _toastSink(message, status);
  }
}
