import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dict_style_preview.dart';

// BUG-1918：打开「词典样式」→ 可视化页闪退（Windows，0xC0000005）。
//
// 根因在原生侧（`packages/flutter_inappwebview_windows/windows/in_app_webview/
// webview_channel_delegate.cpp` 的 CallJsHandlerCallback::decodeResult 把
// Dart 的 **null 答复**（StandardMethodCodec 走无参 Success() → value ==
// nullptr）原样塞进一个已引发的 optional，下游 `response.value()->IsNull()`
// 直接解引用空指针）。触发条件是 **JS 调了一个 Dart 侧没注册的 handler 名**：
// `_handleMethod` 走到末尾 `return null`，于是回复就是 null。
//
// DictStylePreview 跑的是**真的** popup.js，它能发起 21 个桥调用，而预览此前只
// 注册了 4 个——`reportJsError`（预览里任何 JS 报错都会调）、`tapOutside`（点空白
// 处）等一调就崩。
//
// 原生那一层已根治，但两侧都得对：预览必须给 popup.html 加载的每个脚本里出现的
// 每个 `callHandler('X')` 一个确定的 Dart 侧语义，而不是靠平台兜底空回复。
// 这条守卫把「名单 ⊇ 脚本里真实调用的名字」钉住——popup.js 新加一个 callHandler
// 而预览没跟上，这里就红。
void main() {
  test('DictStylePreview 注册了 popup.html 所有脚本能调到的全部 JS handler', () {
    final Directory popupDir = Directory('assets/popup');
    expect(
      popupDir.existsSync(),
      isTrue,
      reason: '测试要在 fushi/ 下跑（assets/popup 是相对它的路径）',
    );

    // popup.html 实际加载了哪些脚本，就扫哪些——别扫整个目录：definition.js /
    // global_lookup_host.js 是别的宿主（视频定义面板 / app 外浮窗）在用的，把它们
    // 的 handler 名摊派给预览会让这份名单虚胖，读的人分不清哪些是真必需。
    final String html = File('assets/popup/popup.html').readAsStringSync();
    final List<String> scripts = RegExp(
      r'<script\s+src="([^"]+\.js)"',
    ).allMatches(html).map((RegExpMatch m) => m.group(1)!).toList();
    expect(scripts, isNotEmpty, reason: 'popup.html 里没扫到 <script src>');
    expect(scripts, contains('popup.js'));

    final Set<String> called = <String>{};
    for (final String script in scripts) {
      final File file = File('assets/popup/$script');
      expect(file.existsSync(), isTrue, reason: 'popup.html 引用了不存在的 $script');
      // 允许 `callHandler(` 与名字之间换行/空格：popup.js 里长参数是折行写的，
      // 只认同一行会漏掉 resolveWordAudio、findMinedMatches 等一批。
      called.addAll(
        RegExp(r'''callHandler\(\s*['"]([A-Za-z0-9_]+)['"]''')
            .allMatches(file.readAsStringSync())
            .map((RegExpMatch m) => m.group(1)!),
      );
    }
    expect(
      called.length,
      greaterThan(10),
      reason: '正则没匹配到几个名字，八成是 callHandler 的写法变了，先修正则',
    );

    final Set<String> registered = kDictStylePreviewNoopHandlers.toSet();
    expect(
      registered.length,
      kDictStylePreviewNoopHandlers.length,
      reason: 'kDictStylePreviewNoopHandlers 里有重复名字',
    );

    final List<String> missing = (called.difference(registered).toList())
      ..sort();
    expect(
      missing,
      isEmpty,
      reason:
          '预览没注册这些 popup 脚本会调的 handler：$missing —— '
          '未注册的名字会让插件回 null 答复（BUG-1918 的闪退触发条件），'
          '且该桥调用在预览里行为未定义。补进 kDictStylePreviewNoopHandlers。',
    );

    final List<String> stale = (registered.difference(called).toList())..sort();
    expect(stale, isEmpty, reason: '这些名字已经没有任何 popup 脚本会调了，从名单里删掉：$stale');
  });

  test('原生侧 decodeResult 对 null 答复有空守卫（BUG-1918 根因）', () {
    // 真正的崩点在 C++，flutter test 跑不到它；但那一行的存在与否是二元的，源码
    // 扫描能钉住。要求：CallJsHandlerCallback 的 decodeResult 体内出现 `!value`
    // 判空并返回 nullopt——去掉它就回到「空回复被当指针解引用」的闪退。
    final File cpp = File(
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/'
      'webview_channel_delegate.cpp',
    );
    expect(cpp.existsSync(), isTrue, reason: '找不到 ${cpp.path}');
    final String source = cpp.readAsStringSync();

    const String marker = 'CallJsHandlerCallback::CallJsHandlerCallback()';
    final int start = source.indexOf(marker);
    expect(start, greaterThanOrEqualTo(0), reason: '构造函数改名了，先更新本守卫');
    // 截到下一个构造函数为止，避免把别的 decodeResult 的空守卫当成这一个的。
    final int next = source.indexOf('Callback::', start + marker.length);
    final String body = source.substring(
      start,
      next < 0 ? source.length : next,
    );

    expect(body.contains('decodeResult'), isTrue);
    expect(
      body.contains('if (!value)') || body.contains('!value ||'),
      isTrue,
      reason:
          'CallJsHandlerCallback::decodeResult 必须先判 value 是否为空：'
          'Dart 回 null 时这里收到的就是 nullptr，直接 return value 会装出一个 '
          'has_value()==true 但值为 nullptr 的 optional，下游解引用即闪退。',
    );
    expect(
      body.contains('std::nullopt'),
      isTrue,
      reason: '空 value 必须降成 std::nullopt，让下游 has_value() 守卫真的能拦住。',
    );
  });
}
