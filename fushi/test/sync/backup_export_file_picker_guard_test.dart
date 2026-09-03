import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 从 [declStart] 起那个声明的花括号块（含两端）。注释已剥，字符串里的花括号只有
/// 配平的 `${...}` 插值，直接计数即可。
///
/// [openAfter] 是「块的左括号从哪儿开始找」——顶层函数用命名参数时，`(` 后面那个
/// `{` 是**参数表**而不是函数体，裸 `indexOf('{')` 会匹配到参数表，断言于是恒假。
String _bracedBody(String src, int declStart, {String openAfter = '{'}) {
  final int at = src.indexOf(openAfter, declStart);
  expect(at, greaterThanOrEqualTo(0),
      reason: 'no "$openAfter" after $declStart');
  final int open = src.indexOf('{', at);
  expect(open, greaterThanOrEqualTo(0), reason: 'no block at $declStart');
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  fail('unbalanced braces from $declStart');
}

void main() {
  // 判据前必须剥注释：本次修复的注释大段引用了「旧实现在 createBackup 之后的
  // `if (!mounted) return`」，不剥的话 indexOf 会先命中注释里那一份，守卫恒绿。
  // 用共享原语（等长掩码，下标可直接回原串切片），并连字符串内容一起掩掉 ——
  // 下面要做花括号配对，三引号/普通串里的花括号不能参与配对。
  final String src = maskCommentsAndStrings(
    File('lib/src/sync/sync_settings_schema/backup.part.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n'),
  );

  test('desktop backup export treats a cancelled save dialog as cancellation',
      () {
    final int saveDialog = src.indexOf('await FilePicker.platform.saveFile(');
    expect(saveDialog, greaterThanOrEqualTo(0),
        reason: 'Desktop backup export must use FilePicker.saveFile.');

    final int successToast = src.indexOf('t.backup_export_success', saveDialog);
    expect(successToast, greaterThan(saveDialog),
        reason: 'The success toast should remain after the save branch.');

    final String desktopSaveBody = src.substring(saveDialog, successToast);
    expect(
      desktopSaveBody,
      contains('cancelled = true'),
      reason: 'If FilePicker returns null, the user cancelled or the native '
          'panel failed; that has to be recorded as a cancellation.',
    );
    expect(
      desktopSaveBody,
      contains('if (cancelled) return;'),
      reason: '取消必须在成功提示之前 return —— 否则用户取消了另存却收到「备份成功」。',
    );
  });

  test('备份打包的所有权不在设置行的 State 上', () {
    // 根因：「本地备份」是可折叠分区，收起时整棵 rows 子树从 widget tree 移除、
    // 那一行的 State 随之 dispose。旧实现把整个导出流程写在 State 的方法里，打包
    // 之后有一句 `if (!mounted) return;` —— 折叠一下，已经打完的 zip 连同分享/
    // 另存/成功提示全被丢掉，观感就是「点一下折叠箭头，备份被取消了」。
    //
    // 结构上根治：流程搬到**库级函数**。顶层函数根本看不到 State 的 mounted，
    // 这类丢结果的写法于是无从产生。下面钉的就是这个结构。
    final int flow = src.indexOf('\nFuture<void> runBackupExportFlow(');
    expect(flow, greaterThanOrEqualTo(0),
        reason: '导出流程必须是**顶层**函数（行首无缩进），不能挂回会被折叠销毁的 '
            'State 上。');

    expect(
      'service.createBackup('.allMatches(src).length,
      1,
      reason: '打包入口只应有一处。',
    );
    final String flowBody = _bracedBody(src, flow, openAfter: ') async {');
    expect(flowBody, contains('service.createBackup('),
        reason: '打包必须发生在 runBackupExportFlow 里。');

    final int stateClass =
        src.indexOf('class _BackupExportWidgetState extends State<');
    expect(stateClass, greaterThanOrEqualTo(0));
    expect(
      _bracedBody(src, stateClass),
      isNot(contains('createBackup(')),
      reason: '设置行的 State 里不得再直接打包 —— 它会随分区折叠被销毁。',
    );
  });

  test('每次导出前先清掉上一次遗留的备份包', () {
    // 移动端走系统分享面板，非结果变体的 Future 在面板呈现后就完成，拿不到「用户
    // 存完了」的时机，所以当场删会把文件从接收方手里抽走。旧实现的
    // `finally { tmpFile.delete() }` 只写在桌面分支里，于是移动端一次都没删过：
    // 每导出一次就永久堆一份完整备份（可能几 GB），存储页里也没有删除入口。
    final int flow = src.indexOf('\nFuture<void> runBackupExportFlow(');
    final String flowBody = _bracedBody(src, flow, openAfter: ') async {');
    final int sweep = flowBody.indexOf('_sweepStaleBackupArchives(');
    final int pack = flowBody.indexOf('service.createBackup(');
    expect(sweep, greaterThanOrEqualTo(0),
        reason: '导出流程必须清理上一次遗留的备份包。');
    expect(sweep, lessThan(pack),
        reason: '清理必须发生在打包之前 —— 打完再清会把这一次的成果也删掉。');
  });
}
