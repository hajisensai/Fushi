/// 来源库(扫描根,`MediaSources` 表)的媒体种类值域(命名统一 Phase 3.4 批 2)。
///
/// ⚠️ 与 [MediaKind](media_kind.dart) **不是**同一值域:来源库只分
/// 'book'/'video' 两类(book 源既装 EPUB 也装 SRT 书,不细分),`book`≠`epub`
/// 是真实语义差,不做合并——这正是 `MediaSources.mediaKind` 列「字段名叫
/// mediaKind 却装不下 MediaKind 值」的历史根源,本枚举把它显式化。
/// 跨域换算见 media_kind_mappings.dart 的既有模式(本值域暂无跨域映射需求)。
///
/// [dbValue] 即落库串,**逐字节冻结**(守卫:source_library_kind_test)。
enum SourceLibraryKind {
  book('book'),
  video('video');

  const SourceLibraryKind(this.dbValue);

  /// `MediaSources.mediaKind` 列的落库串。
  final String dbValue;

  /// 严格解析:未知串返回 null(调用方自行决定回退/报错)。
  static SourceLibraryKind? tryParse(String? raw) {
    for (final SourceLibraryKind kind in values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}
