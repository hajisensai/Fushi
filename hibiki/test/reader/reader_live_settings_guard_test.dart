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

  // BUG-023: 字体大小/行间/余白 live 变更经 _applyStylesLive 注入新 CSS 后，body
  // 会重新分页，但旧实现只 `el.textContent = css` 就完事，从不重锚到分页边界 ——
  // 页面停在错位滚动量、最上一行被裁。修复后注入的 JS 必须在 hoshiReader 存在时
  // 走 reanchorAfterStyleChange（捕捉进度→换样式→重建 metrics→rAF 重锚），仅在其
  // 缺席（未初始化 / 非分页 reader 页）时回退裸 textContent。谁把重锚去掉、退回
  // 只设 textContent，本断言红。
  test('applyStylesLive routes live CSS through reanchorAfterStyleChange', () {
    expect(
      src,
      contains('reanchorAfterStyleChange'),
      reason: '_applyStylesLive 注入的 live-CSS JS 必须调用 '
          'reanchorAfterStyleChange，让字体/行间/余白变更后重排能重锚到分页边界，'
          '否则最上一行被裁（BUG-023）。勿退回只 el.textContent = css。',
    );
  });
}
