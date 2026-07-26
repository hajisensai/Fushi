import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/magpie_scaling_channel.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';

/// Magpie 缩放状态监听的源码守卫。
///
/// native 侧只在 Windows 运行且需要真实的 Magpie 进程广播，CI（Linux）和普通单测宿主
/// 都进不去真实路径，所以在「最强可落地层」= 源码文本上锁死修复结构：channel 名、
/// 广播消息名、UIPI 放行、以及最容易被「简化」掉的
/// `wParam==0 && lParam!=0 仍算缩放中` 那条语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter test 的 cwd 是包根（hibiki/），用相对路径解析，Linux CI 同样可跑。
  final File cpp = File('windows/runner/flutter_window.cpp');
  final File header = File('windows/runner/flutter_window.h');
  final File dartChannel = File('lib/src/mining/magpie_scaling_channel.dart');

  late String source;
  late String headerSource;
  late String dartSource;

  setUpAll(() {
    expect(cpp.existsSync(), isTrue,
        reason: '找不到 ${cpp.path}（cwd=${Directory.current.path}）');
    expect(header.existsSync(), isTrue,
        reason: '找不到 ${header.path}（cwd=${Directory.current.path}）');
    expect(dartChannel.existsSync(), isTrue,
        reason: '找不到 ${dartChannel.path}（cwd=${Directory.current.path}）');
    source = cpp.readAsStringSync();
    headerSource = header.readAsStringSync();
    dartSource = dartChannel.readAsStringSync();
  });

  group('flutter_window.cpp Magpie 监听结构', () {
    test('注册了 Magpie 的广播消息名', () {
      expect(source.contains('MagpieScalingChanged'), isTrue,
          reason: '必须 RegisterWindowMessageW(L"MagpieScalingChanged")');
      expect(source.contains('RegisterWindowMessageW(L"MagpieScalingChanged")'),
          isTrue,
          reason: '广播消息号必须来自 RegisterWindowMessageW，不能写死常量');
    });

    test('对该消息放行 UIPI 消息过滤器', () {
      expect(source.contains('ChangeWindowMessageFilterEx'), isTrue,
          reason:
              '跨完整性级别收广播必须 ChangeWindowMessageFilterEx(..., MSGFLT_ALLOW, nullptr)');
      expect(source.contains('MSGFLT_ALLOW'), isTrue);
    });

    test('channel 名与 Dart 侧一致（两侧都扫，改一边就红）', () {
      // 这条以前只扫 native：只改 Dart 侧字面量的话，channel 名对不上、事件永远收
      // 不到，而测试全绿。两侧都断言才叫「守卫」。
      const String channelName = 'app.hibiki.reader/magpie';
      const String methodName = 'onScalingChanged';
      expect(source.contains(channelName), isTrue);
      expect(source.contains(methodName), isTrue);
      expect(dartSource.contains("MethodChannel('$channelName')"), isTrue,
          reason: 'Dart 侧 channel 名必须与 native 逐字节一致');
      expect(dartSource.contains("call.method != '$methodName'"), isTrue,
          reason: 'Dart 侧方法名必须与 native InvokeMethod 逐字节一致');
      // 广播消息名同理：native 的 RegisterWindowMessageW 与 Dart 侧的常量必须同源。
      expect(kMagpieScalingChangedMessage, 'MagpieScalingChanged');
      expect(
          source.contains(
              'RegisterWindowMessageW(L"$kMagpieScalingChangedMessage")'),
          isTrue);
    });

    test('退出期不许 use-after-free：channel 与引擎都要判空', () {
      final int idx =
          source.indexOf('void FlutterWindow::NotifyMagpieScalingChanged(');
      expect(idx, greaterThan(0));
      final int end = source.indexOf('InvokeMethod(', idx);
      expect(end, greaterThan(idx));
      expect(
        source
            .substring(idx, end)
            .contains('if (!flutter_controller_ || !magpie_channel_)'),
        isTrue,
        reason: '引擎先被拆、窗口还在收广播时，只判 channel 非空会踩已销毁的 messenger',
      );
    });

    test('wParam==0 且 lParam!=0 仍算缩放中（只是源窗口转后台）', () {
      // 载荷表达式本身是根因所在：把它简化成 `wparam != 0` 就会把「源窗口转后台」
      // 误判成「缩放结束」。
      expect(source.contains('(wparam == 0) ? (lparam != 0) : true'), isTrue,
          reason: 'scaling 判定必须保留 lParam 区分，不能退化成只看 wParam');
      expect(source.contains('仅源窗口切到后台'), isTrue,
          reason: '语义注释锚点丢失说明这段被重写过，需重新确认 Magpie 契约');
    });

    test('广播不被消费（不 return，落到基类默认处理）', () {
      final int idx =
          source.indexOf('if (magpie_scaling_message_ != 0 && message ==');
      expect(idx, greaterThanOrEqualTo(0), reason: '缺少运行时消息号匹配分支');
      final int braceEnd = source.indexOf('}', idx);
      expect(braceEnd, greaterThan(idx));
      final String branch = source.substring(idx, braceEnd);
      expect(branch.contains('return'), isFalse,
          reason: '系统广播必须透传给基类，不得在此 return 消费');
    });

    test('注册函数在 OnCreate 里被调用，且声明落在 header', () {
      expect(source.contains('  RegisterMagpieChannel();'), isTrue);
      expect(headerSource.contains('void RegisterMagpieChannel();'), isTrue);
      expect(headerSource.contains('magpie_scaling_message_ = 0;'), isTrue,
          reason: '消息号成员必须零初始化，否则未注册时会误匹配');
    });
  });

  group('MagpieScalingChannel Dart 侧解析', () {
    tearDown(MagpieScalingChannel.clearHandler);

    test('onScalingChanged 原样解析 state/handle/scaling', () async {
      MagpieScalingEvent? got;
      MagpieScalingChannel.setHandler((MagpieScalingEvent e) => got = e);
      await MagpieScalingChannel.debugDispatch(const MethodCall(
        'onScalingChanged',
        <Object?, Object?>{'state': 0, 'handle': 1234, 'scaling': true},
      ));
      expect(
          got, const MagpieScalingEvent(state: 0, handle: 1234, scaling: true));
    });

    test('字段缺失取保守缺省，未知方法名忽略', () async {
      MagpieScalingEvent? got;
      MagpieScalingChannel.setHandler((MagpieScalingEvent e) => got = e);
      await MagpieScalingChannel.debugDispatch(
          const MethodCall('onScalingChanged', <Object?, Object?>{}));
      expect(
          got, const MagpieScalingEvent(state: 0, handle: 0, scaling: false));

      got = null;
      await MagpieScalingChannel.debugDispatch(
          const MethodCall('somethingElse', <Object?, Object?>{'state': 1}));
      expect(got, isNull);
    });

    test('clearHandler 后不再派发', () async {
      MagpieScalingEvent? got;
      MagpieScalingChannel.setHandler((MagpieScalingEvent e) => got = e);
      MagpieScalingChannel.clearHandler();
      await MagpieScalingChannel.debugDispatch(const MethodCall(
        'onScalingChanged',
        <Object?, Object?>{'state': 1, 'handle': 7, 'scaling': true},
      ));
      expect(got, isNull);
    });
  });
}
