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
/// 同一个词可以同时有**多次**后台写入在途（两个弹窗各点了一次「+」）。每次写入由
/// [addStarted] 发一个代号；排队的覆盖绑定在**排队那一刻最新的那次写入**上（用户眼前
/// 「已加入」的就是它），只由那次写入的落地结算——先落地的另一次写入既不会把在途标记
/// 清掉，也不会把覆盖错套到别的笔记上。
///
/// 词的身份用 [mineEntryKeyOf]（与 popup.js `mineEntryKey` 同一口径：表记 + 读音）。
/// 不依赖 Flutter / Anki，策略由单测驱动；页面只负责接线（冻结制卡输入、跑覆盖、出 OSD）。
class PendingMineOverwrites<R> {
  int _nextAddId = 0;
  final Map<String, List<int>> _addsInFlight = <String, List<int>>{};
  final Map<String, ({int addId, R request})> _queued =
      <String, ({int addId, R request})>{};
  final Map<String, bool> _lastLanded = <String, bool>{};

  /// 后台写入开始：从这一刻起，这个词的覆盖请求可以排队。返回这次写入的代号，
  /// 落地时原样交给 [settle]。
  int addStarted(String key) {
    final int addId = ++_nextAddId;
    (_addsInFlight[key] ??= <int>[]).add(addId);
    _lastLanded.remove(key);
    return addId;
  }

  /// 这个词是否有后台写入还没落地。
  bool isAddPending(String key) => _addsInFlight[key]?.isNotEmpty ?? false;

  /// 这个词最近一次后台写入（已全部落地之后）的结局：true = 写进了 Anki，false =
  /// 失败；没走过后台写入、或还有写入在途时为 null。
  bool? lastLanded(String key) => isAddPending(key) ? null : _lastLanded[key];

  /// 排一个覆盖请求，绑定到这个词当前最新的那次在途写入。没有在途写入时不收（返回
  /// false）；已有排队的请求时被这一次顶掉。
  bool queue(String key, R request) {
    final List<int>? adds = _addsInFlight[key];
    if (adds == null || adds.isEmpty) return false;
    _queued[key] = (addId: adds.last, request: request);
    return true;
  }

  /// 当前排着的请求（诊断与测试用）。
  R? queuedFor(String key) => _queued[key]?.request;

  /// 代号为 [addId] 的后台写入落地（成功或失败都必须调一次）。排队的覆盖若绑定在这次
  /// 写入上，就取走并按结局处理；绑在别的在途写入上的不动。
  ///
  /// * 没有绑在这次写入上的请求：只清掉这次写入的在途标记。
  /// * [landed] 为 false（写入失败）：不覆盖，[onCancelled] 报
  ///   [PendingOverwriteCancel.addFailed]。
  /// * 写入成功：目标笔记取 [noteId]；后端不回 id（AnkiDroid）时用 [findNoteId] 反查
  ///   （取最新的那张）；还是找不到就报 [PendingOverwriteCancel.noTargetNote]，否则
  ///   调 [overwrite]。
  Future<void> settle(
    String key,
    int addId, {
    required bool landed,
    required int? noteId,
    required Future<int?> Function(R request) findNoteId,
    required Future<void> Function(int noteId, R request) overwrite,
    required void Function(R request, PendingOverwriteCancel reason)
    onCancelled,
  }) async {
    final List<int>? adds = _addsInFlight[key];
    if (adds == null || !adds.remove(addId)) return;
    if (adds.isEmpty) {
      _addsInFlight.remove(key);
      _lastLanded[key] = landed;
    }
    final ({int addId, R request})? queued = _queued[key];
    if (queued == null || queued.addId != addId) return;
    _queued.remove(key);
    final R request = queued.request;
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
