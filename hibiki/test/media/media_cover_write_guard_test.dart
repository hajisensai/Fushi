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
//   目标路径），Dart 侧无字节可交给收口，见其库注释。
// - lib/src/sync/**：互联层远端封面（remote_cover_image / remote_cover_cache，
//   协议字段 coverUrl 冻结）是网络缓存，本轮不收编（见 MediaCoverService 类注释）。
//
// ③（BUG-1394 补的覆盖洞）**豁免是逐函数的，不是整文件的**。②/① 都是「同一个
//    文件里同时出现派生 + 裸写」才报，于是「派生点与写盘点跨文件」两边都逃：
//    anime_download_importer.dart 派生了 videoCoverFileName 目的地但自己不写盘
//    （→ ② 的 rawWrite 不命中直接放行），真正的裸 writeAsBytes 在被整文件豁免的
//    video_cover_extractor.dart 里（→ ② 的白名单直接 continue）。结果是给「导入
//    期首写」开的豁免被三个**覆盖写**调用点（番剧下载重放、流媒体换封面、导入
//    弹窗重取）复用，同路径重下后 UI 命中旧解码缓存 = 显示旧图，守卫全绿。
//    这条把豁免收成「白名单文件里**哪些函数**可以裸写」的显式清单：新增裸写函数
//    或把已收口的函数改回裸写都会红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

void main() {
  final Directory libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));

  String norm(String path) => p.split(path).join('/');

  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(dartFiles().length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
  });

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
    // 注释（行注释 / doc / 块注释）里的提法不算调用：先做共享词法掩码再匹配，
    // 否则「见 VideoStorage.coversDir()」这类文档引用会误报。TODO-2477：旧写法是
    // 删除式 `replaceAll(RegExp(r'//.*$'), '')`，块注释与串里的 `//` 两个方向都错。
    const Set<String> allowed = <String>{
      // 收口自身。
      'lib/src/media/media_cover_service.dart',
      // 导入期首写产线（ffmpeg 子进程直写目标路径），见其库注释。缩略图下载路
      // 已收口，本条豁免的实际边界由下面第 ③ 条逐函数钉死（BUG-1394）。
      'lib/src/media/video/video_cover_extractor.dart',
    };
    final List<String> offenders = <String>[];
    for (final File f in dartFiles()) {
      final String path = norm(f.path);
      if (allowed.contains(path)) continue;
      // 互联层远端封面本轮不收编（协议 coverUrl 冻结，W 系列另册处理）。
      if (path.startsWith('lib/src/sync/')) continue;
      final String src = maskComments(f.readAsStringSync());
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

  test('白名单文件的裸写豁免逐函数登记（跨文件派生+写盘的覆盖洞，BUG-1394）', () {
    // 白名单文件里**允许**裸写封面的函数全名单。空 = 该文件已无裸写。
    // 新增裸写函数、或把已收口的函数改回裸 writeAsBytes，都会让本用例红。
    const Map<String, Set<String>> allowedRawWriters = <String, Set<String>>{
      // 收口自身：两个入口的 .tmp 写 + rename 就是收口实现本体。
      'lib/src/media/media_cover_service.dart': <String>{
        'applyCoverFile',
        'applyCoverBytes',
      },
      // ffmpeg 两条路由子进程写盘，Dart 侧无字节；下载路已改走
      // MediaCoverService.applyCoverBytes，故本文件不该再有任何裸写。
      'lib/src/media/video/video_cover_extractor.dart': <String>{},
    };
    final RegExp rawWrite =
        RegExp(r'writeAsBytes\(|\.copy\(|\.rename\(|openWrite\(');
    // 顶层声明 / 类成员声明的行首标识（`static Future<void> applyCoverBytes({`、
    // `Future<String?> downloadVideoCoverToPath({` 等）：缩进 ≤2 且缩进之后**立刻**
    // 是标识符，取 `(` / `{` 前的最后一个标识符为函数名。缩进阈值把函数体里的
    // `if (...) {` / `} catch (_) {` 这类控制流挡在外面（它们缩进 ≥4，且行首不是
    // 「类型 空格 名字」的形状）。
    final RegExp declaration =
        RegExp(r'^ {0,2}(?:static )?(?:[\w<>?,]+ )+(\w+)\s*[({]');

    allowedRawWriters.forEach((String path, Set<String> allowed) {
      // 先等长掩码再按行切：块注释与串里的 `//` 都掩得掉，且列宽与原文一致，
      // 所以 declaration 正则仍能在掩码行上正确匹配（代码本身原样保留）。
      final List<String> lines =
          maskComments(File(path).readAsStringSync()).split('\n');
      final Set<String> found = <String>{};
      String current = '<file-scope>';
      for (final String line in lines) {
        final RegExpMatch? decl = declaration.firstMatch(line);
        if (decl != null) current = decl.group(1)!;
        if (rawWrite.hasMatch(line)) {
          found.add(current);
        }
      }
      expect(found, allowed,
          reason: '$path 里的裸写封面函数与登记名单不符。豁免是逐函数的：'
              '「导入期首写」的理由只对 ffmpeg 子进程写盘成立，Dart 侧有字节的路'
              '（被覆盖写场景跨文件复用）必须走 MediaCoverService.applyCoverBytes。\n'
              '实际=$found 登记=$allowed');
    });
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
