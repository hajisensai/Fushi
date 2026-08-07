// BUG-1016 匿名 FTP：ftpLoginCredentials 归一逻辑单测。
// 空/空 → (anonymous, '')；有用户名无密码 → (user, '')；全有 → 原样。
// 消除旧的「testConnection 放行空账密、_connect 硬拒空账密」不一致。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';

void main() {
  group('FtpSyncBackend.ftpLoginCredentials', () {
    test('null/null → anonymous 登录', () {
      final creds = FtpSyncBackend.ftpLoginCredentials(null, null);
      expect(creds.user, 'anonymous');
      expect(creds.pass, '');
    });

    test('空串/空串 → anonymous 登录', () {
      final creds = FtpSyncBackend.ftpLoginCredentials('', '');
      expect(creds.user, 'anonymous');
      expect(creds.pass, '');
    });

    test('有用户名、无密码 → 用户名原样 + 空密码', () {
      final creds = FtpSyncBackend.ftpLoginCredentials('reader', null);
      expect(creds.user, 'reader');
      expect(creds.pass, '');
    });

    test('用户名+密码全有 → 原样透传', () {
      final creds = FtpSyncBackend.ftpLoginCredentials('reader', 'pw');
      expect(creds.user, 'reader');
      expect(creds.pass, 'pw');
    });
  });
}
