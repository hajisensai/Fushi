import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-829 平台分流守卫。
///
/// 硬约束：桌面（含 Linux）严格走 [FilePicker.saveFile]，移动端才用
/// [Share.shareXFiles]。Linux 无 share_plus 注册，桌面分支误调 Share 会崩。本守卫
/// 锁定 `collection_exporter.dart` 里 `Share.` 调用只出现在 `else`（非桌面）分支，
/// `FilePicker.platform.saveFile` 只出现在 `if (_isDesktop)` 分支——回归把它们移出
/// 各自分支即报红。
void main() {
  test('Share.shareXFiles is only reached in the non-desktop branch', () {
    final String src = File('lib/src/utils/misc/collection_exporter.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    // 二分判据存在。
    expect(src, contains('bool get _isDesktop =>'),
        reason: '必须保留 _isDesktop 桌面判据');
    expect(src, contains('if (_isDesktop) {'),
        reason: '导出 IO 必须以 if (_isDesktop) 二分');

    // 桌面分支 = FilePicker；移动分支 = Share。
    final int desktopBranch = src.indexOf('if (_isDesktop) {');
    final int elseBranch = src.indexOf('} else {', desktopBranch);
    expect(desktopBranch, greaterThanOrEqualTo(0));
    expect(elseBranch, greaterThan(desktopBranch));

    final String desktopBody = src.substring(desktopBranch, elseBranch);
    final String mobileBody = src.substring(elseBranch);

    expect(desktopBody, contains('FilePicker.platform.saveFile'),
        reason: '桌面分支必须走 FilePicker.saveFile');
    expect(desktopBody, isNot(contains('Share.')),
        reason: '桌面分支绝不能调 Share.（Linux 无 share_plus 注册会崩）');

    expect(mobileBody, contains('Share.shareXFiles'),
        reason: '移动分支才用 Share.shareXFiles');
  });
}
