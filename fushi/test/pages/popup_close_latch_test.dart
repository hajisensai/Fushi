import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/popup_channel.dart';

/// BUG-1757：安卓独立查词窗「关不掉」。
///
/// 触发路径是连续查词——关掉一个查词窗、紧接着查下一个词：
///
///   1. `PopupEngineHolder` 是 object 单例，关闭回调 `onFinish` 是它的字段；
///   2. 每个 `PopupDictFlutterActivity` 在 onCreate 里把它指向**自己**的 finish；
///   3. 旧实现的 onDestroy **无条件** `setOnFinish(null)`；
///   4. Android 的生命周期顺序是「新实例 onCreate → 旧实例 onDestroy」，于是旧窗销毁时
///      把新窗刚注册的回调清成 null；
///   5. 新窗调 `finishPopup` → `onFinish?.invoke()` 撞上 null，静默什么都不做；
///   6. 而 Dart 侧 `_close()` 是**先上锁后办事**：`_isClosing = true` 已经置下，它唯一的
///      复位点是「宿主推来新词」（didUpdateWidget）。
///
/// 结果：窗口留在屏幕上、外观毫无变化，X / 点外面 / 横滑 / 系统返回全部撞上 `_close()`
/// 开头那句 `if (_isClosing) return;` 静默早退 = 用户侧「关不掉」；而弹窗内是活的原生
/// WebView，不受 Flutter 侧任何影响，所以内容还能滚一点 = 用户侧「只能动一点点」。
///
/// 修复两侧都做：
///   * 原生侧注销回调必须比对 owner（消除竞态本身，且 API 上不再存在「无条件清空」）；
///   * `finishPopup` 把「有没有人真的接下这次关闭」回给 Dart，没接就解开闭锁（安全网：
///     将来任何原因导致关闭没发生，都不会再把弹窗锁死）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PopupChannel.finishPopup 的接受语义（BUG-1757 安全网）', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.popup, null);
    });

    void mockPopup(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.popup, handler);
    }

    test('原生确认接下关闭 → true', () async {
      mockPopup((MethodCall call) async {
        expect(call.method, 'finishPopup');
        return true;
      });
      expect(await PopupChannel.instance.finishPopup(), isTrue);
    });

    test('原生侧没人接（回调已被销毁中的旧 Activity 清掉）→ false', () async {
      mockPopup((MethodCall call) async => false);
      expect(await PopupChannel.instance.finishPopup(), isFalse,
          reason: '这正是 BUG-1757 的现场：窗口不会关，调用方必须解开闭锁');
    });

    test('原生返回 null（旧协议 / 未实现）→ false，宁可解锁也不锁死', () async {
      mockPopup((MethodCall call) async => null);
      expect(await PopupChannel.instance.finishPopup(), isFalse);
    });

    test('通道抛异常 → false（异常被吞，但绝不能报告成功）', () async {
      mockPopup((MethodCall call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await PopupChannel.instance.finishPopup(), isFalse);
    });
  });

  group('源码守卫：关闭闭锁不得永久锁死', () {
    const String pagePath =
        'lib/src/pages/implementations/popup_dictionary_page.dart';

    String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

    test('_close 在关闭未被接受时复位 _isClosing', () {
      final String src = flat(File(pagePath).readAsStringSync());
      // literal: 'final bool accepted = await PopupChannel.instance.finishPopup();'
      expect(
        src.contains(
            'final bool accepted = await PopupChannel.instance.finishPopup();'),
        isTrue,
        reason: '必须拿到原生侧的接受结果，而不是 fire-and-forget',
      );
      // literal: 'if (!accepted && mounted) { _isClosing = false; }'
      expect(
        src.contains('if (!accepted && mounted) { _isClosing = false; }'),
        isTrue,
        reason: '没人接下关闭就必须解开 _isClosing，否则所有关闭入口永久静默早退',
      );
    });
  });

  group('源码守卫：原生侧关闭回调必须按 owner 注销', () {
    const String androidRoot = 'android/app/src/main/java/app/fushi/reader';

    /// 先剥注释再扫：这些文件的注释里**故意**引用了旧写法（`setOnFinish(null)`）作为
    /// 历史说明，扫原文会让「不得保留无条件清空入口」这条守卫被文档自己打红。
    String stripComments(String s) => s
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
        .replaceAll(RegExp(r'//[^\n]*'), ' ');

    String read(String relative) =>
        stripComments(File('$androidRoot/$relative').readAsStringSync());

    String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

    test('PopupEngineHolder 注销时比对 owner，且不存在无条件清空入口', () {
      final String src = flat(read('PopupEngineHolder.kt'));
      // literal: 'fun setOnFinish(owner: Any, callback: () -> Unit)'
      expect(
        src.contains('fun setOnFinish(owner: Any, callback: () -> Unit)'),
        isTrue,
        reason: '注册必须带 owner，否则无从判断该不该注销',
      );
      // literal: 'if (finishHandler?.owner !== owner) return'
      expect(
        src.contains('if (finishHandler?.owner !== owner) return'),
        isTrue,
        reason: 'BUG-1757 的根因：旧 Activity 的 onDestroy 晚于新 Activity 的 '
            'onCreate，注销必须先确认当前回调确实属于自己',
      );
      // 「无条件清空」入口存在多久，这个竞态就存在多久 —— 不允许它回来。
      expect(
        src.contains('setOnFinish(null)'),
        isFalse,
        reason: '不得保留可以清掉别人回调的入口',
      );
    });

    test('finishPopup 把「有没有人接」回给 Dart', () {
      final String src = flat(read('PopupEngineHolder.kt'));
      // literal: 'result.success(handler != null)'
      expect(src.contains('result.success(handler != null)'), isTrue,
          reason: 'Dart 侧的解锁判据来自这里；回 null 会让安全网失效');
    });

    test('PopupDictFlutterActivity 用 clearOnFinish(this) 注销自己那次注册', () {
      final String src = flat(read('PopupDictFlutterActivity.kt'));
      // literal: 'PopupEngineHolder.setOnFinish(this) { runOnUiThread { finish() } }'
      expect(
        src.contains(
            'PopupEngineHolder.setOnFinish(this) { runOnUiThread { finish() } }'),
        isTrue,
        reason: '注册时把自己作为 owner 交出去',
      );
      // literal: 'PopupEngineHolder.clearOnFinish(this)'
      expect(src.contains('PopupEngineHolder.clearOnFinish(this)'), isTrue,
          reason: 'onDestroy 只注销自己那次注册');
    });
  });
}
