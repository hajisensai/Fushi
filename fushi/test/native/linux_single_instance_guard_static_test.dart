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
        '    gtk_window_present(self->window);\n'
        '    return;\n'
        '  }',
      ),
      reason: 'D-Bus 再次 activate 不得起第二个窗口 / 第二个 Dart isolate',
    );
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
    final int run = main.indexOf('g_application_run(');
    expect(wait, isNonNegative);
    expect(wait, lessThan(run), reason: '必须在注册（g_application_run）之前等');
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
