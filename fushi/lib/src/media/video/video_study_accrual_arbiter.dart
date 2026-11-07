import 'dart:async';

/// 视频学习时长的跨面去重：同一时刻只让**一个**视频面入账时长（2026-11-07）。
///
/// 视频有两类写入面，各持一只墙钟 `StudyClock`：
///  * **app 内**：本地视频页 / 网页档视频页（经 `StudyClockRunGate` 起停）；
///  * **浏览器**：浏览器扩展的播放样本桥（`BrowserVideoStudyBridge`）。
///
/// 两边同时在播（app 里开着视频、又在浏览器里看）时各计一份，同一段墙钟进账两次。
/// 这里是**唯一**裁决点，两边都不写自己的判断：
///
///  * 本 app 持有焦点（主窗没报失焦；桌面查词窗不抢焦点）且 app 内视频在计时 →
///    app 内入账，浏览器不入账；
///  * 否则浏览器桥有会话（扩展在发样本）→ 浏览器入账，app 内（失焦仍在播放）不入账——
///    app 失焦时前台就是浏览器；
///  * 只有一边想计 → 那一边入账。
///
/// 只裁决**时长**：被压下的一边时钟照跑（`StudyClock.isActive` 读 [VideoStudyAccrualClaim.timeAllowed]，
/// 被拒的窗口整窗丢弃），字幕字数照常各自计（两边字幕内容不同）。裁决翻转前先让翻转方
/// [VideoStudyAccrualClaim] 的 `settle` 按**旧**结论结算到此刻（`StudyClock.flushNow`），
/// 翻转时刻之前的时间不会被整窗误判。
class VideoStudyAccrualArbiter {
  VideoStudyAccrualArbiter();

  /// 进程级唯一实例（app 内页面与 `AppModel` 持有的浏览器桥共用）。
  static final VideoStudyAccrualArbiter instance = VideoStudyAccrualArbiter();

  final Set<VideoStudyAccrualClaim> _claims = <VideoStudyAccrualClaim>{};

  /// 登记一个写入面。[settle] 把该面时钟按当前结论结算到此刻（一般是
  /// `clock.flushNow()`）；时钟还没建可传空操作。
  VideoStudyAccrualClaim claim({
    required VideoStudySurface surface,
    required FutureOr<void> Function() settle,
  }) {
    final VideoStudyAccrualClaim claim = VideoStudyAccrualClaim._(
      this,
      surface,
      settle,
    );
    _claims.add(claim);
    return claim;
  }

  void _release(VideoStudyAccrualClaim claim) {
    if (!_claims.remove(claim)) return;
    _recompute();
  }

  void _recompute() {
    bool inAppForeground = false;
    bool browserWanted = false;
    for (final VideoStudyAccrualClaim c in _claims) {
      if (!c._wanted) continue;
      switch (c.surface) {
        case VideoStudySurface.inApp:
          if (c._foreground) inAppForeground = true;
        case VideoStudySurface.browser:
          browserWanted = true;
      }
    }
    for (final VideoStudyAccrualClaim c in _claims.toList()) {
      final bool allowed = videoStudyTimeAllowed(
        surface: c.surface,
        inAppForeground: inAppForeground,
        browserWanted: browserWanted,
      );
      if (allowed == c._timeAllowed) continue;
      // 先按旧结论把「上一次 tick → 此刻」结算掉，再翻。
      unawaited(Future<void>.sync(c._settle));
      c._timeAllowed = allowed;
    }
  }
}

/// 视频写入面的种类。
enum VideoStudySurface {
  /// 本地视频页 / 网页档视频页。
  inApp,

  /// 浏览器扩展样本桥。
  browser,
}

/// [VideoStudyAccrualArbiter] 的纯判据：[surface] 此刻能否入账时长。
///
/// [inAppForeground] = 有 app 内视频面在计时且本 app 持有焦点；[browserWanted] = 浏览器
/// 桥有会话在计时。
bool videoStudyTimeAllowed({
  required VideoStudySurface surface,
  required bool inAppForeground,
  required bool browserWanted,
}) {
  switch (surface) {
    case VideoStudySurface.inApp:
      return inAppForeground || !browserWanted;
    case VideoStudySurface.browser:
      return !inAppForeground;
  }
}

/// 一个视频写入面在仲裁里的登记。
class VideoStudyAccrualClaim {
  VideoStudyAccrualClaim._(this._arbiter, this.surface, this._settle);

  final VideoStudyAccrualArbiter _arbiter;
  final VideoStudySurface surface;
  final FutureOr<void> Function() _settle;
  bool _wanted = false;
  bool _foreground = false;
  bool _timeAllowed = true;
  bool _released = false;

  /// 本面此刻能否入账时长（喂 `StudyClock.isActive`）。
  bool get timeAllowed => _timeAllowed;

  /// 报到：[running] = 本面时钟此刻在跑；[foreground] = 本 app 持有焦点（浏览器面恒
  /// false）。
  void update({required bool running, bool foreground = false}) {
    if (_released) return;
    if (_wanted == running && _foreground == foreground) return;
    _wanted = running;
    _foreground = foreground;
    _arbiter._recompute();
  }

  /// 本面离场（页面 dispose / 桥会话结束）。可重复调用。
  void release() {
    if (_released) return;
    _released = true;
    _wanted = false;
    _arbiter._release(this);
  }
}
