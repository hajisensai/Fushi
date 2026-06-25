import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// reader live 设置 hook / eval 异步守卫的回归测试（源码扫描，沿用
/// `settings_renderer_test.dart` 的静态断言模式：`File(...).readAsStringSync()`
/// + `contains`）。
///
/// 守护 a5b046c40 + 972147a8d：
/// - 两个 live 设置 hook（`onSettingsChangedLive` / `onLayoutReloadLive`）把
///   `_applyStylesLive()` / `_reloadWithCurrentSettings()` 的 Future
///   fire-and-forget 时**必须** `catchError` 归集到 ErrorLogService —— 否则 await
///   边界之后的异步异常（WebView 半销毁时 `evaluateJavascript` 抛
///   PlatformException）会逃进当前 zone，绕过 FlutterError.onError /
///   takeException / platformDispatcher，生产里成未捕获异步错误、测试里让
///   flutter_test binding 断言。
/// - 三个 `_controller.evaluateJavascript` 点（`_applyStylesLive` /
///   `_reloadWithCurrentSettings` 的孤儿 await / `_updateLyricsStyleLive`）**必须**
///   有 try/catch no-op 守卫。
///
/// 为什么用源码扫描而非行为测试：reader 页含真实 `InAppWebView` 平台视图，无法在
/// widget 测试挂载；「controller 非 null 但底层 channel 已废」是运行时销毁竞态，难
/// 确定性复现。故以结构守卫替代手动设备复测，CI 每次自动验证守卫在位 —— 任何一处
/// 退回裸 fire-and-forget / 裸 eval，对应 ErrorLogService 日志 tag 消失，本测试红。
void main() {
  final String src = readReaderPageSource();

  test('reader live-settings hooks + eval sites stay async-guarded', () {
    // 每个 tag 只出现在对应的 catchError / try-catch 守卫块内；守卫被移除即消失。
    const List<String> guardTags = <String>[
      // 两个 live hook 的 catchError 日志 tag（防 fire-and-forget Future 逃 zone）
      'ReaderHibiki.onSettingsChangedLive',
      'ReaderHibiki.onLayoutReloadLive',
      // 三个 evaluateJavascript 点的 try/catch no-op 守卫 tag
      'ReaderHibiki.applyStylesLive.eval',
      'ReaderHibiki.reloadWithCurrentSettings.eval',
      'ReaderHibiki.updateLyricsStyleLive.eval',
    ];
    for (final String tag in guardTags) {
      expect(
        src,
        contains("'$tag'"),
        reason: '$tag 守卫缺失：reader 异步异常会逃 zone（半销毁 WebView 上 '
            'evaluateJavascript 抛 PlatformException）。见 a5b046c40 / 972147a8d，'
            '勿退回裸 fire-and-forget / 裸 eval。',
      );
    }

    // hook 必须经 unawaited 注册，不能同步丢弃 Future（旧写法 `_applyStylesLive();`
    // 会让 await 边界后的异常无主逃逸）。
    expect(src, contains('unawaited(_applyStylesLive()'),
        reason: 'onSettingsChangedLive 必须 unawaited()+catchError，不能裸调');
  });

  // BUG-023 / TODO-736 B-1：字体大小/行间/余白 live 变更经 _applyStylesLive 注入新 CSS 后
  // body 会重新分页，必须重锚到分页边界，否则最上一行被裁。旧实现走单函数
  // reanchorAfterStyleChange（rAF 自驱清旗，清太早 → 翻页改字号跳章首）；TODO-736 B-1 改走
  // 两阶段 settle-aware 编排 _reanchorForStyleChange（begin 同步换 CSS+采锚+置旗 → postFrame
  // settle → commit 滚回+清旗+打 _reanchorClearedAt）。谁把重锚去掉、退回只设 textContent，本断言红。
  test(
      'applyStylesLive routes live CSS through _reanchorForStyleChange orchestration',
      () {
    expect(
      src,
      contains('_reanchorForStyleChange('),
      reason: '_applyStylesLive 必须走 _reanchorForStyleChange 两阶段编排（begin/commit '
          'settle-aware 重锚），让字体/行间/余白变更后重排能重锚到分页边界，否则最上一行被裁'
          '（BUG-023）。勿退回只 el.textContent = css。',
    );
  });

  // TODO-842：「反转阅读器底栏」改完不实时生效须退出重进。根因=该项 onChanged
  // 只调 quick-settings sheet 自身 refresh()，不触碰下层 reader 页；reader 底栏裸读
  // appModel.reverseReaderBottomBar（非 ref.watch），只有 reader 页 rebuild 才重取值。
  // 修复=新增轻量 onChromeReloadLive hook（纯 setState 重建 chrome 层，不重锚/不重排/
  // 不动 WebView），reader 注册+dispose 置 null，settings_actions 新增
  // notifyReaderChromeChanged，reverse_reader_bottom_bar 的 onChanged 改走它。
  // 任何一处接线退回（漏注册 / 漏 dispose 置 null / onChanged 退回裸 c.refresh()），本组红。
  test('TODO-842: reverse-bottom-bar toggle wired through onChromeReloadLive',
      () {
    // 1) reader 页注册 + dispose 置 null（防泄漏）。
    expect(
      src,
      contains('onChromeReloadLive ='),
      reason:
          'reader initState 必须注册 onChromeReloadLive（纯 setState 重建 chrome 层），'
          '否则反转底栏改完不实时生效须退出重进（TODO-842）。',
    );
    expect(
      src,
      contains('onChromeReloadLive = null'),
      reason: 'reader dispose 必须把 onChromeReloadLive 置 null，防止静态 hook 泄漏到已销毁页。',
    );

    // 2) settings_actions.dart 新增 notifyReaderChromeChanged 且体内 fire hook。
    final String actions = File('lib/src/settings/settings_actions.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      actions,
      contains('void notifyReaderChromeChanged('),
      reason:
          'settings_actions 必须提供 notifyReaderChromeChanged 触发 reader chrome 重建。',
    );
    expect(
      actions,
      contains('onChromeReloadLive?.call()'),
      reason:
          'notifyReaderChromeChanged 体内必须 fire onChromeReloadLive，否则 reader 不重建。',
    );

    // 3) reverse_reader_bottom_bar 的 onChanged 走 notifyReaderChromeChanged，
    //    不再裸 c.refresh()（裸 refresh 只重建设置浮层，不碰 reader 页）。
    final String schema = File('lib/src/settings/settings_schema_reading.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int idx =
        schema.indexOf("'reading_display.reverse_reader_bottom_bar'");
    expect(idx, greaterThanOrEqualTo(0),
        reason: 'reverse_reader_bottom_bar 设置项缺失。');
    // 取该项 onChanged 闭包到下一个 `),` 块尾的切片，断言走 hook 而非裸 refresh。
    final int onChangedIdx = schema.indexOf('onChanged:', idx);
    final String slice = schema.substring(onChangedIdx, onChangedIdx + 200);
    expect(
      slice,
      contains('notifyReaderChromeChanged(c)'),
      reason:
          'reverse_reader_bottom_bar onChanged 必须走 notifyReaderChromeChanged，'
          '否则只重建设置浮层、reader 底栏不实时镜像（TODO-842）。',
    );
    expect(
      slice.contains('c.refresh()'),
      isFalse,
      reason:
          'reverse_reader_bottom_bar onChanged 不应再裸调 c.refresh()（不触下层 reader 页）。',
    );
  });
}
