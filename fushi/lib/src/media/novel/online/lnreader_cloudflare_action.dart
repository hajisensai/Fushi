import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_cloudflare_challenge_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

/// 插件请求被 Cloudflare 拦下后，给用户的「站点验证」按钮。
///
/// 与 LNReader app 的「在 WebView 中打开」同一用法：**只由用户点击触发**，从不
/// 在后台请求里自动弹页。解题页与漫画扩展共用 [AidokuCloudflareChallengePage]
/// （同 UA 打开被拦地址、轮询到新的 `cf_clearance` 自动关闭、整站 cookie 回存），
/// cookie 落进小说源自己的 jar，桥之后的请求都会带上。
///
/// 该插件没有待解挑战时不占位。
class LnReaderCloudflareAction extends StatelessWidget {
  const LnReaderCloudflareAction({
    required this.cloudflare,
    required this.pluginId,
    required this.onVerified,
    super.key,
    this.pageBuilder,
  });

  final LnReaderCloudflare? cloudflare;
  final String pluginId;

  /// 验证通过后调用（页面据此重新加载）。
  final VoidCallback onVerified;

  /// 测试注入：替掉真解题页（widget 测试环境没有平台 WebView）。
  @visibleForTesting
  final Widget Function(LnReaderCloudflareChallenge challenge)? pageBuilder;

  Future<void> _verify(BuildContext context) async {
    final LnReaderCloudflare? state = cloudflare;
    final LnReaderCloudflareChallenge? challenge = state?.challengeFor(
      pluginId,
    );
    if (state == null || challenge == null) return;
    final bool? solved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        // 路由层中和界面整体缩放，WebView 才按真实视口栅格化（BUG-2522）。
        builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
          child:
              pageBuilder?.call(challenge) ??
              AidokuCloudflareChallengePage(
                challengeUrl: challenge.url,
                userAgent: challenge.userAgent,
                jar: state.jar,
              ),
        ),
        fullscreenDialog: true,
      ),
    );
    if (solved != true) return;
    state.resolved(pluginId);
    onVerified();
  }

  @override
  Widget build(BuildContext context) {
    if (cloudflare?.challengeFor(pluginId) == null) {
      return const SizedBox.shrink();
    }
    return FilledButton.tonalIcon(
      key: ValueKey<String>('novel_source_cloudflare_verify_$pluginId'),
      onPressed: () => _verify(context),
      icon: const Icon(Icons.verified_user_outlined),
      label: Text(t.manga_source_cloudflare_verify_title),
    );
  }
}
