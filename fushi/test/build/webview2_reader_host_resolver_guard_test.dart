import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/reader_resource_host.dart'
    show kReaderResourceHost;

String _read(String path) => File(path).readAsStringSync();

/// BUG-3497 源码接线守卫：WebView2 默认环境必须把阅读器虚拟域名的主机解析
/// 短路成「立即找不到」。
///
/// 根因：`fushi.local` 只存在于资源拦截器里，但 WebView2 每次主框架导航仍会照常
/// 解析主机名；`.local` 在 Windows 上走组播名称解析（mDNS / LLMNR），要等约 2.7 s
/// 才失败，且失败不缓存——开书、跨章每次导航都白屏约 2 秒。解析结果本来就是失败
/// （fork 在 NavigationCompleted 里把这次假失败纠正为成功），`~NOTFOUND` 只是让
/// 它立即失败，语义不变。
void main() {
  test(
    'default WebView2 environment short-circuits the reader host lookup',
    () {
      final String fork = _read(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/'
        'in_app_webview.cpp',
      );
      expect(
        fork,
        contains(
          r'--host-resolver-rules=\"MAP '
          '$kReaderResourceHost'
          r' ~NOTFOUND\"',
        ),
        reason:
            'without this rule every main-frame navigation to '
            '$kReaderResourceHost waits ~2.7 s for a multicast name lookup '
            'to fail on Windows (BUG-3497); the rule host must follow '
            'kReaderResourceHost',
      );
      // 同一处 AdditionalBrowserArguments 里仍保留 autoplay（BUG-1093），两条参数
      // 必须同在一个字符串里——put_AdditionalBrowserArguments 后一次调用会覆盖前一次。
      final int autoplay = fork.indexOf(
        '--autoplay-policy=no-user-gesture-required',
      );
      final int resolver = fork.indexOf('--host-resolver-rules=');
      expect(autoplay, greaterThanOrEqualTo(0));
      expect(resolver, greaterThan(autoplay));
      expect(
        'put_AdditionalBrowserArguments'.allMatches(fork).length,
        1,
        reason: 'the default environment sets its browser arguments once',
      );
    },
  );
}
