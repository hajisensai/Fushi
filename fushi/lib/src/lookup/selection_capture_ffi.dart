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

import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

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

  /// Saves the clipboard, clears it, injects a clean Ctrl+C so the foreground
  /// app copies its current selection, reads it back, then restores the
  /// previous clipboard text. Returns the selected text, or null if nothing was
  /// captured.
  static Future<String?> captureForegroundSelection() async {
    if (!Platform.isWindows || _keybdEvent == null) {
      glog('capture: unsupported (windows=${Platform.isWindows} '
          'ffi=${_keybdEvent != null})');
      return null;
    }

    final String? oldText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text;

    // spec 2026-07-10 §8 — 本函数的剪贴板写入（清空 / 注入 Ctrl+C 的选区写入 /
    // 旧值恢复）都会触发 WM_CLIPBOARDUPDATE；此刻 app 不在前台，剪贴板监听会把
    // 它们当用户复制排进查词管线（假查词/面板错句）。TODO-617 设计（design.md:74）
    // 规划过此护栏但从未实现。审查修正：captured 回声可能在下方轮询的 await 间隙
    // **先于事后登记**到达——故改用捕获期括号：begin 后事件一律暂存，end 时以
    // 「本次自产文本集合」对账放行/丢弃（收口后才到的恢复回声由登记集拦截）。
    DesktopLookupService.instance.beginSelfInflictedCapture();
    String? captured;
    try {
      await Clipboard.setData(const ClipboardData(text: ''));

      _injectCleanCopy();

      // Bounded poll: the Windows clipboard update is async and may be briefly
      // locked by the source app (mirrors the BUG-114 retry in
      // desktop_lookup_service.dart). ~600ms ceiling.
      for (int i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final String? now =
            (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (now != null && now.isNotEmpty) {
          captured = now;
          break;
        }
      }
    } finally {
      // 收口在恢复写入**之前**：恢复回声在登记之后到达，必被登记集吞掉。
      // finally 保证异常路径也不把括号留开（否则后续真实复制全被暂存卡死）。
      DesktopLookupService.instance.endSelfInflictedCapture(<String>[
        if (captured != null) captured,
        if (oldText != null) oldText,
      ]);
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
