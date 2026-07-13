// spec 2026-07-10 — ClipboardPanelController 的可离屏部分：rect 记忆纯函数、
// 关面板不永久暂停（BUG-717：× 只清当前卡，下一条剪贴板复制重开）、面板栏高度
// 跨端契约、dispatcher panel 分区接线守卫。运行时链（真窗口/真查词）归 M4 真机 gate。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/clipboard_panel_controller.dart';

void main() {
  group('parseClipboardPanelRect / encodeClipboardPanelRect', () {
    test('roundtrip', () {
      const Rect r = Rect.fromLTWH(120.5, 80.0, 380.0, 560.0);
      expect(parseClipboardPanelRect(encodeClipboardPanelRect(r)), r);
    });

    test('非法格式回退 null（用默认位）', () {
      expect(parseClipboardPanelRect(''), isNull);
      expect(parseClipboardPanelRect('1,2,3'), isNull);
      expect(parseClipboardPanelRect('a,b,c,d'), isNull);
      expect(parseClipboardPanelRect('0,0,NaN,100'), isNull);
    });

    test('过小尺寸=损坏记忆，弃用', () {
      expect(parseClipboardPanelRect('0,0,50,560'), isNull);
      expect(parseClipboardPanelRect('0,0,380,50'), isNull);
    });
  });

  group('hitLengthCodePoints（bestLength 码元 → 横幅码点，真机第 4 轮）', () {
    test('BMP 文本码元=码点', () {
      expect(ClipboardPanelController.hitLengthCodePoints(3, '食べていた'), 3);
    });

    test('代理对（emoji/罕见汉字）折算为码点数', () {
      // '𠮟る' — '𠮟' 是 2 个 UTF-16 码元、1 个码点。
      expect(ClipboardPanelController.hitLengthCodePoints(3, '𠮟る'), 2);
    });

    test('越界/非法 bestLength 钳位', () {
      expect(ClipboardPanelController.hitLengthCodePoints(99, 'ある'), 2);
      expect(ClipboardPanelController.hitLengthCodePoints(0, 'ある'), 0);
      expect(ClipboardPanelController.hitLengthCodePoints(-1, 'ある'), 0);
      expect(ClipboardPanelController.hitLengthCodePoints(2, ''), 0);
    });
  });

  group('rootHitRange（BUG-773 句首标点补偿：起点右移 + 从词首量长度）', () {
    test('句首书名号：呪術廻戦 高亮到词本身，不吞 『、不缺 戦', () {
      // 原始句 = 『呪術廻戦 第1期』…；归一化剥掉句首 『（leadingUnits=1），引擎从
      // 剥离串匹配 呪術廻戦（bestLength=4，全 BMP）。修复前从句首铺 4 = 『呪術廻（错）；
      // 修复后起点右移 1 落到 呪，长度 4 = 呪術廻戦（对）。
      const String sentence = '『呪術廻戦 第1期』『チェンソーマン』';
      final hit = ClipboardPanelController.rootHitRange(
        query: sentence,
        baseStartCp: 0,
        leadingUnits: 1,
        bestLength: 4,
      );
      expect(hit.start, 1); // 跳过句首 『
      expect(hit.length, 4); // 呪術廻戦
      // 码点区间对准的正是被查词。
      final chars = sentence.runes.toList();
      final matched = String.fromCharCodes(
          chars.sublist(hit.start, hit.start + hit.length));
      expect(matched, '呪術廻戦');
    });

    test('无句首标点：leadingUnits=0 时退化为旧语义（零回归）', () {
      final hit = ClipboardPanelController.rootHitRange(
        query: '呪術廻戦は面白い',
        baseStartCp: 0,
        leadingUnits: 0,
        bestLength: 4,
      );
      expect(hit.start, 0);
      expect(hit.length, 4);
    });

    test('点字后缀：baseStartCp 为句中码点下标，起点叠加', () {
      // 点了句子第 5 个码点起的后缀，后缀本身无句首标点（leadingUnits=0）。
      final hit = ClipboardPanelController.rootHitRange(
        query: '第1期』の話',
        baseStartCp: 5,
        leadingUnits: 0,
        bestLength: 3, // 第1期
      );
      expect(hit.start, 5);
      expect(hit.length, 3);
    });

    test('代理对（罕见汉字）长度折算为码点', () {
      // '𠮟' 2 code units / 1 code point；leadingUnits=1（句首标点 1 unit）。
      final hit = ClipboardPanelController.rootHitRange(
        query: '「𠮟る',
        baseStartCp: 0,
        leadingUnits: 1, // 「
        bestLength: 3, // 𠮟(2) + る(1) = 3 code units
      );
      expect(hit.start, 1); // 跳过 「（1 码点）
      expect(hit.length, 2); // 𠮟る = 2 码点
    });

    test('bestLength 越界/非法 钳位；空串安全', () {
      final over = ClipboardPanelController.rootHitRange(
        query: '『あ',
        baseStartCp: 0,
        leadingUnits: 1,
        bestLength: 99,
      );
      expect(over.start, 1);
      expect(over.length, 1); // 只剩 あ
      expect(
        ClipboardPanelController.rootHitRange(
            query: 'ある', baseStartCp: 0, leadingUnits: 0, bestLength: 0),
        (start: 0, length: 0),
      );
      expect(
        ClipboardPanelController.rootHitRange(
            query: '', baseStartCp: 3, leadingUnits: 0, bestLength: 2),
        (start: 0, length: 0),
      );
    });
  });

  test('面板栏高度与 host.js PANEL_BAR_HEIGHT 一致（跨端几何契约）', () {
    final String hostJs =
        File('assets/popup/global_lookup_host.js').readAsStringSync();
    expect(
      hostJs.contains(
          'var PANEL_BAR_HEIGHT = ${kClipboardPanelBarHeight.toInt()};'),
      isTrue,
      reason: 'Dart 视口计算（height - bar）与 host root shell top 偏移必须同源',
    );
  });

  group('源码接线守卫', () {
    final String controllerSrc =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final String dispatcherSrc =
        File('lib/src/lookup/desktop_lookup_dispatcher.dart')
            .readAsStringSync();

    test('BUG-717：× 关面板不永久暂停，下一条剪贴板复制重开', () {
      // 旧的 paused 门（× 后丢弃非 hotkey 事件、直到 Ctrl+Shift+D 才解除）整条移除：
      // 用户「第一个关掉了第二个就出不来」的根因就是这个门。
      expect(controllerSrc.contains('bool paused'), isFalse,
          reason: 'BUG-717：paused 字段必须移除');
      expect(
        controllerSrc.contains('request.origin != DesktopLookupOrigin.hotkey'),
        isFalse,
        reason: 'BUG-717：不得再有「paused 时丢弃非 hotkey 剪贴板事件」的门',
      );
      // 正向契约：update 见 !_visible 无条件 _showPanel，故关面板（_visible=false）
      // 后下一条剪贴板复制会重开面板。
      final int updAt = controllerSrc.indexOf('Future<void> update(');
      // 前缀匹配：clipboard 真机第 2 轮把这个重开门加固成
      // `if (!_visible || !await _channel.isShowing())`（窗口被系统藏掉也重上屏），
      // 重开机制（!_visible 时 _showPanel）不变，故不锁死到旧的 `) {` 尾。
      final int visAt = controllerSrc.indexOf('if (!_visible', updAt);
      final int showAt =
          controllerSrc.indexOf('await _showPanel(model);', visAt);
      expect(visAt, greaterThan(updAt),
          reason: 'update 必须在 !_visible 时重新显示面板（关掉后重开的机制）');
      expect(showAt, greaterThan(visAt));
    });

    test('hidePanel 只藏窗、不设阻塞标志（关掉后下一条复制照弹）', () {
      final int hideAt = controllerSrc.indexOf('Future<void> hidePanel()');
      expect(hideAt, greaterThanOrEqualTo(0),
          reason: 'BUG-717：hidePanel 无参（不再有 pause 开关）');
      final int end = controllerSrc.indexOf('}', hideAt);
      final String body = controllerSrc.substring(hideAt, end);
      expect(body.contains('_visible = false'), isTrue);
      expect(body.contains('paused'), isFalse, reason: 'hidePanel 不得设任何暂停标志');
    });

    test('九根 DEFERRED 桥经共享权威 handler（红线：不复制）', () {
      expect(
          controllerSrc.contains('maybeHandleOverlayDeferredBridge'), isTrue);
      expect(controllerSrc.contains('resolveBridge: _channel.resolveBridge'),
          isTrue,
          reason: '回传必须走面板自己的 channel，与瞬态窗互不串线');
    });

    test('渲染走 layoutMode panel；透明=整窗 LWA_ALPHA（spec §6 真机修正）', () {
      expect(controllerSrc.contains("layoutMode: 'panel'"), isTrue);
      expect(controllerSrc.contains('setWindowAlpha'), isTrue,
          reason: '真透视=整窗 alpha；acrylic 实测经 windowed WebView2 不透明');
      expect(controllerSrc.contains('cardBgAlpha: 1.0'), isTrue,
          reason: '卡背景恒不透明，避免与整窗 alpha 双重变淡');
      expect(controllerSrc.contains('applyBackdrop'), isFalse,
          reason: 'acrylic backdrop 路线废弃（毛玻璃≠透视），面板不再调用');
    });

    test('update 每次复核 native isShowing（防渲染进被系统藏掉的隐形窗）', () {
      expect(
        controllerSrc.contains('!_visible || !await _channel.isShowing()'),
        isTrue,
        reason: '真机症状「只显示一次」：窗口被藏后 Dart _visible 仍 true，'
            '后续更新全进隐形窗',
      );
    });

    test('dispatcher panel 分区调 ClipboardPanelController.update', () {
      expect(
        dispatcherSrc.contains('ClipboardPanelController.instance.update'),
        isTrue,
      );
    });

    test('释义子查词瞬态窗不带剪贴板横幅（sentence=\'\'，去重）', () {
      // 用户报「查词的时候出现的查词弹窗，上面有个多余的剪切板内容」：释义文字/
      // 内链点击开的瞬态窗是子查词，被点词不在剪贴板整句里，不该重复贴整句横幅
      // （面板背后已显示）。_lookupExternal 必须给 lookupText 传空句，与面板自身
      // 「子卡不带横幅」策略一致。
      final int fnAt = controllerSrc.indexOf('Future<void> _lookupExternal(');
      expect(fnAt, greaterThan(0));
      final int fnEnd = controllerSrc.indexOf('\n  }', fnAt);
      final String body = controllerSrc.substring(fnAt, fnEnd);
      expect(
        body.contains("await lookup(query, '', screenRect)"),
        isTrue,
        reason: '瞬态子查词窗必须传空句（无横幅），不得回退传 _currentSentence',
      );
      expect(
        body.contains('lookup(query, _currentSentence'),
        isFalse,
        reason: '不得把剪贴板整句作为子查词的横幅/上下文重复展示',
      );
    });
  });
}
