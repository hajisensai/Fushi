/// 「横幅…」面板里「本地已有的图」这一类候选（视频分集剧照 / 帧缩略图、合集成员的
/// 横幅）：一批盘上路径 → 只读文件头量尺寸 → 留横版的 → [BannerCandidate]。
///
/// 量尺寸在后台 isolate（[selectWideLocalImages] 经 `compute`），只看文件头、不解码；
/// 最多量 [kBannerEpubScanLimit] 张、留 [kBannerBookCandidateLimit] 张，与书中候选
/// 同一组上限。与设计系统无关（纯数据装配）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'package:fushi/src/media/banner/banner_book_scan.dart'
    show kBannerBookCandidateLimit, kBannerEpubScanLimit, kBannerWideMinAspect;
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/reader/illustration_aspect_probe.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;

/// 网格预览的解码宽度（同书中候选）。
const int kBannerLocalPreviewWidth = 480;

/// 一张本地候选图（[label] 进卡片角标）。
typedef BannerLocalImage = ({String path, String? label});

/// isolate 入口：按序量 [paths] 的前 [kBannerEpubScanLimit] 张（去重），留宽高比不低于
/// [kBannerWideMinAspect] 的，封顶 [kBannerBookCandidateLimit] 张。读不出尺寸的（文件
/// 不在 / 不是图）跳过。返回入选的下标与尺寸。
List<({int index, int width, int height})> selectWideLocalImages(
  List<String> paths,
) {
  final List<int> probed = <int>[];
  final Set<String> seen = <String>{};
  for (int i = 0; i < paths.length; i++) {
    if (probed.length >= kBannerEpubScanLimit) break;
    if (paths[i].isEmpty || !seen.add(paths[i])) continue;
    probed.add(i);
  }
  final Map<String, ImagePixelSize> sizes = probeIllustrationSizes(<String>[
    for (final int i in probed) paths[i],
  ]);
  final List<({int index, int width, int height})> out =
      <({int index, int width, int height})>[];
  for (final int i in probed) {
    final ImagePixelSize? size = sizes[paths[i]];
    if (size == null || size.width <= 0 || size.height <= 0) continue;
    if (size.width / size.height < kBannerWideMinAspect) continue;
    out.add((index: i, width: size.width, height: size.height));
    if (out.length >= kBannerBookCandidateLimit) break;
  }
  return out;
}

/// [images] 里的横版图 → 候选（id = `<idPrefix>-<序号>`，原图就是盘上那个文件）。
Future<List<BannerCandidate>> loadLocalBannerCandidates(
  List<BannerLocalImage> images, {
  required String idPrefix,
}) async {
  if (images.isEmpty) return const <BannerCandidate>[];
  final List<({int index, int width, int height})> picked = await compute(
    selectWideLocalImages,
    <String>[for (final BannerLocalImage image in images) image.path],
  );
  return <BannerCandidate>[
    for (final ({int index, int width, int height}) pick in picked)
      BannerCandidate(
        id: '$idPrefix-${pick.index}',
        preview: resizedFileImage(
          File(images[pick.index].path),
          width: kBannerLocalPreviewWidth,
        ),
        resolve: () async => File(images[pick.index].path),
        label: images[pick.index].label,
        width: pick.width,
        height: pick.height,
      ),
  ];
}
