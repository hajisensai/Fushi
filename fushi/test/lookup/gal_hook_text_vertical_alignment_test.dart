// BUG-1890：galgame 台词浮窗**垂直**对齐偏好（'center' / 'top'）。
//
// 修前：native 侧已经有 DWRITE_PARAGRAPH_ALIGNMENT_NEAR（顶对齐）这条路，但只在文字
// **溢出**窗口时才走（BUG-1095 的设计：溢出才顶对齐，保住阅读顺序）；放得下就强制
// 垂直居中，用户无从选择。长短句交替时台词就在窗口里上下跳。
//
// 设置页那个「文字对齐」只有水平的居中 / 左对齐两档，垂直方向没有任何入口。
//
// 三层断言：偏好白名单收敛（真 DB）、通道 String→int 编码、native 消费点源码守卫。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('偏好层：白名单二值收敛（真 DB）', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('默认垂直居中（老用户升级后逐像素不变）', () {
      expect(repo.galHookTextVerticalAlignment, 'center');
    });

    test('写 top 读回 top', () async {
      await repo.setGalHookTextVerticalAlignment('top');
      expect(repo.galHookTextVerticalAlignment, 'top');
    });

    test('写入端白名单：非法值一律落回 center', () async {
      await repo.setGalHookTextVerticalAlignment('top');
      await repo.setGalHookTextVerticalAlignment('bottom');
      expect(repo.galHookTextVerticalAlignment, 'center');
      await repo.setGalHookTextVerticalAlignment('TOP');
      expect(
        repo.galHookTextVerticalAlignment,
        'center',
        reason: '大小写不同的值不是合法值，不做模糊匹配',
      );
    });

    test('与水平对齐互不干扰（两个正交的轴，不是三选一）', () async {
      await repo.setGalHookTextVerticalAlignment('top');
      await repo.setGalHookTextAlignment('left');
      expect(repo.galHookTextVerticalAlignment, 'top');
      expect(repo.galHookTextAlignment, 'left');
      await repo.setGalHookTextAlignment('center');
      expect(
        repo.galHookTextVerticalAlignment,
        'top',
        reason: '改水平对齐绝不能把垂直对齐冲掉',
      );
    });
  });

  group('通道层：String -> int 编码', () {
    const String channelName = 'app.fushi.reader/gal_hook_text';
    const MethodChannel channel = MethodChannel(channelName);
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      GalHookTextOverlayChannel.platformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return true;
      });
    });

    tearDown(() {
      GalHookTextOverlayChannel.platformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Map<Object?, Object?> lastArgs() =>
        calls.last.arguments as Map<Object?, Object?>;

    test('show：top -> 1、center -> 0、非法 -> 0', () async {
      await GalHookTextOverlayChannel.show(verticalAlignment: 'top');
      expect(lastArgs()['verticalAlignment'], 1);

      await GalHookTextOverlayChannel.show(verticalAlignment: 'center');
      expect(lastArgs()['verticalAlignment'], 0);

      await GalHookTextOverlayChannel.show(verticalAlignment: 'bottom');
      expect(lastArgs()['verticalAlignment'], 0,
          reason: '非法值必须落回老行为，绝不透传给 native');
    });

    test('show 默认不带偏好时 = 0（老 payload 行为）', () async {
      await GalHookTextOverlayChannel.show();
      expect(lastArgs()['verticalAlignment'], 0);
    });

    test('updateStyle：同样编码，且与水平对齐各占一个键', () async {
      await GalHookTextOverlayChannel.updateStyle(
        bgColor: 0xE0000000,
        textAlignment: 'left',
        verticalAlignment: 'top',
      );
      final Map<Object?, Object?> args = lastArgs();
      expect(args['verticalAlignment'], 1);
      expect(
        args['textAlignment'],
        1,
        reason: '水平与垂直是两个独立的键，互不覆盖',
      );
    });
  });

  group('native 消费点源码守卫', () {
    final String header =
        File('windows/runner/floating_lyric_window.h').readAsStringSync();
    final String window =
        File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    final String flutterWindow =
        File('windows/runner/flutter_window.cpp').readAsStringSync();

    test('样式结构体有 vertical_alignment 且默认 0', () {
      expect(header.contains('int vertical_alignment = 0;'), isTrue);
    });

    test('通道参数被解析进样式', () {
      expect(
        flutterWindow.contains(
            'IntFromValue(args, "verticalAlignment", style.vertical_alignment)'),
        isTrue,
        reason: '没有这一行，Dart 传的偏好在 native 侧原地蒸发',
      );
    });

    test('每帧覆写处读该偏好：选顶部则恒 NEAR，否则保留溢出判据', () {
      expect(
        window.contains('(style_.vertical_alignment == 1 ||\n'
            '               metrics.height > text_rect_.height)'),
        isTrue,
        reason: '这是真正生效的那处 SetParagraphAlignment（每帧覆写 text_format_ 的初值）；'
            '「用户选了顶部」与「文字溢出」是并联条件，溢出场景行为必须与修前一致',
      );
    });

    test('歌词条（非 hook 模式）不受影响', () {
      expect(
        window.contains('hook_text_mode_ && style_.vertical_alignment == 1'),
        isTrue,
        reason: '有声书歌词条要的是当前行居中，垂直对齐偏好只作用于 hook 台词模式',
      );
    });
  });

  group('设置页入口', () {
    final String schema =
        File('lib/src/settings/settings_schema_game.dart').readAsStringSync();

    test('垂直对齐是独立分段项，不与水平对齐合并成三选一', () {
      expect(
        schema.contains("id: 'game.gal_hook_text_vertical_alignment'"),
        isTrue,
      );
      expect(
        schema.contains("id: 'game.gal_hook_text_alignment'"),
        isTrue,
        reason: '原来的水平对齐项必须还在——两者是正交的轴',
      );
      expect(schema.contains('t.gal_hook_text_vertical_alignment_top'), isTrue);
      expect(
        schema.contains('setGalHookTextVerticalAlignment'),
        isTrue,
      );
    });
  });
}
