/// Bangumi 封面 URL 的统一解析。
///
/// 当前 API 的 `images.large` 通常直接指向无缩放参数的原图，例如
/// `https://lain.bgm.tv/pic/cover/l/...jpg`；其它尺寸可能是
/// `/r/800/pic/cover/l/...jpg` 或旧式 `/pic/cover/c|m|s|g/...jpg`。
/// 刮削结果会长期落盘，不能把候选预览用的缩略图永久保存成媒体封面，因此所有
/// Bangumi 刮削入口都通过本文件选择候选并还原原图 URL。
library;

/// 从 Bangumi subject 的 `images` / 兼容 `image` 字段取原图 URL。
///
/// 字段优先级仍与 API 语义一致：`large → common → medium → small → grid`；
/// 无论命中哪个尺寸，都由 [bangumiOriginalImageUrl] 去掉 CDN 缩放层。
String? bangumiOriginalCoverUrl(Map<Object?, Object?> subject) {
  final Object? images = subject['images'];
  if (images is Map) {
    for (final String key in const <String>[
      'large',
      'common',
      'medium',
      'small',
      'grid',
    ]) {
      final String? url = bangumiOriginalImageUrl(images[key]);
      if (url != null) return url;
    }
  }
  return bangumiOriginalImageUrl(subject['image']);
}

/// 把一条 Bangumi CDN 封面地址正规化为上传原图地址。
///
/// 非 Bangumi CDN 地址不改写，只负责 trim；这样测试源、代理源或未来 API 返回的
/// 独立图床仍可照常下载。
String? bangumiOriginalImageUrl(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.toLowerCase() != 'lain.bgm.tv') {
    return trimmed;
  }

  final RegExp derivativePath = RegExp(
    r'^/(?:r/[^/]+/)?pic/cover/[lcmsg]/',
  );
  if (!derivativePath.hasMatch(uri.path)) return trimmed;

  final String originalPath = uri.path.replaceFirst(
    derivativePath,
    '/pic/cover/l/',
  );
  return uri.replace(path: originalPath).toString();
}
