import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-1003）：独立「下载」页（[DownloadsPage] → 内联
/// [AnimeDownloadDialog]）的 [Scaffold] 必须显式 `resizeToAvoidBottomInset: false`。
///
/// 根因：内联下载流程把 apikey / 搜番 / Nyaa 查询 / 通用磁力等**输入框全放在页面
/// 上半部**，中段结果列表是唯一的 `Expanded`、「下载任务」折叠区贴底。默认
/// `resizeToAvoidBottomInset:true` 时，手机点顶部 apikey 输入框弹出软键盘会压掉
/// `Scaffold` body 高度 → 唯一弹性的中段被压扁 → 贴底任务区被顶到键盘上方、爬到
/// 顶部输入框边上（用户报「下载任务被输入框挤上去」）。关掉 inset 让键盘只覆盖下半部
/// 结果 / 任务区（打字时本就不看），顶部输入框保持可见、布局不反流。
///
/// 键盘弹出后的几何依赖真实 `MediaQuery.viewInsets` + 平台软键盘，widget 测试难稳定
/// 复现，故用源码扫描守卫钉住这行接线不被回退。
void main() {
  test(
      'downloads_page 的 Scaffold 设 resizeToAvoidBottomInset:false（软键盘不顶掉贴底任务区）',
      () {
    final File f = File('lib/src/pages/implementations/downloads_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 downloads_page.dart（路径变了要同步本守卫）');
    final String src = f.readAsStringSync();

    // 必须出现在文件里且落在 Scaffold(...) 内（本文件只有一个 Scaffold）。
    final int scaffold = src.indexOf('return Scaffold(');
    expect(scaffold, greaterThanOrEqualTo(0), reason: '下载页应是一个 Scaffold');
    expect(
      src.contains('resizeToAvoidBottomInset: false'),
      isTrue,
      reason: '下载页 Scaffold 必须显式 resizeToAvoidBottomInset:false，'
          '否则软键盘弹出会把贴底「下载任务」区顶到顶部输入框边上（BUG-1003）',
    );
  });
}
