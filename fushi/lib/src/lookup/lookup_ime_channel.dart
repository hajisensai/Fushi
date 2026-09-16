/// 把「查词输入框期望的输入法语言」告诉原生侧。
///
/// 为什么是**页面级**而不是焦点级：iOS 的 `textInputMode` 是在输入框成为第一响应者
/// **之前**被读的（Hoshi Reader iOS 为此特意等转场动画结束才抢焦点）。焦点变化 →
/// Dart listener → method channel → 原生，这条链能不能赶在那次读取之前到位是没有保证
/// 的；查词页面则在任何输入框拿到焦点之前很久就 mount 了，时序上稳。
///
/// 代价是粒度粗：页面存续期间，这一页里**所有**输入框都会拿到这个语言提示。查词页面
/// 上除了查词框没有别的输入框，所以目前没有实际影响；将来若要细到单个输入框，得换成
/// 「焦点 + 原生侧按第一响应者身份判定」，不是把这层改细就行。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

class LookupImeChannel {
  const LookupImeChannel._();

  static const MethodChannel _channel = FushiChannels.lookupIme;

  /// 上一次真正发出去的值，避免同一页反复重建时刷 channel。
  static String? _lastSent;

  /// 谁还在要哪种语言，按登记顺序排——最后登记的赢。
  ///
  /// 不能只记「上一次发了什么」：桌面上词典主页的搜索框可能正聚焦着（已经切到日语），
  /// 这时打开再关掉弹窗词典，弹窗一句 null 就会把还活着的主页那份也还原掉。注销一个
  /// 请求者之后必须回落到仍然活跃的那个，而不是无条件还原。
  static final Map<Object, String> _requests = <Object, String>{};

  @visibleForTesting
  static void resetForTesting() {
    _lastSent = null;
    _requests.clear();
  }

  /// 以 [owner] 的名义要求某种语言；[tag] 为 null / 空串 = 撤回这个请求者的要求。
  static Future<void> request(Object owner, String? tag) async {
    // 先移除再放回：Map 按插入顺序排，这样重新表达的请求会排到末尾（最后的赢）。
    _requests.remove(owner);
    if (tag != null && tag.isNotEmpty) {
      _requests[owner] = tag;
    }
    await setLanguage(_requests.isEmpty ? null : _requests.values.last);
  }

  /// 撤回 [owner] 的请求，回落到仍然活跃的那个请求者（没有就还原）。
  static Future<void> release(Object owner) => request(owner, null);

  /// 直接设置期望语言（BCP-47；null / 空串 = 不表达偏好）。
  ///
  /// 常规路径请用 [request]/[release]——它们能处理多个查词入口交叠的情况。
  ///
  /// 没有原生实现的平台（目前 Android / Linux）会抛 [MissingPluginException]，这里
  /// 咽掉：少一次输入法提示不该让查词页面开不出来。
  static Future<void> setLanguage(String? tag) async {
    final String? normalized = (tag == null || tag.isEmpty) ? null : tag;
    if (normalized == _lastSent) return;
    _lastSent = normalized;
    try {
      await _channel.invokeMethod<void>('setLanguage', normalized);
    } on MissingPluginException {
      // 该平台还没接原生侧。
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] setLanguage failed: $error');
      _lastSent = null;
    }
  }

  /// 把用户选的语言**存**给原生查词界面用，不切换任何输入法。
  ///
  /// Android 的悬浮词典与弹窗词典搜索框是原生 EditText（不是 Flutter TextField，
  /// 吃不到 hintLocales 参数），而且它们可能在任何 Flutter 查词页面打开之前就被拉
  /// 起——所以不能等 [request]，必须在偏好变更时和启动时各存一次。
  ///
  /// 桌面/iOS 没有实现这个方法（它们靠 [request] 真的切输入法），静默跳过。
  static Future<void> persistForNativeSurfaces(String? tag) async {
    try {
      await _channel.invokeMethod<void>('persistLanguage', tag ?? '');
    } on MissingPluginException {
      // 该平台没有原生查词输入框需要这个值。
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] persistLanguage failed: $error');
    }
  }

  /// 系统里有没有这个语言的输入法可用。
  ///
  /// 拿不到原生探针时返回 true（「没有证据说不可用」）：Android 走的是
  /// `hintLocales` 提示，本来就不需要我们判断有没有装；Linux 还没接原生侧。宁可
  /// 不提示，也不要对着一个其实能用的语言报「不可用」。
  static Future<bool> isLanguageAvailable(String tag) async {
    if (tag.isEmpty) return true;
    final Map<String, Object?>? info = await probe();
    if (info == null) return true;
    final List<Object?>? enabled = info['enabledLanguages'] as List<Object?>?;
    if (enabled == null) return true;
    return enabled.any(
      (Object? candidate) =>
          candidate is String && lookupImeLanguageMatches(tag, candidate),
    );
  }

  /// 原生侧探针：`installed` / `desired` / `resolveCount` / `lastResolved` /
  /// `activeInputModes`。用来分辨「属性没被调用」与「调用了但系统没采纳返回值」——
  /// 这两种失败的修法完全不同。没有原生实现时返回 null。
  static Future<Map<String, Object?>?> probe() async {
    try {
      final Map<Object?, Object?>? raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('probe');
      if (raw == null) return null;
      return raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key?.toString() ?? '', value),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] probe failed: $error');
      return null;
    }
  }
}
