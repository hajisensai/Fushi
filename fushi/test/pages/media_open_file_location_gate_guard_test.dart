import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 视频库 / 游戏库「打开文件位置」的门控接线守卫（书架那条在
/// `reader_shelf_open_file_location_guard_test.dart`，三条同一形状）。
///
/// 这条动作只在有文件管理器契约的桌面端成立。门控一旦被删，移动端会多出一个点了
/// 必然失败的菜单项——而 widget 测试宿主恒为桌面，它不会让任何行为用例变红，只会
/// 让用户点了以为坏了。所以判据放在源码层：门控表达式必须**紧挨着**这条动作本身，
/// 而不是文件里某处出现过。
///
/// `\s` 覆盖 `\r\n`，故两条判据在 CRLF 与 LF 两种 checkout 下同样成立。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('视频卡「打开文件位置」被 currentRevealHost + 本地文件判据同时门控', () {
    final String source = read(
      'lib/src/pages/implementations/home_video_page.dart',
    );

    expect(
      RegExp(
        r'currentRevealHost\(\)\s*!=\s*null\s*&&\s*'
        r'videoBookHasLocalFiles\(book\)\s*\)\s*DialogQuickAction\('
        r'\s*label:\s*t\.media_file_location_open',
      ).hasMatch(source),
      isTrue,
      reason: '两道门都得直接包住这条动作：移动端无文件管理器契约，流媒体书本机无文件',
    );
  });

  test('视频卡定位复用删除路径的本地文件候选表，不在页面里另拼一份', () {
    final String source = read(
      'lib/src/pages/implementations/home_video_page.dart',
    );

    expect(
      RegExp(r'revealFirstOf\(\s*localVideoFileCandidates\(').hasMatch(source),
      isTrue,
      reason: '「这一行在本机有哪些原始文件」是删除路径的真相源，定位不该再拼第二份',
    );
  });

  test('游戏卡「打开文件位置」被 currentRevealHost 门控', () {
    final String source = read(
      'lib/src/pages/implementations/games_library_page.dart',
    );

    expect(
      RegExp(
        r'currentRevealHost\(\)\s*!=\s*null\s*\)\s*\(\s*'
        r"action:\s*'file_location',\s*label:\s*t\.media_file_location_open",
      ).hasMatch(source),
      isTrue,
      reason: '门控必须直接包住这条菜单项，移动端不得出现点了必失败的菜单项',
    );
  });

  test('游戏卡定位先试 exe 再退回工作目录', () {
    final String source = read(
      'lib/src/pages/implementations/games_library_page.dart',
    );

    expect(
      RegExp(
        r'revealFirstOf\(\s*<String>\[\s*game\.exePath,\s*game\.workdir,?\s*\]',
      ).hasMatch(source),
      isTrue,
      reason: 'exe 被移走/改名时仍要把用户带到游戏目录，顺序不能反',
    );
  });
}
