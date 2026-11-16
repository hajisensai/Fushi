import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_page_content.dart';

/// 页面侧判据最多等多久（站点数据常是页面加载完后才异步到，如 hitomi 阅读页的
/// `galleryinfo`）。与 ComicRead 站点适配 `isMangaPage` 的等待上限同量级。
const Duration kWebComicDetectBudget = Duration(seconds: 5);

/// 两次检查之间的间隔。
const Duration kWebComicDetectInterval = Duration(milliseconds: 200);

/// 按随包站点规则判定漫画页（照 ComicRead：先按站点适配认，认不到才走通用识别）。
///
/// 规则命中 URL 且没有 [WebComicSiteRule.detect] → 是漫画页；有 detect → 在页面里
/// 反复跑它直到返回真值或超出 [budget]。没有规则覆盖的地址返回 null，交给通用启发式。
class WebComicSiteComicDetector implements WebPageSiteComicDetector {
  WebComicSiteComicDetector({
    Future<WebComicRuleSet> Function()? rules,
    this.budget = kWebComicDetectBudget,
  }) : _rules = rules ?? WebComicAssets.rules;

  final Future<WebComicRuleSet> Function() _rules;
  final Duration budget;

  @override
  Future<bool?> isComicPage(InAppWebViewController controller, Uri url) async {
    final WebComicSiteRule? rule = (await _rules()).matchChapter(url);
    if (rule == null) return null;
    final String? detect = rule.detect;
    if (detect == null) return true;
    final CallAsyncJavaScriptResult? result = await controller
        .callAsyncJavaScript(
          functionBody: webComicDetectFunctionBody(detect, budget: budget),
        );
    if (result == null || result.error != null) return false;
    return webComicDetectVerdict(result.value);
  }
}

/// 把规则的 detect 函数体包成「限时轮询」的 async 函数体（给 `callAsyncJavaScript`）。
///
/// detect 原文直接写进源码（不在页面里 `new Function`，理由同 `script` 取图）；它抛错
/// 当作「还不是」，到点仍不是返回 0。返回 1 / 0 而不是布尔：各平台回传值解码不一致。
String webComicDetectFunctionBody(
  String detect, {
  Duration budget = kWebComicDetectBudget,
  Duration interval = kWebComicDetectInterval,
}) =>
    'var check = async function () {\n$detect\n};\n'
    'var deadline = Date.now() + ${budget.inMilliseconds};\n'
    'for (;;) {\n'
    '  try { if (await check()) return 1; } catch (_) {}\n'
    '  if (Date.now() >= deadline) return 0;\n'
    '  await new Promise(function (r) { '
    'setTimeout(r, ${interval.inMilliseconds}); });\n'
    '}';

/// [webComicDetectFunctionBody] 回传值 → 判定（1 / "1" / true 为是）。
bool webComicDetectVerdict(Object? value) =>
    value == true || value == 1 || value == '1' || value == 1.0;
