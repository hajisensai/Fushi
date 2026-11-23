/// 媒体标题清洗的引擎入口：全部媒体共用一份实现（显示层 [cleanImportedTitle] +
/// 检索 / 键层原语）。
///
/// 实现住在 fushi_core（`src/utils/media_title_clean.dart`）：存量标题清理是 schema
/// 迁移步（v172），迁移只能用 core 里的代码。引擎与 app 一律从本文件引用，不各写
/// 一份「什么是 CRC 标签 / 扩展名」的正则。
library;

export 'package:fushi_core/fushi_core.dart'
    show
        cleanImportedTitle,
        importedTitleExtensionPattern,
        isCrcHex,
        kCrcHexSource,
        kCrcTagSource,
        kImportedTitleExtensionSource,
        kImportedTitleFileExtensions,
        stripImportedFileExtension,
        stripTrailingCrcTags,
        trailingCrcTagsPattern;
