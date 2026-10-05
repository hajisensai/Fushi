// 内置在线漫画源 mokuro.moe 在「来源」视图里的一行。
//
// BUG-1431：它此前挂在「本地扫描根」一节里（和 Hibiki 互联并排），但 mokuro.moe
// 是个网站、不是扫描根。用户口径：「mokuro 不应该单独显示，应该和漫画扩展同一
// 层级」。现在它和扩展提供的在线源同处「漫画源」一节，长得也一样（左开关 + 名字 +
// 地址），开关语义也一样：**关掉就不出现在「浏览」里**。
//
// 值走偏好 `manga_online_catalog_enabled`（默认 true，保持既有行为）。
// `PreferencesRepository` 写完会 notifyListeners，`AppModel` 转发，所以这里
// `ref.watch(appProvider)` 就能让「来源」与「浏览」两个视图同步——「浏览」在库页壳
// 里是 Offstage 保活的，不靠 provider 通知它永远不会重建。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/online/installed_online_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

/// 偏好未就绪时的兜底站点（与 `PreferencesRepository` 的默认值一致）。
const String kMokuroMoeDefaultBaseUrl = 'https://mokuro.moe';

/// mokuro.moe 是否参与漫画浏览。偏好未就绪时按默认值 true 处理——这条路径只在
/// widget 测试里出现，真实运行时 `AppModel` 早已初始化完毕。
bool isMokuroMoeSourceEnabled(AppModel appModel) =>
    !appModel.isPreferencesReady || appModel.mangaOnlineCatalogEnabled;

/// 见文件头：与扩展源行同一形态（[InstalledOnlineSourceRow]，M3E 分段列表行），
/// 放在「漫画源」一节最前，自成一组（内置源，没有排序 / 置顶 / 清数据）。
class MokuroMoeSourceRow extends ConsumerWidget {
  const MokuroMoeSourceRow({super.key, this.onOpen});

  /// 点行进 mokuro.moe 的目录；为 null 时行不可点。与扩展源行同一口径：
  /// 关掉的源不可点。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final bool ready = appModel.isPreferencesReady;
    final bool enabled = isMokuroMoeSourceEnabled(appModel);
    // mokuro.moe 只有日文漫画：语言 tag 固定 JA，与扩展源行同一副标题形态。
    return FushiStaggeredEntrance(
      index: 0,
      child: InstalledOnlineSourceRow(
        index: 0,
        count: 1,
        rowKey: const ValueKey<String>('mokuro_moe_source_row'),
        title: 'Mokuro.moe',
        enabled: enabled,
        onEnabledChanged: ready
            ? (bool value) =>
                unawaited(appModel.setMangaOnlineCatalogEnabled(value))
            : null,
        language: 'ja',
        detail: _siteLabel(
          ready ? appModel.mangaOnlineCatalogBaseUrl : kMokuroMoeDefaultBaseUrl,
        ),
        onOpen: onOpen,
      ),
    );
  }

  /// 副标题只显示站点 host（与扩展源的包名 / 站点同一层级），解析不出 host 的
  /// 自定义地址原样显示。
  static String _siteLabel(String baseUrl) {
    final String host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return host.isEmpty ? baseUrl : host;
  }
}
