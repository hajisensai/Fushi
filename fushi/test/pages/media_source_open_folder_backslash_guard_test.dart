import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';

/// BUG-920 守卫：管理来源「打开文件夹」必须把 rootPath 的正斜杠转回反斜杠再交给
/// Windows explorer.exe。
///
/// 根因：normalizeSourceRootPath 把本地 rootPath 归一化为正斜杠（跨平台一致 +
/// dedup/label 依赖），而 explorer.exe 只认反斜杠路径参数——传正斜杠会被忽略、
/// 改开默认「文档」目录。存储层归一化不动，仅在 explorer 平台边界做方向转换。
///
/// 「打开文件夹」现在走三桌面端共用的 [revealInFileManager]（Linux / macOS 也能
/// 用），方向转换收在该原语的 Windows 分支：这里同时钉住「委托给原语」与「原语
/// 对正斜杠目录做了转换」两半，缺一半 BUG-920 就会回来。
void main() {
  late String source;

  setUp(() {
    // 实现体已从对话框文件搬到 [MediaSourcesView]（对话框与库页「来源」视图共用
    // 同一份行为），守卫因此跟着扫内容体文件。
    source = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
  });

  test('_openFolder 委托给 revealInFileManager，不再自己拼 explorer 调用', () {
    final int idx = source.indexOf('Future<void> _openFolder(');
    expect(idx, isNonNegative, reason: '必须存在 _openFolder');
    final String body = source.substring(idx, idx + 400);
    expect(body, contains('revealInFileManager(row.rootPath)'));
    expect(
      source.contains("Process.run('explorer'"),
      isFalse,
      reason: '裸 explorer 调用会绕开原语里的 / → \\ 转换（BUG-920 回归）',
    );
  });

  test('原语的 Windows 分支把正斜杠目录转成反斜杠', () {
    final RevealCommand command = revealCommand(
      host: RevealHost.windows,
      path: 'D:/Anime/Season 1',
      isDirectory: true,
    );
    expect(command.executable, 'explorer');
    expect(command.arguments, <String>[r'D:\Anime\Season 1']);
  });

  test('入口不再只给 Windows：桌面三端本地来源都可用', () {
    expect(source, contains('onTap: isLocal && currentRevealHost() != null'));
    expect(source, isNot(contains('enabled: isLocal && Platform.isWindows,')));
  });
}
