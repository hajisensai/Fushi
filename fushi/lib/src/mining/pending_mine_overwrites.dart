/// 「卡还在后台写入 Anki 时又要覆盖它」的排队簿（BUG-3492，所有者拍板的方案 B）。
///
/// 在线视频默认后台制卡：弹窗当场只拿到「已加入」，卡要过几秒才真正进 Anki。这几秒
/// 里用户从「高级制卡」或点 ✓ 发起覆盖时，被覆盖的那张笔记**还不存在**——不能立刻
/// 覆盖，也不该让请求凭空消失。所以先排队：等后台写入落地，再对写入的那张笔记执行
/// 覆盖；写入失败就取消覆盖并说明原因。
///
/// 规则（所有者 2026-10-17 拍板）：
/// * 只有「同一个词正有一次后台写入在途」时才收下覆盖请求（[queue] 返回 false 时调用
///   方另行处理——那张卡不在这条后台路径上，排了也等不到落地）；
/// * 同一个词连续排多次**只保留最后一次**；
/// * 弹窗关掉后排队照样有效：本簿属于宿主页面，不属于弹窗。
///
/// 词的身份用 [mineEntryKeyOf]（与 popup.js `mineEntryKey` 同一口径：表记 + 读音）。
/// 不依赖 Flutter / Anki，策略由单测驱动；页面只负责接线（冻结制卡输入、跑覆盖、出 OSD）。
class PendingMineOverwrites<R> {
  final Set<String> _addsInFlight = <String>{};
  final Map<String, R> _queued = <String, R>{};

  /// 后台写入开始：从这一刻起，这个词的覆盖请求可以排队。
  void addStarted(String key) => _addsInFlight.add(key);

  /// 这个词是否有一次后台写入还没落地。
  bool isAddPending(String key) => _addsInFlight.contains(key);

  /// 排一个覆盖请求。没有在途写入时不收（返回 false）；已有排队的请求时被这一次顶掉。
  bool queue(String key, R request) {
    if (!_addsInFlight.contains(key)) return false;
    _queued[key] = request;
    return true;
  }

  /// 当前排着的请求（诊断与测试用）。
  R? queuedFor(String key) => _queued[key];

  /// 后台写入落地（成功或失败都必须调一次）：取走排队的请求并按结局处理。
  ///
  /// * 没有排队的请求：只清掉在途标记。
  /// * [landed] 为 false（写入失败）：不覆盖，[onCancelled] 报
  ///   [PendingOverwriteCancel.addFailed]。
  /// * 写入成功：目标笔记取 [noteId]；后端不回 id（AnkiDroid）时用 [findNoteId] 反查
  ///   （取最新的那张）；还是找不到就报 [PendingOverwriteCancel.noTargetNote]，否则
  ///   调 [overwrite]。
  Future<void> settle(
    String key, {
    required bool landed,
    required int? noteId,
    required Future<int?> Function(R request) findNoteId,
    required Future<void> Function(int noteId, R request) overwrite,
    required void Function(R request, PendingOverwriteCancel reason)
    onCancelled,
  }) async {
    _addsInFlight.remove(key);
    final R? request = _queued.remove(key);
    if (request == null) return;
    if (!landed) {
      onCancelled(request, PendingOverwriteCancel.addFailed);
      return;
    }
    final int? target = noteId ?? await findNoteId(request);
    if (target == null) {
      onCancelled(request, PendingOverwriteCancel.noTargetNote);
      return;
    }
    await overwrite(target, request);
  }
}

/// 排队的覆盖为什么没有执行。
enum PendingOverwriteCancel {
  /// 前一次后台写入失败了：没有可覆盖的笔记。
  addFailed,

  /// 写入报成功，但找不到它写下的那张笔记。
  noTargetNote,
}

/// 词条身份键（表记 + 读音），与 popup.js `mineEntryKey` 同一口径。
String mineEntryKeyOf(String expression, String reading) =>
    '$expression\u0000$reading';
