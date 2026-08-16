import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/clipboard_dedupe.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

enum DesktopLookupOrigin { clipboard, hotkey, explicit }

enum DesktopLookupForegroundPolicy { none, bringToFront }

class DesktopLookupRequest {
  const DesktopLookupRequest({
    required this.text,
    required this.origin,
    this.foregroundPolicy = DesktopLookupForegroundPolicy.bringToFront,
    this.showSourcePanel = true,
    this.passiveStream = false,
    this.rubySpans = const <RubySpan>[],
  });

  /// 纯基准文本：注音标记已在 [DesktopLookupService._queueLookupRequest] 剥掉
  /// （注音落在 [rubySpans]）。本条链路的唯一坐标系。
  final String text;

  /// 注音（振假名）区间，下标落在 [text] 上（UTF-16 code unit）。空 = 无注音。
  final List<RubySpan> rubySpans;
  final DesktopLookupOrigin origin;
  final DesktopLookupForegroundPolicy foregroundPolicy;
  final bool showSourcePanel;

  /// 剪贴板内容变化是环境输入，不代表用户要求播放声音；全局热键与显式点词
  /// 是用户主动发起的查词，可继续遵循 autoReadOnLookup 偏好。
  bool get allowsAutomaticAudio => origin != DesktopLookupOrigin.clipboard;

  /// 被动连续文本流：Hibiki 在**没有收到任何指向自己的用户动作**时被环境喂进来的文本
  /// （galgame 台词 hook / 外部 texthooker 每 ~400ms 往剪贴板灌一条新台词，由
  /// [DesktopLookupService.processClipboardText] 的剪贴板监听接住），而不是用户的一次性
  /// 显式意图（全局热键 [DesktopLookupOrigin.hotkey] / 悬浮字幕点词
  /// [DesktopLookupOrigin.explicit]）。
  ///
  /// 两个消费面据此决定是否保留用户已点出的那张卡（判据单一真相源
  /// `keepUserOwnedCardForPassiveStream`）：
  /// - 悬浮面板：用户已点词查看释义时只刷新可点句子横幅，不抢占/不重置 root；
  /// - 瞬态覆盖窗：用户点词开出的卡直接留在原地，不重建 root、不清空已测尺寸。
  /// 否则连续流会把点词的 searchDictionary 作废 + 整帧重置冲掉释义，表现为
  /// 「对话流动时点词没反应 / 释义被清空缩回去」（BUG-1099）。
  ///
  /// BUG-1099 根因备忘：本字段自 a3330a4bc 引入后，唯一置 true 的调用点在
  /// GalgameSessionController；该文件在 2df13d481 作为死代码整体删除，于是全仓再无
  /// `passiveStream: true`，上面两条保护变成永不触发的死代码，用户报的
  /// 「查完词后剪贴板一更新释义就被清空」重新出现。现由剪贴板监听路径直接标记。
  final bool passiveStream;
}

/// 桌面剪贴板 + 全局热键查词触发器。单例 ChangeNotifier（仿 TexthookerService）。
/// 监听系统剪贴板变化与全局热键 → 去重 → 设 pendingText。
///
/// 这里不直接唤主窗前台：只有词典页实际消费 [pendingText] 并开始搜索时，
/// 才由 UI 调用 [bringPendingLookupToFront]，避免任意剪贴板变化抢前台。
///
/// TODO-1355：被动剪贴板变化（origin=clipboard）连消费侧也**不**唤前台——用户在别的
/// 窗口工作时剪贴板一变就把 Hibiki 弹前面会打断用户。剪贴板来源统一带
/// [DesktopLookupForegroundPolicy.none]，只在后台准备查词结果；唤前台只保留给显式
/// 意图（全局热键 / 悬浮字幕点词）。
///
/// 聚焦态**不**参与是否查词的判定（用户 2026-08-16 拍板删除聚焦过滤）：无论 Hibiki
/// 在不在前台，剪贴板一变就查词。此前的 [WindowListener] 聚焦跟踪只服务于那条过滤，
/// 已随之整条移除；抢前台与否仍由 [DesktopLookupForegroundPolicy] 单独决定。
class DesktopLookupService extends ChangeNotifier with ClipboardListener {
  DesktopLookupService._();
  static final DesktopLookupService instance = DesktopLookupService._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  DesktopLookupRequest? _pendingRequest;
  DesktopLookupRequest? get pendingRequest => _pendingRequest;
  String? get pendingText => _pendingRequest?.text;
  String? _lastText;

  /// BUG-1025：上次查词文本的时刻，配 [_lastText] 做时间窗去重——同词只在极短窗口内
  /// 判为自触发回声跳过，超窗口的同词复制视为用户显式重查放行。
  DateTime? _lastTextTime;

  /// BUG-1025：时间窗去重用的时钟，@visibleForTesting 便于离屏单测注入固定时刻。
  @visibleForTesting
  DateTime Function() clock = () => DateTime.now();

  /// BUG-700 / TODO-1385：监听生命周期用**引用计数**而非裸 `bool _running`。
  ///
  /// 根因：本服务是 app 级单例，但其唯一 owner（[HomeDictionaryPage]）会在窗口物理宽
  /// 跨 600px 断点时（`home_page.dart` 的 compact↔medium 布局切换，两套结构不同的
  /// Scaffold）被 Flutter dispose+重建。Flutter 先挂新元素（initState→[start]）、帧末才
  /// 卸旧元素（dispose→[stop]），于是同一帧内**短暂存在两个 owner**。裸 `bool` 无法建模
  /// 这种瞬时重叠：新页 start 见 `_running==true` 短路 no-op（不重挂 addListener），随后
  /// 旧页 stop 把 watcher 停掉、监听器摘掉 → 净结果 watcher 死掉、静默不查（缩回窗口偶尔
  /// 又好是 start/stop 均 `unawaited` 异步穿插的非确定性）。
  ///
  /// 引用计数正确建模「N 个并发持有者」：每次 [start] 计数 +1，每次 [stop] 计数 -1，
  /// 只有 0→1 才真正挂 watcher、只有 1→0 才真正拆。断点期计数 1→2→1 恒 >0，watcher 始终
  /// 存活；真正切离查词 tab（无第二个 owner）时计数归 0 才拆，故仍满足「仅在查词界面监听
  /// 剪贴板/全局热键」的既定契约。
  /// 计数的自增/分支判定都在首个 `await` 之前同步完成，故与 start/stop 的 `unawaited`
  /// 异步穿插无关，结果确定。
  int _startRefCount = 0;
  DesktopClipboardWindowMode _windowMode = DesktopClipboardWindowMode.normal;
  HotKey? _hotKey;

  /// 剪贴板复制历史采集回调（AppModel 接上 `addClipboardHistoryEntry`）。仅在真实
  /// 剪贴板变化（origin=clipboard、去重通过）时触发；热键 / 悬浮字幕点词不计入
  /// 「复制历史」。桌面单例，主进程设一次。
  void Function(String text)? onClipboardCaptured;

  bool get isRunning => _startRefCount > 0;

  /// TODO-1355：被动剪贴板变化（用户在**别的 app** 里复制）只把内容排进查词管线
  /// 供词典页在后台准备结果，**绝不**唤主窗前台/抢焦点——用户此刻正在别的窗口工作，
  /// 剪贴板一变就把 Hibiki 弹到前面会打断用户。故剪贴板来源统一用
  /// [DesktopLookupForegroundPolicy.none]：消费侧（HomeDictionaryPage._runDesktopLookup）
  /// 见 none 时只搜索、不调 [bringPendingLookupToFront]。想主动把查词唤到前台的用户
  /// 仍可按全局热键（Ctrl+Shift+D，origin=hotkey）或在悬浮字幕上点词（origin=explicit）
  /// ——那些是显式意图，保留 bringToFront。窗口置顶策略（[DesktopClipboardWindowMode]）
  /// 不改变本约定：无论选哪种策略，被动剪贴板变化都不抢焦点。
  ///
  /// BUG-1099 — [passiveStream]：本方法的两个调用点（[processClipboardText] 与
  /// [endSelfInflictedCapture] 的回放）都来自**环境剪贴板监听**，即 Hibiki 没有收到
  /// 任何指向自己的用户动作，故一律传 true。显式意图（热键 [_onHotKey] / 悬浮字幕点词
  /// [triggerLookup]）不走本方法，它们直接调 [_queueLookupRequest] 并保持
  /// `passiveStream: false`，因此永远不会被消费侧的「保留用户卡」分支拦下。
  void submitText(String raw, {bool passiveStream = false}) {
    _queueLookupRequest(
      raw,
      origin: DesktopLookupOrigin.clipboard,
      foregroundPolicy: DesktopLookupForegroundPolicy.none,
      passiveStream: passiveStream,
    );
  }

  void _queueLookupRequest(
    String raw, {
    required DesktopLookupOrigin origin,
    DesktopLookupForegroundPolicy foregroundPolicy =
        DesktopLookupForegroundPolicy.bringToFront,
    bool showSourcePanel = true,
    bool dedupe = true,
    bool passiveStream = false,
  }) {
    // 注音标记在这里剥，且必须**先于**下面的截断：先截断会把 `<rふる>` 这类标记
    // 拦腰切断，解析器认不出就只能把半截标记当正文留下。剥完得到的纯基准文本是
    // 本条链路（透明文字窗 / 悬浮面板 / 瞬态卡 / 剪贴板历史）唯一的坐标系，注音
    // 以旁路区间随 [DesktopLookupRequest.rubySpans] 下发。
    //
    // 放在 _queueLookupRequest 而不是 processClipboardText，是因为这里是剪贴板 /
    // 全局热键 / 悬浮字幕点词三个来源的共同收口，一处生效即可；而自产回声拦截
    // （clipboardIgnores.consume）必须留在上游比对**原始串**——登记侧写进剪贴板的
    // 就是原始串。
    final RubyMarkupText parsed = parseRubyMarkup(raw);
    // BUG-442：剪贴板/热键/显式查词的统一入口。所有来源在排队前先按同一码点上限
    // 截断（用 characters 不切碎代理对 / 字素簇），避免超长串一路流到逐字渲染的
    // SourceLookupTextPanel 把主 isolate 撑爆，也省掉对超长串做线性清洗。
    raw = _capLookupInput(parsed.text);
    if (!dedupe) {
      final String trimmed = raw.trim();
      if (trimmed.isEmpty) return;
      _lastText = trimmed;
      _lastTextTime = clock();
      _pendingRequest = DesktopLookupRequest(
        text: trimmed,
        origin: origin,
        foregroundPolicy: foregroundPolicy,
        showSourcePanel: showSourcePanel,
        passiveStream: passiveStream,
        rubySpans: parsed.rebase(trimmed).spans,
      );
      notifyListeners();
      return;
    }
    // BUG-1025：时间窗去重——同词只在极短窗口内当自触发回声跳过，超窗口的同词复制
    // 视为用户显式重查放行。
    final DateTime nowTs = clock();
    final String? deduped =
        dedupeClipboard(raw, _lastText, lastAt: _lastTextTime, now: nowTs);
    if (deduped == null) return;
    _lastText = deduped;
    _lastTextTime = nowTs;
    // BUG-1145：剪贴板复制历史的唯一采集点。落在**去重通过之后**，所以被
    // dedupeClipboard 判为自触发回声（挖词/抓选区写回）的那次不会进历史；同一段
    // 文本超窗口再复制则如实记一条，仓库侧 [ClipboardHistoryRepository.add] 再做
    // 「同文本去重到最新」把它移到队尾而不是堆重复行。
    //
    // `origin == clipboard` 是真实剪贴板变化的判据：热键（origin=hotkey）与悬浮
    // 字幕点词（origin=explicit）都走上面 `dedupe: false` 的提前返回分支，本行不
    // 可达；这道显式判定保证即使将来有别的来源改走去重分支，也不会把非「复制」
    // 动作污染进复制历史（守卫见 desktop_lookup_service_test.dart 的 BUG-1145 组）。
    //
    // 记的是 [deduped]——注音标记已剥、超长已截断的纯基准文本，与本条链路
    // （透明文字窗 / 悬浮面板 / 瞬态卡 / 剪贴板历史）其余消费面同一坐标系。
    if (origin == DesktopLookupOrigin.clipboard) {
      onClipboardCaptured?.call(deduped);
    }
    _pendingRequest = DesktopLookupRequest(
      text: deduped,
      origin: origin,
      foregroundPolicy: foregroundPolicy,
      showSourcePanel: showSourcePanel,
      passiveStream: passiveStream,
      rubySpans: parsed.rebase(deduped).spans,
    );
    notifyListeners();
  }

  /// BUG-442：把查词输入截断到 [kMaxLookupInputChars] 个码点（字素簇），防止超长
  /// 剪贴板文本一路流到逐字建 widget 的 [SourceLookupTextPanel] 触发主 isolate OOM。
  /// 用 `characters` 截断不切碎代理对 / 组合字素；截断时记 info 级日志（非 error，
  /// 这是正常的防御性裁剪而非异常）。
  String _capLookupInput(String raw) {
    final Characters chars = raw.characters;
    if (chars.length <= kMaxLookupInputChars) return raw;
    debugPrint(
      '[desktop-lookup] clipboard input ${chars.length} chars exceeds '
      '$kMaxLookupInputChars; truncating for lookup.',
    );
    return chars.take(kMaxLookupInputChars).toString();
  }

  void clearPending() {
    _pendingRequest = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _pendingRequest = null;
    _lastText = null;
    _lastTextTime = null;
    // BUG-1145：采集回调是单例上的长命字段，不清会让上一个用例装的捕获器
    // 漏进后续用例（写到已经析构的仓库上）。生产侧不调 debugReset，行为不受影响。
    onClipboardCaptured = null;
    // BUG-700：跑过 start()/stop() 的用例可能留下非零计数 + 已挂的 Dart 侧监听器，
    // 若不清会漏进后续用例。仅在确有累计计数时同步摘除监听并归零（未 start 的用例
    // 计数恒 0，此块跳过，行为不变）。removeListener 对未注册的监听器是安全 no-op。
    if (_startRefCount > 0) {
      clipboardWatcher.removeListener(this);
      _startRefCount = 0;
      _hotKey = null;
    }
  }

  Future<void> start({required DesktopClipboardWindowMode windowMode}) async {
    if (!isDesktop) return;
    // 计数自增 + 分支判定在首个 await 之前同步完成（见 [_startRefCount] 说明）。
    _startRefCount++;
    if (_startRefCount > 1) {
      // 已有 owner 在监听（老 owner，或跨断点重建时新旧页短暂重叠的第二个 owner）：
      // watcher / 监听器 / 热键都还在位，只需按新 windowMode 重配一次；**绝不**重挂
      // addListener（重挂无益，且过去与随后旧页的 stop 穿插正是 watcher 被拆死的根因）。
      await configureWindowMode(windowMode);
      return;
    }
    // 首个 owner（0→1）：真正把剪贴板 watcher + 全局热键接上。
    await configureWindowMode(windowMode);
    clipboardWatcher.addListener(this);
    await clipboardWatcher.start();
    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyD,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(_hotKey!, keyDownHandler: (_) => _onHotKey());
  }

  Future<void> stop() async {
    // 计数递减 + 分支判定同步完成（见 [_startRefCount] 说明）。计数已为 0 时钳制成
    // no-op（防重复 stop / 设置里关开关时词典页早已卸载→计数已为 0 的下溢）。
    if (_startRefCount == 0) return;
    _startRefCount--;
    // 仍有其它 owner 持有（跨断点重建时新旧页短暂重叠）：保持 watcher 存活，
    // 只有最后一个引用释放（1→0）才真正拆。这正是消除断点竞态的关键。
    if (_startRefCount > 0) return;
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
    // TODO-1086 根因：这里过去调**全局** hotKeyManager.unregisterAll()，会连带注销
    // 本进程里其它服务注册的系统热键——尤其是应用外全局查词（GlobalLookupController
    // 的 Ctrl+Alt+D）。本服务（老的 Ctrl+Shift+D 剪贴板/热键查词）一旦在全局查词热键
    // 注册后被 stop/restart，就会把 Ctrl+Alt+D 一并抹掉，导致「应用外查词唤不出来」。
    // 改为只注销自己持有的那个热键（per-hotkey），互不干扰。
    final HotKey? hotKey = _hotKey;
    if (hotKey != null) {
      await hotKeyManager.unregister(hotKey);
    }
    _hotKey = null;
    if (_windowMode == DesktopClipboardWindowMode.lookup) {
      await _setAlwaysOnTop(false);
    }
  }

  Future<void> configureWindowMode(
    DesktopClipboardWindowMode windowMode,
  ) async {
    _windowMode = windowMode;
    if (!isDesktop) return;
    await _setAlwaysOnTop(windowMode == DesktopClipboardWindowMode.always);
  }

  Future<void> _setAlwaysOnTop(bool value) async {
    if (!isDesktop) return;
    if (DesktopForegroundGuard.isHiddenWindowsRunner) return;
    try {
      await windowManager.setAlwaysOnTop(value);
    } on MissingPluginException {
      // Widget tests and non-window-manager hosts may not install the plugin.
    } on PlatformException {
      // Keep lookup service lifecycle independent from a transient window call.
    }
  }

  /// clipboard_watcher 的 [ClipboardListener.onClipboardChanged] 返回 `void`，
  /// 故异步读取剪贴板的工作下放到不等待的 [_handleClipboardChange]。
  @override
  void onClipboardChanged() {
    unawaited(_handleClipboardChange());
  }

  /// spec 2026-07-10 §8 — 抓选区自产剪贴板事件的一次性忽略集。收口后到达的
  /// 回声（典型是「恢复旧值」那次写入）由 [processClipboardText] 按文本命中
  /// 吞掉。捕获期内先到的事件走 [_deferredDuringCapture]（见下）。
  final ClipboardIgnoreSet clipboardIgnores = ClipboardIgnoreSet();

  /// §8 捕获期括号（审查修正：captured 回声可能在抓取轮询的 await 间隙**先于
  /// 登记**到达——只靠事后登记拦不住主泄漏路径）。抓取方在写剪贴板前
  /// [beginSelfInflictedCapture]，期间到达的事件全部暂存；抓取完成后
  /// [endSelfInflictedCapture] 拿到「本次自产文本集合」对账：命中=自产回声丢弃，
  /// 未命中=捕获窗口里的真实用户复制，原样放行（仍是文本契约，不是时间窗）。
  bool _captureBracket = false;
  final List<String> _deferredDuringCapture = <String>[];

  void beginSelfInflictedCapture() {
    _captureBracket = true;
    _deferredDuringCapture.clear();
  }

  /// [ignoreTexts] = 本次抓取实际写入过剪贴板的文本（捕获到的选区 + 待恢复的
  /// 旧值）。先登记（拦截收口**之后**才到的恢复回声），再回放暂存事件：自产
  /// 回声按本次集合直接对账丢弃（不动 [clipboardIgnores]——回放 miss 不应
  /// 清掉刚登记的恢复回声条目），真实复制走正常提交（去重仍生效）。
  void endSelfInflictedCapture(Iterable<String> ignoreTexts) {
    final Set<String> selfInflicted = <String>{
      for (final String t in ignoreTexts)
        if (t.trim().isNotEmpty) t.trim(),
    };
    clipboardIgnores.register(selfInflicted);
    _captureBracket = false;
    final List<String> deferred = List<String>.of(_deferredDuringCapture);
    _deferredDuringCapture.clear();
    for (final String text in deferred) {
      if (selfInflicted.contains(text.trim())) continue;
      // BUG-1099：回放的仍是**剪贴板监听**接住的事件（只是抓选区括号期内先到、
      // 事后对账放行），来源与 [processClipboardText] 同一条环境通道，故同样是被动流。
      submitText(text, passiveStream: true);
    }
  }

  Future<void> _handleClipboardChange() async {
    // 用户 2026-08-16 拍板：删掉「Hibiki 在前台就不触发」的聚焦过滤——复制即查词，
    // 不再按 app 内/外区分。Hibiki 自产的剪贴板写入（抓选区、挖词回写）由
    // [clipboardIgnores] 精确拦截，同词回声由 [dedupeClipboard] 的时间窗兜底，
    // 两者都不依赖聚焦态，所以删掉过滤不会把自触发回声放进查词管线。
    final String? text = await _readClipboardText();
    if (text == null) return;
    processClipboardText(text);
  }

  /// 剪贴板事件读取成功后的统一入口。@visibleForTesting 使 §8 泄漏根修可离屏
  /// 单测（真实剪贴板读取在测试环境不可驱动）。
  @visibleForTesting
  void processClipboardText(String text) {
    if (text.trim().isEmpty) return;
    if (_captureBracket) {
      // §8 捕获期：自产/真实无法当场区分（登记要等抓取读到文本才知道），
      // 一律暂存，endSelfInflictedCapture 对账后放行或丢弃。
      _deferredDuringCapture.add(text);
      return;
    }
    if (clipboardIgnores.consume(text)) return;
    // BUG-1099：剪贴板监听 = 被动文本流。这条路径由 OS 的剪贴板变化事件驱动
    // （[onClipboardChanged]），用户没有对 Hibiki 做任何动作；galgame 台词 hook /
    // 外部 texthooker 正是经这里每 ~400ms 灌一条新台词。标 passiveStream 让消费侧
    // 能把它与热键/点词这类显式意图区分开，不再冲掉用户点出的释义。
    submitText(text, passiveStream: true);
  }

  Future<void> _onHotKey() async {
    final String? text = await _readClipboardText();
    if (text == null || text.trim().isEmpty) return;
    _lastText = null; // 热键强制查（即便与上次相同）
    _queueLookupRequest(
      text,
      origin: DesktopLookupOrigin.hotkey,
      dedupe: false,
    );
  }

  @visibleForTesting
  Future<void> debugTriggerHotKey() => _onHotKey();

  /// BUG-114：Windows 剪贴板是全局独占资源——刚复制的进程可能仍持有句柄，
  /// 此刻 `OpenClipboard` 会失败（errno 5 / "Unable to open clipboard"），
  /// `Clipboard.getData` 抛 [PlatformException]。`_handleClipboardChange` 经
  /// `unawaited` 发射，异常会逃逸到全局 zone（被记成 UncaughtZone 噪音）。
  ///
  /// 这是不可控的平台竞态：做有界重试（占用方通常毫秒级释放），仍失败则放弃
  /// 本次剪贴板变化而不是把异常往外抛。返回 null 表示读取失败。
  Future<String?> _readClipboardText() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
        return d?.text ?? '';
      } on PlatformException {
        if (attempt == 2) return null;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return null;
  }

  /// 显式查词入口（TODO-376）：把一段文本送进与剪贴板/热键完全相同的查词管线
  /// 与出口（[pendingText] → 词典页消费 → [bringPendingLookupToFront]）。
  ///
  /// 与被动剪贴板 [submitText] 的区别：这是用户的**显式**意图（在桌面悬浮字幕条上
  /// 点词），故先清 [_lastText] 越过去重——即便与上次查的是同一个词也要再查一次。
  /// （旧的「app 内复制不弹」聚焦过滤已整条删除，两条路径不再有这项差异。）
  /// Windows 桌面悬浮字幕点词经
  /// `reader_fushi_page.dart` 的 `_lookupFromFloatingLyric` 调到这里，从而复用
  /// 剪贴板查词出口（主窗查词 tab），而不是在阅读器内弹 in-app 浮层。
  ///
  /// 注意：本方法只负责**排队**待查词（设 [pendingText] + 通知），与剪贴板/热键
  /// 回调一致；唤前台、切到查词 tab、实际搜索都由消费侧（[bringPendingLookupToFront]
  /// + HomeDictionaryPage 挂载消费）负责，故仍满足「服务只排队、不在回调里抢前台」
  /// 的守卫契约。
  void triggerLookup(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.isNotEmpty) {
      _lastText = null;
      _queueLookupRequest(
        trimmed,
        origin: DesktopLookupOrigin.explicit,
        dedupe: false,
      );
      return;
    }
    _lastText = null; // 显式查词：越过去重，即便与上次相同也再查。
    submitText(trimmed);
  }

  /// TODO-341：在桌面词典页里复制文本会让 Windows 任务栏的 Hibiki 图标高亮
  /// （图标闪烁/请求注意），用户得点一下 app 才能消掉。
  ///
  /// 根因：`window_manager` 的 `show()`/`focus()` 在 Windows 上都调
  /// `SetForegroundWindow`（见 window_manager-0.5.1/windows/window_manager.cpp
  /// `Show()`/`Focus()`）。`SetForegroundWindow` 对一个**本就在前台**的窗口调用
  /// 时，会被系统的前台锁定规则拒绝并退化为「闪烁该窗口的任务栏按钮以提醒用户」
  /// （MSDN 明文）——即任务栏高亮。用户在词典页复制时主窗口仍在前台，却仍走到
  /// 这条唤前台路径（外部复制/失焦判据被同进程子窗口焦点切换等情形误触），于是
  /// 出现「复制即任务栏高亮」。
  ///
  /// 修法（消除特殊情况，而非按来源打补丁）：「把待查词带到前台」对一个**已经
  /// 在前台**的窗口本就无事可做——唤前台无用、置顶是用户没要的副作用、且
  /// `SetForegroundWindow` 还会触发任务栏 flash。所以已前台时整个调用 no-op。
  /// 热键/真正的外部复制场景窗口不在前台，`isFocused()` 为 false，照常唤起 +
  /// 置顶，行为不变。
  Future<void> bringPendingLookupToFront() => bringMainWindowToFront();

  /// 统一的桌面主窗口显式唤起出口。Hook 台词浮窗的“打开捕获工作台”等非查词
  /// 场景也必须经过这里，复用 Windows 前台归属判断和任务栏闪烁清理。
  Future<void> bringMainWindowToFront() async {
    if (!isDesktop) return;
    if (DesktopForegroundGuard.isHiddenWindowsRunner) return;
    // 已在前台无需（也不该）做任何唤起/置顶动作：对前台窗口调
    // SetForegroundWindow 会被 Windows 前台锁定退化成任务栏 flash（TODO-341）。
    // TODO-615：前台判据抖动时此守卫可能漏判，导致先前误触的任务栏 flash 仍残留；
    // 已前台路径 early-return 前主动 clear 一次，把残留高亮幂等熄灭（FLASHW_STOP
    // 对没有 flash 的窗口是 no-op）。
    if (await _isFushiForeground()) {
      await WindowCaptionChannel.clearTaskbarFlash();
      return;
    }
    try {
      await windowManager.show();
      await windowManager.focus();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (_windowMode != DesktopClipboardWindowMode.normal) {
      await _setAlwaysOnTop(true);
    }
    // TODO-615：show/focus/setAlwaysOnTop 在某些 Windows 版本上仍可能把任务栏按钮
    // 置成请求注意态（即便窗口此刻确实被唤到前台）。唤前台路径尾部统一 clear 一次，
    // 覆盖 always-on-top 路径，确保唤起后任务栏不残留高亮。
    await WindowCaptionChannel.clearTaskbarFlash();
  }

  /// 判断 Hibiki 是否已经占据前台。Windows 上不能只信
  /// [windowManager.isFocused]：词典 WebView/原生子窗口拿焦点时，插件可能报告
  /// 主窗未聚焦，但 `GetForegroundWindow` 仍属于当前 Hibiki 进程。此时继续
  /// show/focus 主窗会触发任务栏请求注意态。
  Future<bool> _isFushiForeground() async {
    if (DesktopForegroundGuard.isForegroundOwnedByCurrentProcess()) {
      return true;
    }
    if (DesktopForegroundGuard.isForegroundOwnedByFushiAppFamily()) {
      return true;
    }
    return _isWindowFocused();
  }

  /// 查询主窗口是否已在前台。插件缺失（widget 测试）或平台调用失败时保守返回
  /// false，让 [bringPendingLookupToFront] 退回到改前的「照常唤前台」行为，
  /// 不因一次瞬态查询失败而漏掉真正需要的唤起。
  Future<bool> _isWindowFocused() async {
    try {
      return await windowManager.isFocused();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TypeError {
      // window_manager.isFocused() does `return await invokeMethod(...)` typed
      // as Future<bool>; a host/channel that yields null (e.g. an incomplete
      // mock or a misbehaving platform impl) makes that implicit bool cast throw
      // a TypeError. Per this method's contract, any inability to determine the
      // focus state conservatively returns false so bringPendingLookupToFront
      // falls back to the pre-TODO-341 "bring to front as usual" path instead of
      // letting the error escape the unawaited call into the global zone.
      return false;
    }
  }
}
