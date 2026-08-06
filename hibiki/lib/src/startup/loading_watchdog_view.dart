import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart' show t;

/// TODO-1260：启动「加载中」界面（含超时逃生态）。
///
/// 裸 loading 分支此前只有一个**无超时**的 [CircularProgressIndicator]——若
/// `AppModel.initialise()` 因某早期 IO（掉线的自定义数据根盘做 stat / 目录创建）永不
/// 返回，就无限转圈、无任何逃生口（TODO-1260「偶发无限加载」根因之一）。
///
/// 本 widget 把「转圈」与「超时逃生 UI」收敛成 [timedOut] 的纯函数：
///   - [timedOut] == false → 居中转圈（与旧行为一致）。
///   - [timedOut] == true  → 「耗时超预期 + 说明 + 重试」逃生 UI，[onRetry] 触发重试。
///
/// 计时（何时翻 [timedOut]）由 `_FushiReaderAppState` 的看门狗 [Timer] 负责；本 widget
/// 只做渲染，故可被 widget 测试独立断言「超时后 Retry 出现」而无需 pump 整个 App。
class LoadingWatchdogView extends StatelessWidget {
  const LoadingWatchdogView({
    super.key,
    required this.timedOut,
    required this.colorScheme,
    required this.onRetry,
    this.isMobile,
  });

  /// 是否已超过看门狗时限仍未初始化完成（true 显示逃生 UI，false 显示转圈）。
  final bool timedOut;

  /// 首帧配色（与原生 splash 亮暗一致，避免闪白）。
  final ColorScheme colorScheme;

  /// 用户点「重试」的回调（由 State 复位看门狗并调 `retryInitialise`）。
  final VoidCallback onRetry;

  /// BUG-815：是否移动端（决定超时说明文案）。null 时按 [defaultTargetPlatform]
  /// 解析（生产默认）；测试可显式传值断言桌面 / 移动两套文案。
  final bool? isMobile;

  @override
  Widget build(BuildContext context) {
    if (!timedOut) {
      return Center(
        child: CircularProgressIndicator(color: colorScheme.primary),
      );
    }
    // BUG-815: the desktop copy explains the dropped custom-drive data root +
    // "start with the default location" escape. On mobile there is NO custom
    // data root (AppPaths._resolveDataRoot returns null off desktop), so that
    // wording is both irrelevant and alarming — Retry never changes any location
    // there. Pick a mobile-appropriate copy that reassures the data is safe.
    final bool mobile = isMobile ??
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.hourglass_empty, size: 48, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              t.loading_slow_title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              mobile ? t.loading_slow_message_mobile : t.loading_slow_message,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t.retry),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
