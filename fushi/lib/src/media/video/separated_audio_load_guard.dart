/// YouTube 分离流（video-only 主流 + audio-only 外挂音轨）的载入在途记账与音轨被拒回退
/// （反馈 s3sOy3sD1J 的页面侧收尾）。
///
/// 页面上会挂分离音轨的载入有三种来源：远端起播 / 换集、画质切档、音轨被拒后的 muxed
/// 回退。它们会**重叠**：起播在途时用户换集、回退重载在途时用户换集或切档。旧实现用一个
/// 共享 bool 表示「有载入在途」，先开始的那程在 `finally` 里把它清掉时，后开始的那程其实
/// 还没结束——在途门失效，控制器的音轨失败回调就会在后一程 `_applyLoad` 半途再起一程
/// 回退；回退本身 await 完也不看集序号，换集后照样给新集弹「已换成兼容流」。
///
/// 这里把两件事收成可单测的纯逻辑：
/// - **在途所有权按令牌**：每程载入领一个令牌，只有最新那程结束才清在途；旧程迟到的
///   结束不影响新程。
/// - **回退按集序号作废**：回退开始时记下当时的集序号，await 前后都校验「页面还活着且集
///   序号没变」，过期就静默放弃（不弹 OSD、不改状态）。
///
/// 另记「本集分离音轨已被拒」：被拒之后再切到别的分离画质档只会把同一条被拒的音频流
/// 再挂一次、再回退一次，所以页面据 [separatedAudioRefused] 禁用分离画质档并说明原因。
/// 被拒按集序号记，换集（集序号前进）自动失效。
class SeparatedAudioLoadGuard {
  SeparatedAudioLoadGuard({
    required int Function() currentEpisodeSeq,
    required bool Function() isAlive,
  }) : _currentEpisodeSeq = currentEpisodeSeq,
       _isAlive = isAlive;

  final int Function() _currentEpisodeSeq;
  final bool Function() _isAlive;

  int _lastLoadToken = 0;
  int? _activeLoadToken;
  int? _refusedEpisodeSeq;

  /// 有一程会挂分离音轨的载入在途（以最新开始的那程为准）。在途期间控制器报的音轨失败
  /// 只记账，等这程收尾再处理（[recover]）。
  bool get loadInFlight => _activeLoadToken != null;

  /// 当前这一集的分离音轨已被拒过。
  bool get separatedAudioRefused =>
      _refusedEpisodeSeq != null && _refusedEpisodeSeq == _currentEpisodeSeq();

  /// 跑一程会挂分离音轨的载入。期间 [loadInFlight] 为真；结束时只有自己仍是最新那程
  /// 才清在途。
  Future<T> runLoad<T>(Future<T> Function() load) async {
    final int token = ++_lastLoadToken;
    _activeLoadToken = token;
    try {
      return await load();
    } finally {
      if (_activeLoadToken == token) _activeLoadToken = null;
    }
  }

  /// [seq] 是否仍是当前集且页面还活着。
  bool isCurrent(int seq) => _isAlive() && seq == _currentEpisodeSeq();

  /// 分离音轨被拒后的收尾：有 muxed 回退流就原位换过去，没有就提示无声。
  ///
  /// 只在没有载入在途、且控制器确实记了本次 load 的音轨失败（[externalAudioFailed]）时
  /// 动作；动作即记本集「已被拒」。回退重载 await 完若已换集 / 页面已销毁，静默放弃。
  /// 返回实际采取的处理。
  Future<SeparatedAudioRecovery> recover({
    required bool Function() externalAudioFailed,
    required String? fallbackUrl,
    required Future<void> Function(String fallbackUrl) reloadWithFallback,
    required void Function() onNoFallback,
    required void Function() onFellBack,
  }) async {
    final int seq = _currentEpisodeSeq();
    if (!isCurrent(seq) || loadInFlight) return SeparatedAudioRecovery.none;
    if (!externalAudioFailed()) return SeparatedAudioRecovery.none;
    _refusedEpisodeSeq = seq;
    if (fallbackUrl == null) {
      onNoFallback();
      return SeparatedAudioRecovery.promptedNoAudio;
    }
    await runLoad<void>(() => reloadWithFallback(fallbackUrl));
    if (!isCurrent(seq)) return SeparatedAudioRecovery.stale;
    onFellBack();
    return SeparatedAudioRecovery.fellBack;
  }
}

/// [SeparatedAudioLoadGuard.recover] 实际采取的处理。
enum SeparatedAudioRecovery {
  /// 没动作：有载入在途 / 音轨没失败 / 已换集或页面已销毁。
  none,

  /// 无可回退流，已提示无声。
  promptedNoAudio,

  /// 已换到自带音轨的 muxed 流并提示。
  fellBack,

  /// 回退重载期间换集 / 页面销毁，结果作废（不提示）。
  stale,
}
