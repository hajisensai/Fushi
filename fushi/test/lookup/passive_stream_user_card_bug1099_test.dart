// BUG-1099 — 「查完词后剪贴板一更新，浮窗释义被清空缩回去」。
//
// 根因：区分「被动文本流」与「用户显式意图」的 [DesktopLookupRequest.passiveStream]
// 自 a3330a4bc 引入后，唯一置 true 的调用点在 GalgameSessionController；该文件在
// 2df13d481 作为死代码整体删除，全仓再无 passiveStream: true，于是
// ClipboardPanelController 里那条「用户已点词就只换句子横幅」的保护变成永不触发的
// 死代码。每条新台词（剪贴板监听灌进来）都走正常路径 → _seedRootFrame 整帧重置 →
// 用户点出的释义蒸发；瞬态覆盖窗那侧还会把 _lastSentWidth/_lastSentHeight 打回 -1、
// _revealed 清 false，auto-size 窗口跟着新 root 的小内容「缩回去」。
//
// 本文件锁三层：
//  1. 判据纯函数 keepUserOwnedCardForPassiveStream 的两个方向（被动流保住用户卡 /
//     显式意图照常替换）——面板与瞬态窗共用它，语义不会漂开。
//  2. 服务侧真实排队：剪贴板监听 = 被动流；悬浮字幕点词等显式意图 = 非被动流。
//  3. 两个消费面的接线（源码扫描，运行时链要真窗口）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/desktop_lookup_router.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByFushiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('app.fushi/window'),
      (MethodCall call) async => null,
    );
  });
  tearDown(() {
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByFushiAppFamily = null;
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('app.fushi/window'), null);
  });

  group('keepUserOwnedCardForPassiveStream（面板/瞬态窗共用判据）', () {
    test('被动流 + 用户拥有的卡 + 卡可见 → 保住用户的释义（不清帧）', () {
      expect(
        keepUserOwnedCardForPassiveStream(
          passiveStream: true,
          userOwnedCard: true,
          visible: true,
        ),
        isTrue,
        reason: 'BUG-1099 的正题：台词流不得冲掉用户点出来的释义',
      );
    });

    test('显式意图（热键/点词/悬浮字幕）恒替换——绝不被这条保护锁死', () {
      // 这是本修复最容易做错的方向：把主动查词也一起挡掉，用户会以为查词坏了。
      expect(
        keepUserOwnedCardForPassiveStream(
          passiveStream: false,
          userOwnedCard: true,
          visible: true,
        ),
        isFalse,
      );
    });

    test('卡不是用户点出来的（上一条被动流自动查的）→ 下一条流正常替换', () {
      expect(
        keepUserOwnedCardForPassiveStream(
          passiveStream: true,
          userOwnedCard: false,
          visible: true,
        ),
        isFalse,
      );
    });

    test('卡已经不在屏上 → 没有什么要保护，下一条流正常开卡（保护不会永久粘住）', () {
      expect(
        keepUserOwnedCardForPassiveStream(
          passiveStream: true,
          userOwnedCard: true,
          visible: false,
        ),
        isFalse,
      );
    });
  });

  group('DesktopLookupService：谁是被动流', () {
    test('剪贴板监听（processClipboardText）排队的请求 passiveStream=true', () {
      DesktopLookupService.instance.processClipboardText('お前はもう死んでいる');
      expect(
          DesktopLookupService.instance.pendingRequest?.passiveStream, isTrue,
          reason: '剪贴板变化由 OS 事件驱动，用户没有对 Hibiki 做任何动作 = 被动流');
      expect(DesktopLookupService.instance.pendingRequest?.origin,
          DesktopLookupOrigin.clipboard);
    });

    test('抓选区括号期回放的剪贴板事件同样是被动流（同一条环境通道）', () {
      DesktopLookupService.instance.beginSelfInflictedCapture();
      DesktopLookupService.instance.processClipboardText('真实复制');
      // 括号期内先到的事件被暂存，对账后放行。
      expect(DesktopLookupService.instance.pendingRequest, isNull);
      DesktopLookupService.instance.endSelfInflictedCapture(<String>['自产选区']);
      expect(DesktopLookupService.instance.pendingRequest?.text, '真实复制');
      expect(
          DesktopLookupService.instance.pendingRequest?.passiveStream, isTrue);
    });

    test('显式查词（悬浮字幕点词 triggerLookup）passiveStream=false', () {
      DesktopLookupService.instance.triggerLookup('気配');
      expect(
        DesktopLookupService.instance.pendingRequest?.passiveStream,
        isFalse,
        reason: '用户点词是显式意图，必须正常替换当前卡',
      );
      expect(DesktopLookupService.instance.pendingRequest?.origin,
          DesktopLookupOrigin.explicit);
    });

    test('热键路径源码不标被动流（热键是最显式的意图）', () {
      final String src =
          File('lib/src/sync/desktop_lookup_service.dart').readAsStringSync();
      final int at = src.indexOf('Future<void> _onHotKey()');
      expect(at, greaterThan(0));
      final int end = src.indexOf('\n  }', at);
      expect(src.substring(at, end).contains('passiveStream'), isFalse,
          reason: '热键必须保持默认 passiveStream:false，否则用户按热键查词会被吞');
    });
  });

  group('消费面接线（源码扫描；运行时链要真覆盖窗）', () {
    final String panelSrc =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final String glcSrc =
        File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync();
    final String dispatcherSrc =
        File('lib/src/lookup/desktop_lookup_dispatcher.dart')
            .readAsStringSync();

    test('面板 update 用共享判据决定「只换横幅」，不再自己拼条件', () {
      final int at = panelSrc.indexOf('Future<void> update(');
      expect(at, greaterThan(0));
      final int guardAt =
          panelSrc.indexOf('keepUserOwnedCardForPassiveStream(', at);
      final int seedAt = panelSrc.indexOf('_seedRootFrame(request.text', at);
      expect(guardAt, greaterThan(at), reason: 'update 必须先过被动流判据');
      expect(seedAt, greaterThan(guardAt),
          reason: '判据必须在整帧重置（_seedRootFrame）之前，否则释义已经没了');
    });

    test('dispatcher 把 passiveStream 透传给瞬态覆盖窗', () {
      expect(dispatcherSrc.contains('passiveStream: request.passiveStream'),
          isTrue,
          reason: 'transient 分区不透传标记，瞬态窗那侧的保护就永远收不到信号');
    });

    test('瞬态窗 lookupText 在被动流命中判据时早退（不重建 root、不清尺寸）', () {
      final int at = glcSrc.indexOf('Future<bool> lookupText(');
      expect(at, greaterThan(0));
      final int guardAt =
          glcSrc.indexOf('keepUserOwnedCardForPassiveStream(', at);
      final int hideAt = glcSrc.indexOf('GlobalLookupChannel.hide(', at);
      expect(guardAt, greaterThan(at));
      expect(hideAt, greaterThan(guardAt),
          reason: '早退必须在 hide + _lookupExternal 之前，否则窗口已经被清空缩回去了');
    });

    test('瞬态窗所有权：用户动作置位、真正关卡复位（保护不会永久粘住）', () {
      expect(glcSrc.contains('_userOwnedCard = !passiveStream'), isTrue,
          reason: '显式意图开的卡归用户，被动流开的卡不归');
      final int nestedAt = glcSrc.indexOf('Future<void> _lookupNested(');
      expect(nestedAt, greaterThan(0));
      final int nestedEnd = glcSrc.indexOf('\n  }', nestedAt);
      expect(
          glcSrc
              .substring(nestedAt, nestedEnd)
              .contains('_userOwnedCard = true'),
          isTrue,
          reason: '用户在卡里点词开级联，这张卡当然归用户');
      final int hiddenAt = glcSrc.indexOf('void _onOverlayHidden()');
      expect(hiddenAt, greaterThan(0));
      final int hiddenEnd = glcSrc.indexOf('\n  }', hiddenAt);
      expect(
        glcSrc
            .substring(hiddenAt, hiddenEnd)
            .contains('_userOwnedCard = false'),
        isTrue,
        reason: '不复位就会永久吞掉后续所有被动流查词',
      );
    });
  });
}
