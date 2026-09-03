import 'package:flutter/material.dart';

/// 一行「来源开关」的数据。
///
/// 发现来源、内置视频资源索引器都是同一形状：一个 id、一个名字、一句覆盖范围、
/// 一个开/关。两边各写一份 SwitchListTile 就会各自漂（key 命名、密度、副标题行数
/// 都不一样），所以行长什么样只由 [SourceToggleList] 说了算，两边只提供数据。
@immutable
class SourceToggleRow {
  const SourceToggleRow({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.enabled,
  });

  /// 源 id：既是停用清单里的记录名，也是本行 widget key 的后缀。
  final String id;
  final String title;

  /// 覆盖范围/说明。
  final String subtitle;
  final bool enabled;
}

/// 来源开关区的小节标题（图标 + 标题 + 说明）。
///
/// 「外部资源与字幕来源」里那份原本是私有的 `_sectionHeading`；发现来源区要和它
/// 长得一样，抄一份就会漂，所以提到共用层，原处改为委托。
class SourceSectionHeading extends StatelessWidget {
  const SourceSectionHeading({
    super.key,
    required this.title,
    required this.hint,
    this.icon,
  });

  final String title;
  final String hint;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一组来源开关行。
///
/// [keyPrefix] 决定每行的 widget key（`<prefix>-<sourceId>`），因而同一页上两组
/// 开关的 key 不会撞——集成测试和 widget 测试按这个 key 找行。
class SourceToggleList extends StatelessWidget {
  const SourceToggleList({
    super.key,
    required this.keyPrefix,
    required this.rows,
    required this.onChanged,
    this.icon = Icons.public_outlined,
  });

  final String keyPrefix;
  final List<SourceToggleRow> rows;

  /// 用户拨动某一行。异步：两边落地的都是偏好写入 + 运行时重建。
  final Future<void> Function(String sourceId, bool enabled) onChanged;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final SourceToggleRow row in rows)
          SwitchListTile.adaptive(
            key: ValueKey<String>('$keyPrefix-${row.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            secondary: Icon(icon),
            title: Text(row.title),
            subtitle: Text(row.subtitle, maxLines: 3),
            value: row.enabled,
            onChanged: (bool value) => onChanged(row.id, value),
          ),
      ],
    );
  }
}
