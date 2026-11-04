/// 网页桥 Apple ID 登录的纯逻辑：弹窗回传通道补齐、失败原因判定、登录轨迹（诊断日志）。
///
/// 回传通道（反馈 FK0EFFDLIS，2026-11-04 HiBreak 真机取证）：MusicKit JS 的 `authorize()` 开
/// `authorize.music.apple.com` 弹窗，弹窗页只在 sessionStorage 有 `ac`（opener 的 URL，取自
/// `document.referrer`）时才对 `window.opener` 建 JSON-RPC 通道（`authorize` / `close` /
/// `decline` …）。Android WebView 的多窗口（`window.open` → 新 WebView）不带 referrer，托管页
/// 先前又是 `Referrer-Policy: no-referrer`，`ac` 恒空：Apple 账号登录完，token 只存进弹窗自己的
/// sessionStorage，弹窗随即关窗，MusicKit 只看到「窗关了」→ `AUTHORIZATION_ERROR: Unauthorized`，
/// 有订阅的账号也拿不到 token。浏览器里这个值本来就由 referrer 给出，这里在弹窗进入 Apple 授权页
/// 时补上真实的 opener 地址（托管页），只补不改。
///
/// 无订阅：Apple 授权页对 `isAppleMusicSubscriber=false` / `ERROR_NO_DSID` 的账号走 `/upsell`，
/// 「以后再说」只发 `close`、「立即体验」发 `unavailable` 后外开订阅页，都不发 token——网页版
/// MusicKit 不给无订阅账号授权，这是 Apple 侧行为；我们据弹窗走过的路径给出明确原因。
library;

/// Apple 授权弹窗的主机。
const String kAppleMusicAuthorizeHost = 'authorize.music.apple.com';

/// 弹窗页在 Apple 授权页上补 `ac`（opener 地址）的脚本；[bridgePage] 是托管页地址。
///
/// 只在 [kAppleMusicAuthorizeHost] 上、且 `ac` 缺失时写入，不覆盖页面自己从 referrer 拿到的值。
String appleMusicPopupOpenerSeedJs(Uri bridgePage) {
  final String value = bridgePage.toString().replaceAll("'", r"\'");
  return '''
(() => {
  try {
    if (location.hostname !== '$kAppleMusicAuthorizeHost') return 'skip';
    if (sessionStorage.getItem('ac')) return 'present';
    sessionStorage.setItem('ac', '$value');
    return 'seeded';
  } catch (e) {
    return 'error';
  }
})()
''';
}

/// 弹窗走过的 Apple 授权页暗示的失败原因。
enum AppleMusicLoginBlocker {
  /// 账号没有 Apple Music 订阅（`/upsell`、`/error/no-subscription`）。
  noSubscription,

  /// 账号所在地区不支持（`/error/unsupported-country`）。
  unsupportedCountry,

  /// Apple 判定当前设备 / 浏览器不支持（`/error/unsupported-device`）。
  unsupportedDevice,
}

/// 一个弹窗地址对应的 [AppleMusicLoginBlocker]；不是 Apple 授权页的结论页返回 null。
AppleMusicLoginBlocker? appleMusicLoginBlockerOf(Uri url) {
  if (url.host != kAppleMusicAuthorizeHost) return null;
  return switch (url.path) {
    '/upsell' ||
    '/error/no-subscription' => AppleMusicLoginBlocker.noSubscription,
    '/error/unsupported-country' => AppleMusicLoginBlocker.unsupportedCountry,
    '/error/unsupported-device' => AppleMusicLoginBlocker.unsupportedDevice,
    _ => null,
  };
}

/// 一次登录尝试的轨迹：弹窗经过的页面（只记主机 + 路径，不记 query——里面有 token）、
/// 回传通道补齐结果、弹窗由谁关闭。失败时整段写进诊断日志，下次反馈直接看得到卡在哪一步。
class AppleMusicLoginTrace {
  final List<String> _steps = <String>[];
  AppleMusicLoginBlocker? _blocker;

  /// 弹窗走过的 Apple 结论页（[appleMusicLoginBlockerOf]）里最后一个。
  AppleMusicLoginBlocker? get blocker => _blocker;

  /// 已记录的步骤（测试 / 日志用）。
  List<String> get steps => List<String>.unmodifiable(_steps);

  void _add(String step) {
    if (_steps.isNotEmpty && _steps.last == step) return;
    _steps.add(step);
  }

  /// 弹窗加载完一个页面。
  void popupPage(Uri url) {
    _add('page ${url.host}${url.path}');
    final AppleMusicLoginBlocker? b = appleMusicLoginBlockerOf(url);
    if (b != null) _blocker = b;
  }

  /// 补 `ac` 脚本的返回（`seeded` / `present` / `skip` / `error`）。
  void openerSeed(Object? result) {
    if (result == 'seeded' || result == 'error') _add('opener $result');
  }

  /// 弹窗被页面自己关掉（`window.close()`）。
  void popupClosed() => _add('popup closed');

  /// 弹窗想再开一个窗口（如订阅页），交给系统浏览器。
  void externalOpen(Uri url) => _add('external ${url.host}${url.path}');

  /// 一行文本，写进诊断日志。
  String describe(String result) =>
      '$result; ${_steps.isEmpty ? 'no popup' : _steps.join(' → ')}';
}
