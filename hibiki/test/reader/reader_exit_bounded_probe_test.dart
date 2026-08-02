import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_exit_flush.dart';

import '../helpers/source_guard.dart';

/// TODO-2495：阅读器退出链「实时探针限时、落库不限时且永不跳过」的契约。
///
/// 背景（为什么这条契约值得钉住）：阅读器返回是一条全程 await 的串行链，
/// `nav.pop()` 排在最末，外层 `_popInProgress` 单飞门在链跑完前一直顶着，期间每一次
/// 返回都被静默丢弃、无任何 UI 反馈；门只在 `onWillPop()` 返回时由 `finally` 复位，
/// 所以链里任何一段挂死 = 返回键**永久**失效（BUG-1273 那次至少能等播放器停下自愈）。
/// 链上唯一没有延迟上界的一段是向 WebView 实时读进度的 `evaluateJavascript`——同一个
/// 探针在进程退出路径 (`_flushAllForProcessExit`) 被明确注释成「会挂死整个退出」而
/// 刻意不调用，返回路径却一直裸 await 它。
///
/// 下面第一组是**行为**测试（真跑 [flushWithBoundedProbe] 的控制流），第二组是
/// **源码**守卫（钉住调用点确实走了这个契约）——行为变异配行为守卫、源码变异配
/// 源码守卫，两组不互相顶替。
void main() {
  group('flushWithBoundedProbe 行为契约', () {
    test('探针挂死时：不超过预算就放行，且落库照常执行（进度不丢）', () async {
      final Completer<void> hungProbe = Completer<void>();
      addTearDown(() {
        if (!hungProbe.isCompleted) hungProbe.complete();
      });

      bool persisted = false;
      final List<Object> failures = <Object>[];
      final Stopwatch clock = Stopwatch()..start();

      // 预算取小值只为让测试快：契约与具体数值无关，生产值是
      // kReaderExitProbeBudget。
      final bool probed = await flushWithBoundedProbe(
        probe: () => hungProbe.future,
        persist: () async {
          persisted = true;
        },
        probeBudget: const Duration(milliseconds: 80),
        onProbeFailure: (Object error, StackTrace stack) => failures.add(error),
      ).timeout(
        // 这层 timeout 是**测试脚手架**，不是被测契约的一部分：没有它，一旦
        // `.timeout` 被拿掉，本用例会挂到整个 suite 超时而不是给出可读的红。
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'flushWithBoundedProbe 在探针挂死时没有返回——探针的延迟上界丢了，'
          '退出链会被无限期顶住（单飞门永久顶死 = 返回键彻底失效）',
        ),
      );
      clock.stop();

      expect(persisted, isTrue,
          reason: '探针超时绝不能跳过落库：位置/统计写在 persist 里，跳过就是用户可感知的进度丢失');
      expect(probed, isFalse, reason: '探针未在预算内完成时必须如实返回 false（本次落的是缓存锚）');
      expect(failures, hasLength(1),
          reason: '降级必须上报，不能静默吞掉——超时被吞就没人知道实时锚退化成了缓存锚');
      expect(failures.single, isA<TimeoutException>());
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '放行时机必须由预算决定，而不是由探针决定');

      // 探针事后完成不得让已经返回的 future 再出岔子（超时不取消探针，只是不再等它）。
      hungProbe.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('探针抛异常时：落库照常执行（这是旧形态真正丢进度丢统计的那条路）', () async {
      bool persisted = false;
      final List<Object> failures = <Object>[];

      final bool probed = await flushWithBoundedProbe(
        probe: () async => throw StateError('probe blew up'),
        persist: () async {
          persisted = true;
        },
        probeBudget: const Duration(seconds: 5),
        onProbeFailure: (Object error, StackTrace stack) => failures.add(error),
      );

      expect(persisted, isTrue,
          reason: '探针抛错时落库必须照常跑完。旧形态里这个异常会沿 _syncAndFlushPosition → '
              'onSourcePagePop 逃逸，把 _flushPosition() 和其后的 _flushReadingStats() '
              '一起跳过——进度与统计同时丢');
      expect(probed, isFalse);
      expect(failures.single, isA<StateError>());
    });

    test('探针在预算内完成时：先探针后落库，且如实返回 true（BUG-203 的实时锚不能被换掉）', () async {
      final List<String> order = <String>[];
      final List<Object> failures = <Object>[];

      final bool probed = await flushWithBoundedProbe(
        probe: () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          order.add('probe');
        },
        persist: () async {
          order.add('persist');
        },
        probeBudget: const Duration(seconds: 5),
        onProbeFailure: (Object error, StackTrace stack) => failures.add(error),
      );

      expect(order, <String>['probe', 'persist'],
          reason: '实时探针必须在落库之前完成，否则落的还是陈旧缓存锚——正是 BUG-203 '
              '「退出重进落在前面好几页」的成因');
      expect(probed, isTrue);
      expect(failures, isEmpty, reason: '正常路径不得上报失败');
    });

    test('落库自身的耗时不受预算约束（Drift 写慢不等于可以不写）', () async {
      bool persisted = false;

      final bool probed = await flushWithBoundedProbe(
        probe: () async {},
        persist: () async {
          // 明显长于预算：落库是耐久步骤，不许被探针预算连坐掐掉。
          await Future<void>.delayed(const Duration(milliseconds: 120));
          persisted = true;
        },
        probeBudget: const Duration(milliseconds: 10),
        onProbeFailure: (Object error, StackTrace stack) =>
            fail('落库耗时不该被记成探针失败：$error'),
      );

      expect(persisted, isTrue);
      expect(probed, isTrue);
    });

    test('生产预算是个正数且量级合理', () {
      expect(kReaderExitProbeBudget, greaterThan(Duration.zero));
      expect(
          kReaderExitProbeBudget, lessThanOrEqualTo(const Duration(seconds: 1)),
          reason: '预算一旦放到秒级，返回在用户眼里就已经是「按了没反应」了');
    });
  });

  group('退出链源码守卫', () {
    String read(String path) => File(path).readAsStringSync();

    test('_syncAndFlushPosition 必须走限时探针契约，不得裸 await 探针', () {
      const String path =
          'lib/src/pages/implementations/reader_hibiki/navigation.part.dart';
      final String source = maskComments(read(path));
      final int start = source.indexOf('Future<void> _syncAndFlushPosition()');
      expect(start, isNonNegative, reason: '找不到 _syncAndFlushPosition');
      // 方法体内含箭头函数（onProbeFailure），用 balancedBlockFrom 从声明处配对
      // 花括号，切的就是整段方法体。
      final String body =
          balancedBlockFrom(source, start, what: '_syncAndFlushPosition 方法体');

      expect(body, contains('flushWithBoundedProbe('),
          reason: '退出/生命周期 flush 必须经 flushWithBoundedProbe 给 WebView 探针加上'
              '延迟上界；退回裸串行 await 就会重现「按返回毫无反应」（TODO-2495）');
      expect(body, contains('probeBudget: kReaderExitProbeBudget'),
          reason: '预算必须用共享常量，避免各调用点各写一个魔数后悄悄放大');
      expect(body, contains('await _syncPositionFromWebViewProgress()'),
          reason: 'WebView 实时探针本身不能被删——限时是给它加上界，不是不读它');
      expect(body.indexOf('probe:'), lessThan(body.indexOf('persist:')),
          reason: '探针必须挂在 probe 槽、落库必须挂在 persist 槽；两者对调等于给落库'
              '加了上界、给探针去了上界，恰好把契约反过来');
      expect(
          body.indexOf('persist:'), lessThan(body.indexOf('_flushPosition()')),
          reason: '_flushPosition 是耐久步骤，必须落在 persist 槽内而不是探针槽内');
    });

    test('flushWithBoundedProbe 自身必须真的有上界，且落库在 try 之外', () {
      const String path = 'lib/src/reader/reader_exit_flush.dart';
      final String source = maskComments(read(path));
      final int start = source.indexOf('Future<bool> flushWithBoundedProbe(');
      expect(start, isNonNegative);
      // 该函数是**具名参数**签名，声明之后的第一个 `{` 是参数列表的花括号而不是
      // 方法体——直接 balancedBlockFrom(start) 会切出参数列表，让下面的断言拿一段
      // 根本不含实现的文本去比对（一次假红，也可能反过来变成假绿）。把配对起点推到
      // `) async {` 之后，锚的才是真方法体。
      final int bodyBrace = source.indexOf(') async {', start);
      expect(bodyBrace, isNonNegative,
          reason: '找不到 flushWithBoundedProbe 的方法体起点');
      final String body = balancedBlockFrom(source, start,
          openSearchFrom: bodyBrace, what: 'flushWithBoundedProbe 方法体');

      expect(body, contains('.timeout(probeBudget)'),
          reason: '探针必须真的被 probeBudget 限时——去掉它，整个契约只剩注释');
      expect(body.indexOf('await persist()'),
          greaterThan(body.indexOf('} catch (error, stack) {')),
          reason: '落库必须排在 catch 之后（无条件执行），不能待在 try 里被探针异常带走');
    });

    test('进程退出 flush 仍不得触碰 WebView 探针', () {
      const String path =
          'lib/src/pages/implementations/reader_hibiki/navigation.part.dart';
      final String source = maskComments(read(path));
      final int start =
          source.indexOf('Future<void> _flushAllForProcessExit()');
      expect(start, isNonNegative);
      final String body =
          balancedBlockFrom(source, start, what: '_flushAllForProcessExit 方法体');

      // 禁止型断言用 containsIdentifier：裸 contains 两个方向都会错——注释里提一句
      // 这个名字就假红，`_syncPositionFromWebViewProgressV2` 这类更长标识符又会被
      // 子串误命中。
      expect(
          containsIdentifier(body, '_syncPositionFromWebViewProgress'), isFalse,
          reason: '进程退出期 WebView 正在拆除，对它 evaluateJavascript 会挂死整个退出；'
              '这条路径只能落缓存锚（限时探针也救不了它——退出不能再等一个预算）');
      expect(body, contains('await _flushPosition()'), reason: '进程退出仍必须把缓存锚写穿');
    });
  });
}
