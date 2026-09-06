// TODO-617 selection capture — inject Ctrl+C to grab the foreground app's
// current selection, read it from the clipboard, then restore the clipboard.
//
// This is what makes "select text in any app + press hotkey" work without the
// user copying first (yomitan-style). Pure Dart FFI over user32's keybd_event
// (a thin SendInput wrapper); no native code.
//
// CRITICAL: a global hotkey (e.g. Ctrl+Alt+D) fires while the user still
// physically holds Ctrl/Alt. RegisterHotKey does not release them, so a naive
// injected Ctrl+C arrives as Ctrl+Alt+C (not a copy). We therefore inject
// key-up for every modifier first, then a clean Ctrl+C.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';

typedef _KeybdEventNative = Void Function(
    Uint8 bVk, Uint8 bScan, Uint32 dwFlags, IntPtr dwExtraInfo);
typedef _KeybdEventDart = void Function(
    int bVk, int bScan, int dwFlags, int dwExtraInfo);

abstract final class SelectionCapture {
  static final DynamicLibrary? _user32 =
      Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final _KeybdEventDart? _keybdEvent = _user32
      ?.lookupFunction<_KeybdEventNative, _KeybdEventDart>('keybd_event');

  // Virtual-key codes.
  static const int _vkShift = 0x10;
  static const int _vkControl = 0x11;
  static const int _vkMenu = 0x12; // Alt
  static const int _vkLWin = 0x5B;
  static const int _vkRWin = 0x5C;
  static const int _vkC = 0x43;
  static const int _keyUp = 0x0002; // KEYEVENTF_KEYUP

  // TODO-1030 M0 — the native UI Automation foreground-selection context
  // channel (Windows: flutter_window.cpp RegisterForegroundSelectionChannel;
  // macOS: AppDelegate.swift foreground_selection channel). A
  // MissingPluginException / any failure falls back to the clipboard capture
  // below.
  static const MethodChannel _foregroundSelectionChannel =
      MethodChannel('app.fushi.reader/foreground_selection');

  /// 剪贴板捕获的进程内串行闸门（TODO-1066 手柄/鼠标触发）。
  ///
  /// [captureForegroundSelection] 的「存旧剪贴板 → 清空 → 注入 Ctrl+C → 轮询
  /// → 还原」是一段**跨 await 的事务**，而剪贴板是全局单资源。两次重叠会互相
  /// 拆台：A 存下旧值 → A 清空 → **B 存下的是 A 刚清空的空值** → A 注入并读到
  /// 选区 → A 还原 → B 轮询超时 → B 把剪贴板「还原」成空。用户的剪贴板就这么
  /// 没了（同源事故有前科，见 BUG-707 剪贴板回声）。
  ///
  /// 上游的 route 作废机制救不了这里：它只让**已返回**的旧调用在 await 边界
  /// 自杀，而这段事务一旦开始就必须跑完（半途放弃 = 剪贴板停在被清空的状态）。
  /// 所以正确的层是这里——把事务本身串起来，而不是在调用方丢弃触发。
  ///
  /// 串行而非丢弃，是为了不破坏「再按一次总是查当前选区」的既有语义（见
  /// `global_lookup_controller._onHotKeyRouted` 的注释）：后到的那次照常执行，
  /// 只是排在前一次事务之后；它自己的 route 更新，先到的那次结果被上游丢弃。
  static Future<void> _clipboardCaptureGate = Future<void>.value();

  /// 闸门本体。用 Completer 而不是 `_gate = _gate.then(...)`，是为了让**闸门推进
  /// 与本次事务的成败无关**——事务抛异常也必须放行后来者，否则一次失败就永久
  /// 堵死这条路。
  static Future<T?> _runClipboardExclusive<T>(
    Future<T?> Function() body, {
    bool Function()? stillWanted,
  }) async {
    final Completer<void> tail = Completer<void>();
    final Future<void> previous = _clipboardCaptureGate;
    _clipboardCaptureGate = tail.future;
    await previous;
    try {
      if (stillWanted != null && !stillWanted()) {
        glog('capture: superseded while queued — skipped');
        return null;
      }
      return await body();
    } finally {
      tail.complete();
    }
  }

  /// 只给测试：在**同一道闸门**上跑一段任意事务体。
  ///
  /// 存在的理由是 [captureForegroundSelection] 本身在测试里不可调用——它会真的
  /// 注入 Ctrl+C 并改写跑测试这台机器的剪贴板。串行语义又必须有行为测试兜底
  /// （源码守卫看不出 `await previous` 是不是漏了），故把闸门单独暴露出来。
  @visibleForTesting
  static Future<T?> debugRunClipboardExclusive<T>(
    Future<T?> Function() body, {
    bool Function()? stillWanted,
  }) =>
      _runClipboardExclusive<T>(body, stillWanted: stillWanted);

  /// Saves the clipboard, clears it, injects a clean Ctrl+C so the foreground
  /// app copies its current selection, reads it back, then restores the
  /// previous clipboard text. Returns the selected text, or null if nothing was
  /// captured.
  ///
  /// 并发安全：多次重叠调用按到达顺序**串行**执行（见 [_clipboardCaptureGate]）。
  ///
  /// [stillWanted] 在**排队结束、事务开始前**被求值一次：返回 false 表示这次捕获
  /// 在排队期间已被更新的一次触发取代，于是直接返回 null，一次剪贴板操作都不做。
  /// 没有它，手柄连按/侧键抖动会排出一队各自最长 600ms 的事务，用户要等最后一次
  /// 才看到卡片（每一次都真的去动了剪贴板，只是结果被上游丢弃）。
  static Future<String?> captureForegroundSelection({
    bool Function()? stillWanted,
  }) async {
    if (!Platform.isWindows || _keybdEvent == null) {
      glog('capture: unsupported (windows=${Platform.isWindows} '
          'ffi=${_keybdEvent != null})');
      return null;
    }
    return _runClipboardExclusive(
      _captureForegroundSelectionExclusive,
      stillWanted: stillWanted,
    );
  }

  /// [captureForegroundSelection] 的事务体。**只允许经那道闸门调用**——直接调它
  /// 就绕过了串行保证。
  static Future<String?> _captureForegroundSelectionExclusive() async {
    final String? oldText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text;

    String? captured;
    await Clipboard.setData(const ClipboardData(text: ''));

    _injectCleanCopy();

    // Bounded poll: the Windows clipboard update is async and may be briefly
    // locked by the source app (BUG-114: the copying process may still hold
    // the clipboard handle for a few ms). ~600ms ceiling.
    for (int i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final String? now = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (now != null && now.isNotEmpty) {
        captured = now;
        break;
      }
    }
    if (oldText != null && oldText.isNotEmpty && captured != oldText) {
      await Clipboard.setData(ClipboardData(text: oldText));
    }
    // 隐私：绝不把选中/剪贴板正文写进 glog——只记长度与成功/失败。
    glog('capture: clipboard ok=${captured != null && captured.isNotEmpty} '
        'len=${captured?.length ?? 0} (oldLen=${oldText?.length ?? 0})');
    return captured;
  }

  /// TODO-1030 M0 — captures the foreground app's current selection PLUS its
  /// surrounding context via the native foreground-selection channel (Windows
  /// UI Automation, macOS Accessibility/AX), then trims it to the one sentence
  /// the selection sits in (Yomitan {sentence}-style). Returns a
  /// [ForegroundSelectionContext] with the selected term, the current sentence
  /// and the term's offset inside it; or null when the native side has nothing
  /// (no focused text element, empty selection, unsupported platform, or the
  /// native channel is unavailable) so the caller falls back to
  /// [captureForegroundSelection].
  ///
  /// Off-loads the native capture to a worker thread (see the native channel);
  /// this future completes when the marshalled result returns. Never throws:
  /// any error resolves to null (never break the existing lookup path).
  static Future<ForegroundSelectionContext?> captureForegroundContext({
    int maxExpand = 600,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      glog('context: unsupported (windows=${Platform.isWindows} '
          'macos=${Platform.isMacOS})');
      return null;
    }
    try {
      final Map<Object?, Object?>? reply =
          await _foregroundSelectionChannel.invokeMapMethod<Object?, Object?>(
        'captureContext',
        <String, Object?>{'maxExpand': maxExpand},
      );
      if (reply == null) {
        glog('context: UIA returned null — fall back to clipboard');
        return null;
      }
      final String contextText = reply['contextText']?.toString() ?? '';
      final int selStart = (reply['selStart'] as num?)?.toInt() ?? 0;
      final int selLen = (reply['selLen'] as num?)?.toInt() ?? 0;
      final int elapsedMs = (reply['elapsedMs'] as num?)?.toInt() ?? -1;
      if (contextText.isEmpty || selLen <= 0) {
        glog('context: UIA empty (len=${contextText.length} selLen=$selLen '
            'elapsedMs=$elapsedMs) — fall back');
        return null;
      }
      final String selectedText =
          contextText.substring(selStart, selStart + selLen);
      final SentenceExtractionResult sentence =
          extractSentenceAt(contextText, selStart, selLen);
      // 隐私：绝不记录 contextText / sentence 正文——只记长度、耗时、成功。
      glog('context: UIA ok ctxLen=${contextText.length} '
          'selLen=$selLen sentenceLen=${sentence.sentence.length} '
          'elapsedMs=$elapsedMs');
      return ForegroundSelectionContext(
        selectedText: selectedText,
        sentence: sentence.sentence,
        sentenceSelStart: sentence.selStart,
        sentenceSelLen: sentence.selLen,
      );
    } catch (e) {
      // MissingPluginException (channel not registered) or any native error:
      // fall back to the clipboard capture. Log only the error TYPE.
      glog('context: UIA EXCEPTION ${e.runtimeType} — fall back to clipboard');
      return null;
    }
  }

  /// Releases every modifier the user may be holding from the trigger hotkey,
  /// then sends a clean Ctrl+C. Without the releases the injected copy would be
  /// polluted by the still-held Alt/Shift/Win.
  static void _injectCleanCopy() {
    final _KeybdEventDart f = _keybdEvent!;
    // Release anything held.
    f(_vkShift, 0, _keyUp, 0);
    f(_vkMenu, 0, _keyUp, 0);
    f(_vkLWin, 0, _keyUp, 0);
    f(_vkRWin, 0, _keyUp, 0);
    f(_vkControl, 0, _keyUp, 0);
    // Clean Ctrl+C.
    f(_vkControl, 0, 0, 0); // Ctrl down
    f(_vkC, 0, 0, 0); // C down
    f(_vkC, 0, _keyUp, 0); // C up
    f(_vkControl, 0, _keyUp, 0); // Ctrl up
  }
}

/// TODO-1030 M0 — the result of a UIA foreground-selection context capture: the
/// bare selected term plus the sentence it sits in and where the term lands
/// inside that sentence. Pure data (no body text ever logged by the producer).
class ForegroundSelectionContext {
  const ForegroundSelectionContext({
    required this.selectedText,
    required this.sentence,
    required this.sentenceSelStart,
    required this.sentenceSelLen,
  });

  /// The originally-selected text (the query for the dictionary lookup).
  final String selectedText;

  /// The current sentence the selection sits in (trimmed). May equal
  /// [selectedText] when the buffer had no sentence delimiters.
  final String sentence;

  /// The selection's start offset within [sentence] (UTF-16 code units).
  final int sentenceSelStart;

  /// The selection's length within [sentence] (UTF-16 code units).
  final int sentenceSelLen;
}
