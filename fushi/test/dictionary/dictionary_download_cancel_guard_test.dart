import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1499 / BUG-1500 回归守卫。
///
/// 这四条守的是三个**结构性**事实，任何一条塌了都会把用户带回「只能干等」或者
/// 「取消把词典库毁了」：
/// 1. 每个 `DictionaryDownloader.download(` 调用点都得真传 `cancelToken:`——BUG-1499
///    的根因就是形参存在但三个调用点一个都不传，取消入口从来没接上过。
/// 2. 进度框的收尾不得再由发起方 `Navigator.pop(context)`——那一 pop 在用户已经把
///    进度框收起来之后会弹掉词典页本身，也正因为它，"隐藏" 以前根本不可能。
/// 3. 自动更新必须与手动下载共用同一把锁（`dictionaryDownloadController.run`）。
/// 4. 词典导入链路不得接受取消令牌：native 导入是一次不可分割的 FFI 调用，内部是
///    「导新到 temp → 删旧 → publish」，塞进任何中途取消检查点都可能停在「删旧
///    之后」，把用户已有的词典毁掉。
void main() {
  /// 从 [code] 中 [anchor] 处起，按括号配平取出**整个调用/参数表**的源文本。
  List<String> callArgumentLists(String code, String anchor) {
    final List<String> found = <String>[];
    int from = 0;
    while (true) {
      final int start = code.indexOf(anchor, from);
      if (start < 0) break;
      int i = start + anchor.length - 1; // 停在 anchor 末尾的 '('
      int depth = 0;
      final int begin = i;
      for (; i < code.length; i++) {
        final String ch = code[i];
        if (ch == '(') depth++;
        if (ch == ')') {
          depth--;
          if (depth == 0) break;
        }
      }
      found.add(code.substring(begin, i < code.length ? i + 1 : code.length));
      from = i + 1;
    }
    return found;
  }

  /// 从 `signature` 起截到 `end`（不含）的一段源码。
  String sectionSource(String code, String signature, String end) {
    final int start = code.indexOf(signature);
    expect(start, isNot(-1), reason: '守卫锚点消失：$signature');
    final int stop = code.indexOf(end, start + signature.length);
    expect(stop, isNot(-1), reason: '守卫锚点消失：$end');
    return code.substring(start, stop);
  }

  /// 掩掉注释**与字符串字面量**再扫：本文件与被扫文件的注释里都反复写着这些根因的
  /// 名字（含 `Navigator.pop(context)`、`cancelToken` 字样），不掩就是一条稳定的假
  /// 阳性；掩掉串则让下面的括号配平不会被串里的括号带偏。共享词法器保证掩码等长，
  /// 下标可直接回原串（`test/tools/source_guard_adoption_test.dart` 禁手写剥离器）。
  String read(String relativePath) =>
      maskCommentsAndStrings(File(relativePath).readAsStringSync());

  const String dialogPagePath =
      'lib/src/pages/implementations/dictionary_dialog_page.dart';
  const String appModelPath = 'lib/src/models/app_model.dart';
  const String importManagerPath =
      'lib/src/models/dictionary_import_manager.dart';

  test('每个词典下载调用点都真的传了 cancelToken', () {
    for (final String path in <String>[dialogPagePath, appModelPath]) {
      final String code = read(path);
      final List<String> calls =
          callArgumentLists(code, 'DictionaryDownloader.download(');
      expect(calls, isNotEmpty, reason: '$path 里找不到下载调用点，守卫锚点过期');
      for (final String call in calls) {
        expect(
          call.contains('cancelToken:'),
          isTrue,
          reason: '$path 的某个 DictionaryDownloader.download 没传 cancelToken：'
              '这正是 BUG-1499 的根因形态（形参在、没人传，取消按钮按了没用）\n$call',
        );
      }
    }
  });

  test('进度框的收尾不再由发起方 Navigator.pop（否则收起后会弹掉词典页）', () {
    final String code = read(dialogPagePath);
    final String runner = sectionSource(
      code,
      'Future<void> _runWithDownloadProgressDialog({',
      'void _showDownloadProgressDialog()',
    );
    expect(
      runner.contains('Navigator.pop('),
      isFalse,
      reason: '任务收尾处再出现 Navigator.pop 就意味着：用户把进度框收起来之后，'
          '收尾那一 pop 会弹掉词典页本身。关闭必须由对话框自己（AutoCloser）负责。',
    );
    expect(
      code.contains('class DictionaryDownloadProgressAutoCloser'),
      isTrue,
      reason: '进度框的自动关闭必须由活在 dialog route 内的 AutoCloser 负责',
    );
  });

  test('静默自动更新与手动下载共用同一把锁', () {
    final String code = read(appModelPath);
    final String auto = sectionSource(
      code,
      'Future<void> maybeAutoUpdateDictionaries() async {',
      'Future<void> _autoRedownloadAndReimport(',
    );
    expect(
      auto.contains('dictionaryDownloadController.run('),
      isTrue,
      reason: '自动更新不走同一把锁 → 它与手动下载能并发写同一本词典，'
          '而两边导入共用同一个 import_temp 暂存目录（BUG-1500）',
    );
    expect(
      auto.contains('isBusy: dictionaryDownloadController.isBusy'),
      isTrue,
      reason: '「是否已有下载在跑」的判据必须是 app 级 controller，'
          '不能退回本类私有的 bool（那挡不住词典页的手动下载）',
    );
  });

  test('词典导入链路不接受取消令牌（导入中途取消会毁掉已有词典）', () {
    final String code = read(importManagerPath);
    for (final String signature in <String>[
      'Future<void> importFromDirectory(',
      'Future<void> importFromFile(',
    ]) {
      final List<String> params = callArgumentLists(code, signature);
      expect(params, isNotEmpty, reason: '守卫锚点过期：$signature');
      expect(
        params.first.toLowerCase().contains('cancel'),
        isFalse,
        reason: '$signature 出现取消参数：native 导入是一次不可分割的 FFI 调用，'
            '而 Dart 侧「删旧 → publish」之间的任何中断都会让用户旧词典已删、'
            '新词典没落地。要支持真取消必须先让 C++ 侧有安全检查点（BUG-1499）。',
      );
    }
  });

  test('掩码器与取参器本身有效（守卫的自校验）', () {
    const String sample = '''
// DictionaryDownloader.download(url: x, cancelToken: t);
/* DictionaryDownloader.download(url: y, cancelToken: t); */
void f() {
  DictionaryDownloader.download(url: a, tempDir: b);
}
''';
    final List<String> calls = callArgumentLists(
      maskCommentsAndStrings(sample),
      'DictionaryDownloader.download(',
    );
    expect(calls, hasLength(1), reason: '注释里的调用不该被算成命中');
    expect(calls.single.contains('cancelToken:'), isFalse,
        reason: '注释里的 cancelToken 不该把守卫骗绿');
  });
}
