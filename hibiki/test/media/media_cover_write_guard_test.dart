// 封面落盘收口守卫（审计 §1-A / BUG-1118 根因固化）。
//
// 「同路径覆盖写封面后必须双键驱逐解码缓存」这条不变量此前靠每个落盘点自觉补
// evictLocalCoverCache——BUG-1118 的三处刮削落盘正是漏补的教训。收口后该不变量
// 由 MediaCoverService.applyCoverFile / applyCoverBytes 结构性保证（写盘与驱逐
// 收在同一函数）。本守卫用源码扫描钉死两件事：
//
// ① evict 只许出现在收口链路里（定义处 / 服务 / 书 override 统一写入口）——
//    新代码不得再手写「写盘 + evict」对，只能改走服务；
// ② 出现「封面目的地派生 + 原始写盘调用」的 lib/ 文件必须引用
//    MediaCoverService.applyCover*（即经收口写盘），白名单外不得裸写封面路径。
//
// 豁免（记录在案）：
// - media_cover_service.dart：收口自身。
// - media/video/video_cover_extractor.dart：导入期首写产线（ffmpeg 子进程直写
//   目标路径 / 流媒体缩略图下载），目标路径此前无解码缓存，见其库注释。
// - lib/src/sync/**：互联层远端封面（remote_cover_image / remote_cover_cache，
//   协议字段 coverUrl 冻结）是网络缓存，本轮不收编（见 MediaCoverService 类注释）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final Directory libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));

  String norm(String path) => p.split(path).join('/');

  test('evictLocalCoverCache 只许出现在收口链路（新落盘点必须改走 MediaCoverService）', () {
    // 定义处 + 服务 + 书 override 统一写入口（setOverrideThumbnail* 的历史收口，
    // MediaCoverService.applyBookCoverOverride 薄路由到它）。
    const Set<String> allowed = <String>{
      'lib/src/utils/cover_image.dart',
      'lib/src/media/media_cover_service.dart',
      'lib/src/media/media_source.dart',
    };
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (allowed.contains(path)) continue;
      if (f.readAsStringSync().contains('evictLocalCoverCache(')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件手写了 evictLocalCoverCache——封面「写盘→驱逐」必须走 '
            'MediaCoverService.applyCoverFile/applyCoverBytes 收口，不得再散点手补：\n'
            '${offenders.join('\n')}');
  });

  test('封面目的地写盘必须经 MediaCoverService.applyCover*（白名单外禁裸写）', () {
    // 封面目的地派生标记：三岛目录/文件名的唯一派生入口。
    final RegExp destMarker = RegExp(
        r'videoCoverFileName\(|videoCoversDirectory\(|gameCoversDirectory\(|VideoStorage\.coversDir\(');
    // 原始写盘调用（对文件的写/拷/换名）。
    final RegExp rawWrite =
        RegExp(r'writeAsBytes\(|\.copy\(|\.rename\(|openWrite\(');
    // 行注释（含 doc 注释）里的提法不算调用：逐行剥掉 `//` 之后再匹配，
    // 否则「见 VideoStorage.coversDir()」这类文档引用会误报。
    final RegExp lineComment = RegExp(r'//.*$', multiLine: true);
    const Set<String> allowed = <String>{
      // 收口自身。
      'lib/src/media/media_cover_service.dart',
      // 导入期首写产线（ffmpeg 直写 / 缩略图下载），见其库注释。
      'lib/src/media/video/video_cover_extractor.dart',
    };
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (allowed.contains(path)) continue;
      // 互联层远端封面本轮不收编（协议 coverUrl 冻结，W 系列另册处理）。
      if (path.startsWith('lib/src/sync/')) continue;
      final String src = f.readAsStringSync().replaceAll(lineComment, '');
      if (!destMarker.hasMatch(src)) continue;
      if (!rawWrite.hasMatch(src)) continue;
      if (src.contains('MediaCoverService.applyCover')) continue;
      offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: '这些文件推导了封面目的地路径且有原始写盘调用，但没有经 '
            'MediaCoverService.applyCoverFile/applyCoverBytes 收口（BUG-1118 '
            '的「落盘后忘 evict」正是这么回归的）：\n${offenders.join('\n')}');
  });

  test('收口方法本体存在且包含「写盘→驱逐」结构', () {
    final String service =
        File('lib/src/media/media_cover_service.dart').readAsStringSync();
    expect(service.contains('applyCoverFile'), isTrue);
    expect(service.contains('applyCoverBytes'), isTrue);
    expect(service.contains('evictLocalCoverCache(destPath)'), isTrue,
        reason: '收口方法必须在写盘成功后驱逐 destPath 的双键解码缓存');
  });
}
