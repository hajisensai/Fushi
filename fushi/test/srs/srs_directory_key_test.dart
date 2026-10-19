// 复习同步目录身份（srs_directory_key.dart）：拿不到稳定身份时不落成「新目录」。
//
// 修复前 Google Drive / OneDrive / Dropbox 账户还没认出来（currentEmail 为 null）时身份是
// `googleDrive:`，认出来后变成 `googleDrive:<账户>`——同一个物理目录被当成两个目录，第二次重新起步、
// 可能整库重发；两个不同账户都落成 `googleDrive:` 则互相套用进度。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_directory_key.dart';

void main() {
  test('账户型：账户为空 / 只有空白 → null；有账户 → 稳定身份', () {
    expect(srsAccountDirectoryKey('googleDrive', null), isNull);
    expect(srsAccountDirectoryKey('googleDrive', ''), isNull);
    expect(srsAccountDirectoryKey('googleDrive', '  '), isNull);
    expect(
      srsAccountDirectoryKey('googleDrive', 'a@example.com'),
      'googleDrive:a@example.com',
    );
    expect(
      srsAccountDirectoryKey('oneDrive', 'a@example.com'),
      isNot(srsAccountDirectoryKey('googleDrive', 'a@example.com')),
    );
  });

  test('服务器型：地址为空 → null；用户可空', () {
    expect(srsServerDirectoryKey('webDav', null, 'u'), isNull);
    expect(srsServerDirectoryKey('webDav', ' ', 'u'), isNull);
    expect(
      srsServerDirectoryKey('webDav', 'https://dav.example/', 'u'),
      'webDav:https://dav.example/|u',
    );
    expect(srsServerDirectoryKey('ftp', 'h:21', null), 'ftp:h:21|');
  });

  test('host 写入过滤：只认同步根下的复习命名空间', () {
    expect(srsIsHostSrsPath('fushi-data/fushi-srs/p/w#1/cursor'), isTrue);
    expect(srsIsHostSrsPath('fushi-data/TestBook/progress.json'), isFalse);
    expect(srsIsHostSrsPath('fushi-srs/p/w#1/cursor'), isFalse);
    expect(srsIsHostSrsPath('fushi-data/fushi-srs-media/x'), isFalse);
  });
}
