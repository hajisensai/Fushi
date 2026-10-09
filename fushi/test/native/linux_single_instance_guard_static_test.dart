import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Linux runner 单实例 + 外部打开转交的源码守卫（Windows 对应物见
/// `windows_single_instance_guard_static_test.dart`）。
///
/// Flutter 模板的 GTK runner 以 `G_APPLICATION_NON_UNIQUE` 注册：每次「用 Fushi 打开」
/// 文件 / `fushi://` 深链都会再起一个完整实例（第二个 Dart isolate、第二份数据库
/// 连接），而不是把参数交给已开着的那个。修复后 runner 以
/// `G_APPLICATION_HANDLES_COMMAND_LINE` 注册到会话 D-Bus，第二次启动的 argv 经
/// `command-line` 落到首实例，再走与 Windows 同一条 `app.fushi/external_video` 通道。
///
/// 这些结构任何一处被删都只会静默退化（不会编译失败），所以逐条钉住。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('runner 以单实例 + HANDLES_COMMAND_LINE 注册，测试 runner 豁免', () {
    final String app = read('linux/runner/my_application.cc');
    expect(
      app,
      contains('GApplicationFlags flags = G_APPLICATION_HANDLES_COMMAND_LINE;'),
    );
    expect(
      app,
      isNot(
        contains(
          '"flags",\n                                     '
          'G_APPLICATION_NON_UNIQUE, nullptr',
        ),
      ),
      reason: '无条件 NON_UNIQUE 就是没有单实例',
    );
    expect(
      app,
      contains('g_getenv("FUSHI_TEST_HIDDEN")'),
      reason: '集成测试 runner 必须以首实例语义启动（同 Windows IsTestRunnerMode）',
    );
  });

  test('首实例经 command-line 转交外部参数并前置窗口', () {
    final String app = read('linux/runner/my_application.cc');
    expect(
      app,
      contains(
        'G_APPLICATION_CLASS(klass)->command_line = '
        'my_application_command_line;',
      ),
    );
    expect(app, contains('"app.fushi/external_video"'));
    expect(app, contains('"openExternalVideo"'));
    expect(app, contains('gtk_window_present(self->window);'));
    expect(
      app,
      contains(
        'if (self->window != nullptr) {\n'
        '    present_main_window(self);\n'
        '    return;\n'
        '  }',
      ),
      reason: 'D-Bus 再次 activate 不得起第二个窗口 / 第二个 Dart isolate',
    );
  });

  // BUG-3087：首实例退出链里（窗口已隐藏、进程还活几秒、D-Bus 名仍占着）二次启动
  // 不能交给它——参数随将死进程丢失，隐藏的窗口还会被 present 回来。
  test('首实例正在退出：拒收命令行，二次启动方等名字让出后按首实例启动', () {
    final String app = read('linux/runner/my_application.cc');
    final String header = read('linux/runner/my_application.h');
    final String main = read('linux/runner/main.cc');

    expect(header, contains('constexpr int kFushiPrimaryExitingStatus = 75;'));
    expect(app, contains('kAppExitingMethod = "appExiting"'));
    expect(app, contains('self->exiting = TRUE;'));

    final String commandLine = _functionBody(
      app,
      'static int my_application_command_line(',
    );
    final int exitingGuard = commandLine.indexOf(
      'if (self->exiting) {\n    return kFushiPrimaryExitingStatus;\n  }',
    );
    expect(exitingGuard, isNonNegative, reason: '退出中必须拒收');
    expect(
      exitingGuard,
      lessThan(commandLine.indexOf('fushi_first_external_arg(')),
      reason: '拒收必须在转交参数之前',
    );
    expect(
      commandLine,
      isNot(contains('gtk_window_present(')),
      reason: '前置一律走 present_main_window（退出中 / 首帧前不前置）',
    );

    final String present = _functionBody(
      app,
      'static void present_main_window(',
    );
    expect(present, contains('self->exiting'));
    expect(present, contains('!self->first_frame_shown'));

    // 二次启动方：拿到「正在退出」→ 等名字让出（有上界）→ 用同一份 argv 再跑一次。
    expect(main, contains('status == kFushiPrimaryExitingStatus'));
    expect(main, contains('!my_application_became_primary(app)'));
    final int wait = main.indexOf('fushi_wait_for_bus_name_released(');
    expect(wait, isNonNegative);
    expect(
      main.indexOf('return RunApplication(argc, argv,', wait),
      isNonNegative,
      reason: '等到名字让出后必须再按首实例启动一次',
    );
    expect(main, contains('kPreviousInstanceWaitMs = 10000'));
  });

  // BUG-3089：Dart 处理器注册前到达的转交参数要排队，ready 后按序冲出；首帧前不
  // present（否则显示一块黑窗）。
  test('转交参数在 Dart 就绪前排队，ready 后冲出；首帧前不前置', () {
    final String app = read('linux/runner/my_application.cc');
    expect(app, contains('kExternalOpenReadyMethod = "externalOpenReady"'));
    expect(
      app,
      contains(
        'fl_method_channel_set_method_call_handler(\n'
        '      self->external_video_channel, external_video_method_cb',
      ),
    );
    final String deliver = _functionBody(
      app,
      'static void deliver_external_arg(',
    );
    expect(
      deliver,
      contains(
        'if (!self->external_open_ready) {\n'
        '    g_ptr_array_add(self->pending_external_args',
      ),
    );
    final String handler = _functionBody(
      app,
      'static void external_video_method_cb(',
    );
    expect(handler, contains('self->external_open_ready = TRUE;'));
    expect(handler, contains('send_external_arg(self'));
    expect(
      handler,
      contains('g_ptr_array_set_size(self->pending_external_args, 0);'),
    );
    expect(
      _functionBody(app, 'static void first_frame_cb('),
      contains('self->first_frame_shown = TRUE;'),
    );
    final String commandLine = _functionBody(
      app,
      'static int my_application_command_line(',
    );
    expect(commandLine, contains('deliver_external_arg(self, external);'));
    expect(commandLine, isNot(contains('fl_method_channel_invoke_method(')));
  });

  test('Dart 侧：处理器注册后发 ready，退出链在隐藏窗口前发 exiting', () {
    final String dartMain = read('lib/main.dart');
    final int handler = dartMain.indexOf(
      '_externalVideoChannel.setMethodCallHandler(_handleExternalVideoChannel);',
    );
    final int ready = dartMain.indexOf(
      'LinuxExternalOpenChannel.notifyHandlerReady(_externalVideoChannel)',
    );
    expect(handler, isNonNegative);
    expect(ready, greaterThan(handler));

    final int exitStart = dartMain.indexOf(
      'Future<void> _flushAndExitForWindowClose() async {',
    );
    final int exiting = dartMain.indexOf(
      'await LinuxExternalOpenChannel.notifyExiting(_externalVideoChannel);',
      exitStart,
    );
    final int hide = dartMain.indexOf('windowManager.hide()', exitStart);
    expect(exitStart, isNonNegative);
    expect(exiting, isNonNegative);
    expect(exiting, lessThan(hide), reason: '先进入 exiting 再隐藏窗口');
  });

  test('转交参数按发起进程的工作目录解析、file:// URI 转本地路径', () {
    final String handoff = read('linux/runner/external_open_handoff.cc');
    expect(
      handoff,
      contains('g_application_command_line_create_file_for_arg(cmdline, arg)'),
    );
    expect(handoff, contains('g_ascii_strcasecmp(scheme, "file")'));
  });

  test('数据迁移重启（--fushi-restarted）先等旧实例让出 D-Bus 名', () {
    final String main = read('linux/runner/main.cc');
    final String handoff = read('linux/runner/external_open_handoff.cc');
    final int wait = main.indexOf('fushi_wait_for_previous_instance_exit(');
    final int run = main.indexOf('RunApplication(argc, argv,', wait);
    expect(wait, isNonNegative);
    expect(main, contains('g_application_run(application, argc, argv)'));
    expect(run, isNonNegative, reason: '必须在注册（g_application_run）之前等');
    expect(handoff, contains('"--fushi-restarted"'));
    expect(handoff, contains('"NameHasOwner"'));
  });

  test('Dart 侧在 Linux 也注册 external_video 处理器', () {
    final String dartMain = read('lib/main.dart');
    expect(
      dartMain,
      contains(
        'if (Platform.isWindows || Platform.isLinux) {\n'
        '      _externalVideoChannel.setMethodCallHandler('
        '_handleExternalVideoChannel);',
      ),
    );
  });

  test('重启标志与 Dart 侧常量一致', () {
    expect(
      read('lib/src/platform/desktop/desktop_lifecycle_service.dart'),
      contains("restartMarkerArg = '--fushi-restarted';"),
    );
  });
}

/// 从 [source] 里取出以 [signature] 开头的 C/C++ 函数体（按花括号配平）。
String _functionBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final int open = source.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  fail('函数体未闭合：$signature');
}
