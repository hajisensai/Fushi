// spec 2026-07-10 §8 — 抓选区剪贴板事件泄漏根修：一次性忽略集契约。
// 全局查词抓选区会向剪贴板写「捕获文本」与「恢复的旧文本」，各触发一次
// WM_CLIPBOARDUPDATE；忽略集必须吞掉这批自产事件，且不能吞掉用户后续的
// 真实复制（未命中即整批过期）。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/clipboard_dedupe.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  group('ClipboardIgnoreSet', () {
    test('register 后 consume 命中即吞掉且一次性', () {
      final ClipboardIgnoreSet s = ClipboardIgnoreSet()
        ..register(<String>['選択テキスト', '旧剪贴板']);
      expect(s.consume('選択テキスト'), isTrue);
      // 同批第二个登记仍可命中（一次捕获登记两个文本）。
      expect(s.consume('旧剪贴板'), isTrue);
      // 一次性：再次出现同文本 = 用户真实复制，不吞。
      expect(s.consume('選択テキスト'), isFalse);
    });

    test('consume 对 trim 后相同的文本命中（剪贴板常带尾随空白/换行）', () {
      final ClipboardIgnoreSet s = ClipboardIgnoreSet()
        ..register(<String>['単語\n']);
      expect(s.consume('単語'), isTrue);
    });

    test('未命中的真实复制使整批登记过期（防陈旧登记吞掉后续复制）', () {
      final ClipboardIgnoreSet s = ClipboardIgnoreSet()
        ..register(<String>['stale']);
      expect(s.consume('用户真实复制'), isFalse);
      expect(s.consume('stale'), isFalse); // 已整体过期
    });

    test('空白登记被忽略', () {
      final ClipboardIgnoreSet s = ClipboardIgnoreSet()
        ..register(<String>['  ', '\n']);
      expect(s.isEmpty, isTrue);
    });
  });

  group('DesktopLookupService.processClipboardText 与忽略集集成', () {
    setUp(() {
      DesktopLookupService.instance.debugReset();
      // 清残留登记：consume 未命中即整批清空。
      DesktopLookupService.instance.clipboardIgnores.consume('__flush__');
    });

    test('登记文本不产生 pending（抓选区自产事件被吞）', () {
      DesktopLookupService.instance.clipboardIgnores.register(<String>['捕获文本']);
      DesktopLookupService.instance.processClipboardText('捕获文本');
      expect(DesktopLookupService.instance.pendingRequest, isNull);
    });

    test('未登记文本照常排队', () {
      DesktopLookupService.instance.processClipboardText('真实复制');
      expect(DesktopLookupService.instance.pendingText, '真实复制');
    });

    test('吞掉自产事件后，用户复制同文本仍能查词', () {
      DesktopLookupService.instance.clipboardIgnores.register(<String>['単語']);
      DesktopLookupService.instance.processClipboardText('単語'); // 自产，被吞
      expect(DesktopLookupService.instance.pendingRequest, isNull);
      DesktopLookupService.instance.processClipboardText('単語'); // 用户真实复制
      expect(DesktopLookupService.instance.pendingText, '単語');
    });
  });
}
