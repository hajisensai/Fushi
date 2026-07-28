/// 守卫：文件/目录选择器的统一入口纪律。
///
/// ## 为什么要守
///
/// `lib/src/media/import/real_path_directory_picker.dart` 是「选文件/选目录」的
/// 统一入口，存在的全部理由是**安卓**：
///
/// - `FilePicker.getDirectoryPath()` 在安卓返回的是 tree content URI 解析串，
///   `dart:io` 拿它遍历恒空。扫描根、下载根、数据根、mpv 着色器目录全是「选完之后
///   要用 `dart:io` 反复读」的语义，拿到 content URI 串 = 功能直接坏掉。
/// - `FilePicker.pickFiles()` 在安卓会把选中文件**复制一份到 app cache** 再返回缓存
///   路径：白拷一份大文件，且清缓存后该路径失效、长期引用悬空。
///
/// 统一入口按平台分流（桌面/iOS 原样调 file_picker，安卓走 SAF 解析真实路径 + 权限
/// 降级逃生口）。散在各处裸调 `FilePicker.platform.*` 就是绕过这套分流。
///
/// ## 守什么
///
/// **目录选择器：零豁免（一个例外，见下）**。目录是「选完要遍历」的强语义，没有
/// 「当场消费完就扔」的用法，所以不留自由裁量空间——新增裸 `getDirectoryPath(` 一律红。
///
/// **文件选择器：登记制**。文件确实有两类合法用法：
/// (a) 长期引用绝对路径（必须真实路径，走统一入口）；
/// (b) 导入时当场读完就拷进 app 存储（缓存副本无所谓，系统选择器反而更好用——
///     用户熟悉，且能触达 Downloads / 云盘 / 最近文件，见 board 1360）。
/// 分不出 (a)/(b) 的自动判据，所以改为**把现存裸调点全部登记在案**：每条附理由，
/// 新增未登记的调用点即红。这不是放行，是让这笔债可见、可审、只减不增。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 统一入口自身——它就是那层分流实现，当然要调 file_picker。
const String kPickerImpl =
    'lib/src/media/import/real_path_directory_picker.dart';

/// 允许裸调 `getDirectoryPath(` 的文件 → 理由。
///
/// 只有一条，且是**刻意**不走统一入口的：词典目录导入在安卓有自己的原生
/// `pickAndCopyDirectory` 分支（整目录复制进临时目录后导入，导完即删），压根不需要
/// 真实路径；裸 `getDirectoryPath()` 只在桌面/iOS 这条腿上跑，语义与统一入口一致。
/// 若哪天那条原生分支被拿掉，这一条也要跟着收回。
const Map<String, String> kDirectoryPickerAllowlist = <String, String>{
  'lib/src/pages/implementations/dictionary_dialog_page.dart':
      '安卓另有原生 pickAndCopyDirectory 复制分支，此处仅桌面/iOS 生效',
};

/// 允许裸调 `pickFiles(` 的文件 → 理由。**只减不增**。
///
/// 绝大多数是上面 (b) 类：选中即读、读完即拷进 app 存储，缓存副本无害。
/// 标「TODO」的是 (a) 类真实欠账，应在后续 PR 迁到统一入口。
const Map<String, String> kFilePickerAllowlist = <String, String>{
  // (b) 当场消费：解析成 cue / 转 EPUB / 拷进存储后即与原路径脱钩。
  'lib/src/media/audiobook/book_import_dialog.dart':
      '书文件与封面：导入时拷进 app 存储，与原路径脱钩（EPUB 一条 TODO：安卓白拷一份，可迁 pickRealFilePath）',
  'lib/src/media/video/video_import_dialog.dart':
      'm3u8 播放列表：选中即解析成 playlist，不长期引用',
  'lib/src/pages/implementations/video_hibiki/subtitle.part.dart':
      '字幕：选中即解析成 cue（与 pickSystemFilePath 同语义，board 1360）',
  'lib/src/pages/implementations/dictionary_dialog_page.dart':
      '词典包：选中即经 FFI 导入，导完与原路径脱钩',
  'lib/src/pages/implementations/custom_fonts_page.dart':
      '字体文件：校验魔数后拷进 app 字体目录',
  'lib/src/pages/implementations/miscellaneous_settings_page.dart':
      '应用图标：拷进 app 存储（image_picker 在 Windows 无实现，TODO-1239）',
  'lib/src/pages/implementations/profile_management_page.dart':
      'Profile JSON：选中即读入并落库',
  'lib/src/sync/sync_settings_schema/backup.part.dart': '备份 zip：选中即校验并恢复，不长期引用',
  'lib/src/utils/misc/gallery_image_picker.dart': '制卡图片：选中即读字节写进卡片，不长期引用',
  'lib/src/pages/implementations/video_shader_dialog.dart':
      '着色器文件：选中即拷进 mpv_shaders 目录',
  'lib/src/pages/implementations/home_video_page.dart': '视频页文件选择：当场消费',
  // (a) 长期引用，但**仅 Windows** 路径可达，安卓那条腿根本跑不到：
  'lib/src/pages/implementations/games_library_page.dart':
      'galgame exe：Windows 专属（见 galgame SOP），安卓无此入口',
  'lib/src/pages/implementations/texthooker_page.dart':
      'galgame exe / LunaHook tsv：Windows 专属（见 galgame SOP）',
  // (a) TODO：桌面「引用原文件不复制」时长期引用绝对路径；安卓恒复制故当前不坏。
  'lib/src/settings/settings_schema_lookup.dart':
      '本地音频库：桌面可选「引用原文件」长期引用（安卓恒复制，故当前不坏）',
};

/// 扫 `lib/` 下所有 .dart，返回含指定裸调的文件相对路径集合。
///
/// 只算**真调用**：跳过以 `///` 开头的文档注释行（`page_focus_ownership.dart` 在
/// 注释里举例提到了 `FilePicker.platform.pickFiles()`，那不是调用点）。
Set<String> _filesCalling(String needle) {
  final Directory root = Directory('lib');
  final Set<String> hits = <String>{};
  for (final FileSystemEntity e in root.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final String rel = e.path.replaceAll(r'\', '/');
    for (final String line in e.readAsLinesSync()) {
      final String trimmed = line.trimLeft();
      if (trimmed.startsWith('///') || trimmed.startsWith('//')) continue;
      if (line.contains(needle)) {
        hits.add(rel);
        break;
      }
    }
  }
  return hits;
}

void main() {
  test('目录选择器：除统一入口与登记豁免外，不得裸调 getDirectoryPath', () {
    final Set<String> callers =
        _filesCalling('FilePicker.platform.getDirectoryPath(')
          ..remove(kPickerImpl);
    final Set<String> unexpected =
        callers.difference(kDirectoryPickerAllowlist.keys.toSet());
    expect(
      unexpected,
      isEmpty,
      reason: '目录选完要用 dart:io 遍历，安卓裸 getDirectoryPath 给的是 content URI 串、'
          '遍历恒空。请改用 pickRealDirectoryPath（见 $kPickerImpl）。',
    );
  });

  test('目录豁免清单不得虚挂（清单里的文件必须真的还在裸调）', () {
    final Set<String> callers =
        _filesCalling('FilePicker.platform.getDirectoryPath(')
          ..remove(kPickerImpl);
    for (final String path in kDirectoryPickerAllowlist.keys) {
      expect(
        callers,
        contains(path),
        reason: '$path 已不再裸调 getDirectoryPath，请把它从豁免清单删掉——'
            '清单只减不增，虚挂条目会让下一个人以为这里还有债。',
      );
    }
  });

  test('文件选择器：裸调 pickFiles 的文件必须已登记在案', () {
    final Set<String> callers = _filesCalling('FilePicker.platform.pickFiles(')
      ..remove(kPickerImpl);
    final Set<String> unexpected =
        callers.difference(kFilePickerAllowlist.keys.toSet());
    expect(
      unexpected,
      isEmpty,
      reason: '新增裸调 FilePicker.pickFiles。若选中的路径会被**长期引用**（存库/复扫/'
          '启动），必须走 pickRealFilePath；若只是导入时当场读完就拷进 app 存储，'
          '请在 kFilePickerAllowlist 里登记并写明理由。',
    );
  });

  test('文件豁免清单不得虚挂', () {
    final Set<String> callers = _filesCalling('FilePicker.platform.pickFiles(')
      ..remove(kPickerImpl);
    for (final String path in kFilePickerAllowlist.keys) {
      expect(
        callers,
        contains(path),
        reason: '$path 已不再裸调 pickFiles，请把它从豁免清单删掉（清单只减不增）。',
      );
    }
  });

  test('统一入口文件本身存在（清单里的路径不是拼错的）', () {
    expect(File(kPickerImpl).existsSync(), isTrue);
    for (final String path in <String>[
      ...kDirectoryPickerAllowlist.keys,
      ...kFilePickerAllowlist.keys,
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path 不存在');
    }
  });
}
