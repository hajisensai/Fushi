import 'package:flutter/material.dart';

import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一行元信息：跳过空片段后用 ` · ` 串成**单行**。
///
/// 扩展行以前是「语言 · 版本」`\n`「完整 URL」两行硬换行，副标题独占两行、
/// 行高冲到 ~89px，手机一屏只剩六条；URL 还带 `https://` 前缀把有效信息
/// 挤出可视区。收成一行后行高回到 ~62px，且与本仓其它列表（下载任务卡
/// `download_task_card.dart`、章节行 `manga_chapter_list.dart`）同一写法。
String mangaSourceMetaLine(Iterable<String?> parts) => parts
    .map((String? part) => part?.trim() ?? '')
    .where((String part) => part.isNotEmpty)
    .join(' · ');

/// 源地址的可读短形：去掉 scheme / `www.` / 末尾斜杠，保留主机（+ 非根路径）。
/// 解析不动的（Aidoku 只有包 id、没有 baseUrl）原样返回。
String mangaSourceHostLabel(String value) {
  final String raw = value.trim();
  if (raw.isEmpty) return '';
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw;
  final String host =
      uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  final String path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}

/// Shared visual contract for Mihon APK and Aidoku AIX extension rows.
/// Runtime-specific pages supply metadata and actions; spacing, icon fallback,
/// warning badge, progress, enable switch and buttons stay identical.
class MangaExtensionManagementTile extends StatelessWidget {
  const MangaExtensionManagementTile({
    required this.title,
    required this.subtitle,
    super.key,
    this.iconUrl,
    this.contentWarning = false,
    this.busy = false,
    this.enabled,
    this.onEnabledChanged,
    this.secondaryLabel,
    this.onSecondary,
    this.primaryLabel,
    this.onPrimary,
    this.subtitleMaxLines = 1,
  });

  final String title;
  final Widget subtitle;
  final String? iconUrl;
  final bool contentWarning;
  final bool busy;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 副标题行数上限。默认 1（一行元信息）；Mihon 的「可用扩展」行在副标题里
  /// 展开自带源清单，由调用点显式放宽。
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      // 行与行之间必须有实边距：卡片圆角 10 而外边距为 0 时，相邻卡片之间只
      // 从圆角缺口漏出几处页面底色，看着像锯齿而不是分隔。
      margin: EdgeInsets.only(bottom: tokens.spacing.gap),
      padding: EdgeInsets.zero,
      child: FushiListItem(
        // 一行副标题 + 36px 图标已经自带高度；rowVertical(12) 是给两行副标题
        // 留的，这里收到 gap(8)，行高从 ~89 降到 ~62。
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal - 4,
          vertical: tokens.spacing.gap,
        ),
        titleMaxLines: 2,
        subtitleMaxLines: subtitleMaxLines,
        leading: _ExtensionIcon(url: iconUrl ?? ''),
        title: Row(
          children: <Widget>[
            Flexible(child: Text(title)),
            if (contentWarning) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: tokens.radii.chipRadius,
                ),
                child: Text(
                  '18+',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: subtitle,
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (enabled != null)
              Switch.adaptive(value: enabled!, onChanged: onEnabledChanged),
            if (secondaryLabel != null)
              TextButton(
                style: _actionStyle,
                onPressed: onSecondary,
                child: Text(secondaryLabel!),
              ),
            if (primaryLabel != null)
              TextButton(
                style: _actionStyle,
                onPressed: onPrimary,
                child: Text(primaryLabel!),
              ),
          ],
        ),
      ),
    );
  }

  /// 文字动作按钮默认左右各 16 的内边距，两个按钮并排就把标题挤到只剩半屏。
  /// 收到 10 并保留 44 高的点按目标（触摸端最小命中区）。
  static final ButtonStyle _actionStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    minimumSize: const Size(0, 44),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// Shared responsive language/search row for extension repositories.
class MangaExtensionFilters extends StatelessWidget {
  const MangaExtensionFilters({
    required this.languages,
    required this.selectedLanguage,
    required this.languageLabel,
    required this.allLanguagesLabel,
    required this.searchHint,
    required this.searchController,
    required this.searchQuery,
    required this.onLanguageChanged,
    required this.onSearchChanged,
    required this.onSearchCleared,
    super.key,
    this.keyPrefix = 'manga_extension',
  });

  final List<String> languages;
  final String selectedLanguage;
  final String languageLabel;
  final String allLanguagesLabel;
  final String searchHint;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final Widget languageFilter = DropdownButtonFormField<String>(
      value: languages.contains(selectedLanguage) ? selectedLanguage : '*',
      decoration: InputDecoration(labelText: languageLabel),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(
          key: ValueKey<String>('${keyPrefix}_language_*'),
          value: '*',
          child: Text(allLanguagesLabel),
        ),
        for (final String language in languages)
          DropdownMenuItem<String>(
            key: ValueKey<String>('${keyPrefix}_language_$language'),
            value: language,
            child: Text(language.toUpperCase()),
          ),
      ],
      onChanged: (String? value) => onLanguageChanged(value ?? '*'),
    );
    final Widget searchField = TextField(
      key: ValueKey<String>('${keyPrefix}_search_field'),
      controller: searchController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: searchHint,
        border: const OutlineInputBorder(),
        suffixIcon: searchQuery.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: onSearchCleared,
              ),
      ),
      onChanged: onSearchChanged,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            children: <Widget>[
              languageFilter,
              const SizedBox(height: 12),
              searchField,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: languageFilter),
            const SizedBox(width: 12),
            Expanded(child: searchField),
          ],
        );
      },
    );
  }
}

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.url});

  final String url;

  /// 有图标和没图标的行必须等宽起排：占位 `Icon` 是 24、网络图标是 32 时，
  /// 同一列表里两种行的标题左缘差 8px，扫下来像没对齐。统一成一个固定
  /// 36×36 的圆角容器，图标缺失时容器里居中放占位符。
  static const double _size = 36;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    const Widget fallback = Center(
      child: Icon(Icons.extension_outlined, size: 20),
    );
    return SizedBox.square(
      dimension: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaces.group,
          borderRadius: tokens.radii.chipRadius,
        ),
        child: url.isEmpty
            ? fallback
            : ClipRRect(
                borderRadius: tokens.radii.chipRadius,
                // 🔴 不要换回 Image.network（BUG-1715）：NetworkImage 走 Flutter
                // 内部 HttpClient，接不进应用代理出口；桌面上索引经代理能拉到、
                // 图标直连 raw.githubusercontent.com 却失败，列表就全是占位图标。
                child: Image(
                  image: AppHttpImage(url),
                  width: _size,
                  height: _size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback,
                  loadingBuilder:
                      (_, Widget child, ImageChunkEvent? progress) =>
                          progress == null ? child : fallback,
                ),
              ),
      ),
    );
  }
}
