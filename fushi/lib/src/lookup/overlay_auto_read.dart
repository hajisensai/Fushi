// BUG-1210 — app 外两个 WebView2 表面（瞬态查词覆盖窗 / 常驻剪贴板面板）共用的
// 「查词后自动朗读」权威实现，从 GlobalLookupController 原样提出。
//
// 与 overlay_bridge_handlers.dart 同一条红线：两个表面的行为不得漂开，故收口成
// 一份共享实现，绝不复制。此前自动朗读**只在瞬态覆盖窗上接了线**，剪贴板面板
// （galgame / 复制文本流的主力表面）整条路径没有任何朗读调用——同一个全局开关
// `autoReadOnLookup` 在一个表面生效、另一个表面完全无效，用户表现为「查词不读，
// 必须手动点 ♪」。

import 'dart:async';

import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/global_lookup_render.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart';
import 'package:fushi/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 表面注入的「整栈渲染通道」：把脚本送进该表面的 WebView2。
typedef OverlayScriptRunner = Future<void> Function(String script);

/// 表面注入的「WebView 是否已就绪」门控。
typedef OverlayReadinessProbe = Future<bool> Function();

/// app 外表面的自动朗读控制器。每个表面持有**自己的**实例（token 与 pending 表
/// 各自独立，两个窗口的播放回报不会串），但走同一份逻辑。
class OverlayAutoRead {
  OverlayAutoRead({
    required OverlayScriptRunner render,
    required OverlayReadinessProbe isWebViewReady,
    required String label,
  })  : _render = render,
        _isWebViewReady = isWebViewReady,
        _label = label;

  final OverlayScriptRunner _render;
  final OverlayReadinessProbe _isWebViewReady;

  /// 日志前缀（`overlay` / `panel`），让两个表面的 autoread 记录能分辨来源。
  final String _label;

  /// popup.js 侧 `audio.play()` 结果最长等待（与 in-app
  /// DictionaryPopupWebView._kWordAudioPlayReportTimeout 同值同语义）。
  static const Duration _kWordAudioPlayReportTimeout = Duration(seconds: 5);

  int _wordAudioPlayToken = 0;
  final Map<int, Completer<bool>> _pendingWordAudioPlays =
      <int, Completer<bool>>{};

  /// 查到词后按用户「自动朗读」(autoReadOnLookup) 偏好自动发音。
  /// 复用主 Dart 查词链路同一去重协调器 (LookupAutoReadCoordinator)，播放走与
  /// in-app 相同的统一契约 autoReadWordUnified（BUG-1127）：优先驱动表面自己的
  /// HTML5 `<audio>` 快路径（与手动 ♪ 同一 popup.js playWordAudio，桌面不再每播
  /// 一次 libmpv stop→load→play），播放结果经 wordAudioPlayed 桥真实回报，失败/
  /// 超时回落 Dart 播放器（受 BUG-1015 惰性预热保护，BUG-1690 后预热在首次
  /// 真实播放前的激活队列里就地执行），绝不静默丢发音。
  void autoReadFirstEntry(AppModel model, DictionarySearchResult result) {
    if (!ReaderFushiSource.instance.autoReadOnLookup) {
      return;
    }
    if (result.entries.isEmpty) {
      return;
    }
    final DictionaryEntry entry = result.entries.first;
    final String expression = entry.word;
    final String reading = entry.reading;
    if (expression.isEmpty) {
      return;
    }
    unawaited(LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playWordAudio(model, expression, reading),
    ));
  }

  /// 与 in-app _playAutoReadWord 同构：解析一次 ref，WebView 快路径优先、Dart
  /// 播放器兜底（autoReadWordUnified 单一真相）。返回是否真的出声，供协调器在
  /// 静默失败时释放 800ms 去重窗（BUG-1127）。
  Future<bool> _playWordAudio(
          AppModel model, String expression, String reading) =>
      autoReadWordUnified(
        model,
        expression,
        reading,
        playInWebView: playWordAudioUrl,
      );

  /// BUG-1127 — 在表面常驻 ROOT iframe 的 popup.js realm 里播放已解析的 URL，
  /// 回报 `audio.play()` 的真实结果（token + Completer + 5s 超时，镜像 in-app
  /// DictionaryPopupWebView.playWordAudioUrl 的 BUG-1093 契约）。目标固定为
  /// 稳定 root 帧（TODO-1095 常驻复用、启动即预热）：音频与 realm 无关，任何
  /// 已加载 realm 都能播，root 恒暖故无冷 iframe 等待。false = WebView 没播成
  /// （未就绪/JS 缺失/autoplay 拒绝/超时），调用方回落 Dart 播放器。
  ///
  /// 发送前用 isWebViewReady 门控：native 的 render 通道在 surface 未就绪时按
  /// last-wins 缓存脚本，直接盲发会把挂起中的整栈渲染脚本顶掉（卡片永不出现）。
  Future<bool> playWordAudioUrl(String url) async {
    if (url.isEmpty) {
      return false;
    }
    if (!await _isWebViewReady()) {
      return false;
    }
    final int token = ++_wordAudioPlayToken;
    final Completer<bool> completer = Completer<bool>();
    _pendingWordAudioPlays[token] = completer;
    try {
      await _render(
          buildPlayWordAudioScript(kGlobalLookupRootFrameId, url, token));
      final bool ok =
          await completer.future.timeout(_kWordAudioPlayReportTimeout);
      glog('autoread($_label): webview play token=$token ok=$ok');
      return ok;
    } on TimeoutException {
      glog('autoread($_label): webview play token=$token TIMEOUT');
      return false;
    } catch (e) {
      glog('autoread($_label): webview play token=$token EXCEPTION $e');
      return false;
    } finally {
      _pendingWordAudioPlays.remove(token);
    }
  }

  /// 表面 iframe realm 回报自动发音 `audio.play()` 真实结果
  /// （args = [token, ok, reason?]，host 包裹桥盖 __frameId 后原样转发）。
  /// 完成对应 pending Completer；过期 token（已超时回落）直接忽略。
  ///
  /// 返回 true = 已处理（调用方 `_onJsMessage` 直接 return）。
  bool maybeHandleWordAudioPlayed(
      Object? handler, Map<String, Object?> message) {
    if (handler != 'wordAudioPlayed') {
      return false;
    }
    final Object? args = message['args'];
    if (args is List && args.length >= 2) {
      final Object? rawToken = args[0];
      final int? token =
          rawToken is num ? rawToken.toInt() : int.tryParse('$rawToken');
      if (token != null) {
        final bool ok = args[1] == true;
        // BUG-1204：失败原因（args[2]，旧 host 不带 → 空）落日志。没有它，
        // 「首播必失败」只是一个 false，分不清 autoplay 拦截 / 解码失败 / 被掐断，
        // 而这三种的根因修法完全不同。成功不记，避免刷屏。
        if (!ok) {
          final String reason = (args.length >= 3 ? '${args[2]}' : '').trim();
          glog('autoread($_label): webview play token=$token FAILED '
              'reason=${reason.isEmpty ? 'unreported' : reason}');
        }
        final Completer<bool>? completer = _pendingWordAudioPlays.remove(token);
        if (completer != null && !completer.isCompleted) {
          completer.complete(ok);
        }
      }
    }
    return true;
  }
}
