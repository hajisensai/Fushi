// 反馈 / 闪退报告日志脱敏（redactFeedbackLog）与汇总点 collectFeedbackLogText 的契约。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_log_redaction.dart';
import 'package:fushi/src/utils/misc/debug_log_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('家目录', () {
    test('Windows 反斜杠 / 正斜杠 / JSON 转义', () {
      expect(
        redactFeedbackLog(r'open C:\Users\alice\Books\a.epub failed'),
        r'open ~\Books\a.epub failed',
      );
      expect(
        redactFeedbackLog('open c:/users/alice/Books/a.epub'),
        'open ~/Books/a.epub',
      );
      expect(
        redactFeedbackLog(r'{"path":"C:\\Users\\alice\\x.db"}'),
        r'{"path":"~\\x.db"}',
      );
    });

    test('Windows 带空格的用户名', () {
      expect(
        redactFeedbackLog(r'at C:\Users\John Doe\AppData\x.dll'),
        r'at ~\AppData\x.dll',
      );
      // 路径后面接正文：不把正文吞掉。
      expect(redactFeedbackLog(r'cwd C:\Users\bob is gone'), 'cwd ~ is gone');
    });

    test('macOS / Linux / file URL', () {
      expect(
        redactFeedbackLog('read /Users/alice/Library/x'),
        'read ~/Library/x',
      );
      expect(redactFeedbackLog('read /home/bob/.config/x'), 'read ~/.config/x');
      expect(redactFeedbackLog('file:///Users/alice/a.mp4'), 'file://~/a.mp4');
    });

    test('URL 路径里的 /Users/ 不当家目录；Android 存储路径保留', () {
      const String jf = 'GET http://nas:8096/Users/abc123/Items failed';
      expect(redactFeedbackLog(jf), jf);
      const String android = '/storage/emulated/0/Books/a.epub';
      expect(redactFeedbackLog(android), android);
    });
  });

  group('URL 查询参数', () {
    test('每个凭据参数名都遮值、保留参数名与其余参数', () {
      for (final String name in kFeedbackSecretQueryParams) {
        expect(
          redactFeedbackLog('https://h/p?a=1&$name=SECRETv4l&b=2'),
          'https://h/p?a=1&$name=***&b=2',
          reason: name,
        );
        expect(
          redactFeedbackLog('https://h/p?$name=SECRETv4l'),
          'https://h/p?$name=***',
          reason: name,
        );
      }
    });

    test('参数名大小写不敏感；名字只是前缀 / 后缀的不遮', () {
      expect(
        redactFeedbackLog('https://h/v?API_KEY=abc&x-emby-token=def'),
        'https://h/v?API_KEY=***&x-emby-token=***',
      );
      const String keep = 'https://h/v?keyword=abc&monkey=1&tokens=2';
      expect(redactFeedbackLog(keep), keep);
    });

    test('URL userinfo 凭据', () {
      expect(
        redactFeedbackLog('webdav https://bob:hunter2@dav.example/x'),
        'webdav https://***:***@dav.example/x',
      );
    });
  });

  group('请求头与令牌', () {
    test('Authorization / Cookie 值遮到行尾，下一行不受影响', () {
      expect(
        redactFeedbackLog('Authorization: Bearer abc.def\nnext line'),
        'Authorization: ***\nnext line',
      );
      expect(redactFeedbackLog('cookie: sid=1; uid=2'), 'cookie: ***');
      expect(redactFeedbackLog('Set-Cookie: sid=1'), 'Set-Cookie: ***');
      expect(
        redactFeedbackLog('{"Authorization": "Basic Zm9vOmJhcg=="}'),
        '{"Authorization": ***',
      );
      expect(
        redactFeedbackLog(
          'X-Emby-Authorization: MediaBrowser Client="Fushi", Token="t0k"',
        ),
        'X-Emby-Authorization: ***',
      );
      expect(redactFeedbackLog('X-Plex-Token=abc'), 'X-Plex-Token=***');
    });

    test('游离的 Bearer / Basic 令牌', () {
      expect(
        redactFeedbackLog('headers {auth: Bearer eyJhbGciOi.J9x-y_z=}'),
        'headers {auth: Bearer ***}',
      );
      expect(
        redactFeedbackLog('using basic Zm9vOmJhcg== now'),
        'using basic *** now',
      );
    });

    test('提到 authorization / basic 但不是凭据的不遮', () {
      const String s = 'authorization failed (401), fallback to basic auth';
      expect(redactFeedbackLog(s), s);
    });
  });

  group('邮箱', () {
    test('遮整个地址', () {
      expect(
        redactFeedbackLog('login alice.b+x@mail.example.co.jp ok'),
        'login ***@*** ok',
      );
    });

    test('版本号 / 包名带 @ 的不当邮箱', () {
      const String s = 'dep foo@1.2.3 and @scope/pkg';
      expect(redactFeedbackLog(s), s);
    });
  });

  test('排查信息原样保留', () {
    const String s =
        '[2026-11-01 10:00:00] E/reader exception=0xC0000005 '
        'module=fushidicts.dll+0x1234\n#0 main (package:fushi/main.dart:12)';
    expect(redactFeedbackLog(s), s);
  });

  group('collectFeedbackLogText', () {
    late Directory tmp;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmp = Directory.systemTemp.createTempSync('fushi_feedback_redact_');
      await ErrorLogService.instance.init(directoryOverride: tmp);
      await DebugLogService.instance.init();
      await DebugLogService.instance.setEnabled(true);
    });

    tearDown(() async {
      await DebugLogService.instance.setEnabled(false);
      await ErrorLogService.instance.flush();
      tmp.deleteSync(recursive: true);
    });

    test('出口统一脱敏', () {
      ErrorLogService.instance.log(
        'feedback.redact_probe',
        StateError(r'open C:\Users\alice\x.db token=1 ?api_key=SEKRET'),
        StackTrace.empty,
      );
      final String log = collectFeedbackLogText(includeDebugLog: false);
      expect(log, contains('feedback.redact_probe'));
      expect(log, contains(r'~\x.db'));
      expect(log, contains('?api_key=***'));
      expect(log, isNot(contains('alice')));
      expect(log, isNot(contains('SEKRET')));
    });

    test('includeDebugLog: false 时不带调试日志（即使开着）', () {
      debugPrint('debug-probe-line bob@example.com');
      final String withDebug = collectFeedbackLogText(includeDebugLog: true);
      expect(withDebug, contains('==== debug log ===='));
      expect(withDebug, contains('debug-probe-line ***@***'));
      expect(withDebug, isNot(contains('bob@example.com')));

      final String crash = collectFeedbackLogText(includeDebugLog: false);
      expect(crash, contains('==== error log ===='));
      expect(crash, isNot(contains('==== debug log ====')));
      expect(crash, isNot(contains('debug-probe-line')));
    });
  });
}
