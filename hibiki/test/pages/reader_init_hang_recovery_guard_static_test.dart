import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-437 源码守卫：打开书籍偶发永久卡加载、不恢复（双实例更易触发）。
///
/// 根因 = `_initBook` 整函数无 top-level try/catch，其内多处 DB await
/// （_resolveProfileAndSettings / db.getEpubBook / _resolveAudioSlot /
/// repo.findByBookKey）任一抛异常即逃逸出 async 链 → _book / _audioSlotResolved
/// 永不置好 → 尾部 setState 永不执行 → _buildBody 永远返回 spinner → WebView
/// 从不构造 → 唯一兜底超时 _startContentReadyTimeout 从不启动 → 永久卡加载、无恢复。
///
/// 修复 = `_initBook` 体抽进 `_initBookInner`，外层 top-level try/catch 在任何异常时
/// 确定性归还加载态（记真实异常 + toast 提示打开失败 + Navigator.pop 退回书架）。
///
/// 守卫断言修复结构在位：①`_initBook` 含 try{ await _initBookInner ... } catch；
/// ②catch 分支调恢复路径（HibikiToast.show + Navigator.of(context).pop()）；
/// ③真正的 init 逻辑（DB await 链入口 _resolveProfileAndSettings）搬进 `_initBookInner`。
/// 删掉 try/catch 或恢复路径即红。ReaderHibikiPage 过重（WebView + 音频 + 全
/// ProviderContainer），无法在 widget test 可靠拉起跑 _initBook，故落在最强可靠可落地的
/// 源码语料层（与 reader_* 一系列 *_static_test 同纪律）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('_initBook 用 top-level try/catch 包裹 _initBookInner 并确定性恢复加载态', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');

    // ① 真正的 init 链被抽进 _initBookInner（DB await 入口在其中）。
    expect(src.contains('Future<void> _initBookInner() async {'), isTrue,
        reason: 'init 逻辑应抽进 _initBookInner 由 try 包裹');
    final int innerStart = src.indexOf('Future<void> _initBookInner() async {');
    expect(src.indexOf('_resolveProfileAndSettings(db)', innerStart),
        greaterThan(-1),
        reason: 'DB await 链应位于 _initBookInner 体内');

    // ② _initBook 体内：try → await _initBookInner → catch → 恢复路径。
    final int bookStart = src.indexOf('Future<void> _initBook() async {');
    expect(bookStart, greaterThan(-1));
    final String bookBody = src.substring(bookStart, innerStart);
    expect(bookBody.contains('try {'), isTrue,
        reason: '_initBook 必须有 top-level try');
    expect(bookBody.contains('await _initBookInner();'), isTrue,
        reason: 'try 内应 await _initBookInner');
    expect(bookBody.contains('} catch ('), isTrue,
        reason: '_initBook 必须 catch 任何异常（非仅 FormatException）');

    // ③ catch 分支确定性归还加载态：记异常 + toast + pop 退回书架，且 mounted 守卫。
    final int catchIdx = bookBody.indexOf('} catch (');
    final String catchBody = bookBody.substring(catchIdx);
    expect(catchBody.contains('if (!mounted) return;'), isTrue,
        reason: 'catch 内 setState/Navigator 前必须 mounted 守卫');
    expect(catchBody.contains('HibikiToast.show('), isTrue,
        reason: 'catch 必须提示用户打开失败');
    expect(catchBody.contains('Navigator.of(context).pop()'), isTrue,
        reason: 'catch 必须退回书架，不让 spinner 永挂');
    expect(
        catchBody.contains('debugPrint(') ||
            catchBody.contains('ErrorLogService.instance.log('),
        isTrue,
        reason: 'catch 不得吞异常不留痕');
  });
}
