/// galgame 元数据源枚举与源描述。
///
/// 契约见 `docs/design/galgame-library-reina-parity.md` §2。新增数据源 = 在这里加一个
/// 枚举值 + 写一个 adapter + 在 service 的 registry 注册；`galgame_sources` 表是纵表，
/// 加源**零 schema 变更**。
library;

/// 在线元数据源。[key] 是持久化字符串（落 `galgame_sources.source` 列），**不可随意改**。
enum GalgameMetadataSource {
  /// Bangumi（番组计划），`https://bgm.tv`。
  bgm(key: 'bgm', label: 'Bangumi'),

  /// The Visual Novel Database，`https://vndb.org`。
  vndb(key: 'vndb', label: 'VNDB');

  const GalgameMetadataSource({required this.key, required this.label});

  /// 持久化键（DB 列值 / JSON 值）。
  final String key;

  /// UI 展示名（品牌名，不进 i18n）。
  final String label;

  /// 容错解析持久化键：null / 空串 / 未知值一律返回 null（脏数据不崩）。
  static GalgameMetadataSource? fromKey(Object? key) {
    if (key is! String) {
      return null;
    }
    final String normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    for (final GalgameMetadataSource source in GalgameMetadataSource.values) {
      if (source.key == normalized) {
        return source;
      }
    }
    return null;
  }
}

/// `galgames.primarySource` 的两个**非源**取值（契约 §1.1）：多源合并 / 纯用户自定义。
/// 与 [GalgameMetadataSource.key] 同一命名空间，故集中定义避免各处手写字面量。
const String kGalgamePrimarySourceMixed = 'mixed';

/// 见 [kGalgamePrimarySourceMixed]。
const String kGalgamePrimarySourceCustom = 'custom';
