/// 浏览器扩展字体端点（`/api/extension/fonts*`）向 app 侧要的能力，以及双方共用的
/// wire 形状。接口放在 sync 层是为了让 [YomitanApiServer] 不依赖字体页；实现在
/// `BrowserExtensionFontCatalog`（models 层，持有 AppModel）。
library;

/// 目录里一个真实存在的字体文件。
class ExtensionFontEntry {
  const ExtensionFontEntry({
    required this.id,
    required this.name,
    required this.family,
    required this.ext,
    required this.path,
  });

  /// 字体目录 id（`font_N`），扩展拿它打 `/api/extension/fonts/file?id=`。
  final String id;

  /// 目录里的显示名。
  final String name;

  /// app 运行期真正注册的 CSS family 名（`ReaderCustomFontCss.normalizedFontFamilyName`），
  /// 扩展的 `@font-face` 用这个，才能与 app 内渲染同名。
  final String family;

  /// 文件扩展名，小写、无点（`ttf` / `otf` / `woff` / `woff2` / `ttc`）。
  final String ext;

  /// 绝对路径。**不上 wire**：扩展只按 id 取字节。
  final String path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'family': family,
        'ext': ext,
      };

  /// `@font-face` 跨源加载要的 MIME：按扩展名映射，未知扩展名回 octet-stream。
  static String contentTypeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'ttc':
        return 'font/collection';
      default:
        return 'application/octet-stream';
    }
  }
}

/// 推荐字体表的一项 + 是否已在目录里。
class ExtensionRecommendedFont {
  const ExtensionRecommendedFont({
    required this.name,
    required this.nameJa,
    required this.description,
    required this.license,
    required this.installed,
  });

  final String name;
  final String nameJa;
  final String description;
  final String license;
  final bool installed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'nameJa': nameJa,
        'description': description,
        'license': license,
        'installed': installed,
      };
}

enum ExtensionFontDownloadStatus {
  /// 已装或刚下好：[ExtensionFontDownloadOutcome.fonts] 是对应目录条目。
  ok,

  /// 名字不在推荐表里。
  unknownFont,

  /// 多源全失败 / 回的不是字体：[ExtensionFontDownloadOutcome.detail] 是原因。
  downloadFailed,
}

class ExtensionFontDownloadOutcome {
  const ExtensionFontDownloadOutcome.ok(this.fonts)
      : status = ExtensionFontDownloadStatus.ok,
        detail = null;

  const ExtensionFontDownloadOutcome.unknownFont()
      : status = ExtensionFontDownloadStatus.unknownFont,
        fonts = const <ExtensionFontEntry>[],
        detail = null;

  const ExtensionFontDownloadOutcome.failed(this.detail)
      : status = ExtensionFontDownloadStatus.downloadFailed,
        fonts = const <ExtensionFontEntry>[];

  final ExtensionFontDownloadStatus status;
  final List<ExtensionFontEntry> fonts;
  final String? detail;
}

/// app 侧注入给 [YomitanApiServer] 的字体能力。未注入时三个端点一律 404。
abstract class ExtensionFontApi {
  /// 目录里所有 `path` 非空且文件真实存在的字体，按目录顺序。
  Future<List<ExtensionFontEntry>> listFonts();

  /// 推荐字体表，逐项标注是否已在目录里。
  Future<List<ExtensionRecommendedFont>> listRecommended();

  /// 按目录 id 找字体；不在目录或文件不存在时 null。**只按 id**，不接受路径。
  Future<ExtensionFontEntry?> findFont(String id);

  /// 下载推荐表里的 [name]（已装则直接回已有条目）。同名并发调用必须串行去重。
  Future<ExtensionFontDownloadOutcome> downloadRecommended(String name);
}
