/// 守卫：文件/目录选择器的统一入口纪律。
///
/// ## 为什么要守
///
/// `lib/src/media/import/real_path_directory_picker.dart` 是「选文件/选目录」的
/// 统一入口，存在的全部理由是**安卓**：
///
/// - `FilePicker.getDirectoryPath()` 在安卓是把 tree URI **拼**成一个路径串返回
///   （volume 映射不出来时直接退化成 `/`），而 SAF 授的是 URI 权限、不是路径权限
///   ——targetSdk 35 下没拿到全文件访问，`dart:io` 读这个路径必失败。扫描根、下载
///   根、数据根、mpv 着色器目录全是「选完之后要用 `dart:io` 反复读」的语义，于是
///   功能直接坏掉（真实症状：安卓加了本地来源库，却永远扫不出书）。
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

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

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
  'lib/src/settings/settings_schema_video.dart':
      'mpv Lua 脚本：选中即 importLuaScriptFile 拷进 app 的 mpv_scripts 目录，与原路径脱钩',
  'lib/src/pages/implementations/video_fushi/subtitle.part.dart':
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
  'lib/src/pages/implementations/onboarding_wizard_page.dart':
      '新手引导「选择本地推荐包」：备份 zip 选中即走 runBackupImportFlowForFile 校验并恢复，'
          '与 backup.part.dart 同语义，不长期引用',
  'lib/src/utils/misc/gallery_image_picker.dart': '制卡图片：选中即读字节写进卡片，不长期引用',
  'lib/src/pages/implementations/video_shader_dialog.dart':
      '着色器文件：选中即拷进 mpv_shaders 目录',
  'lib/src/pages/implementations/home_video_page.dart': '视频页文件选择：当场消费',
  'lib/src/media/manga/mihon/mihon_extensions_page.dart':
      'Mihon 扩展 APK：选中即 readAsBytes 拷进 app 存储的 tmp/extension-<sha>.apk.part 再校验安装，原路径不入库',
  'lib/src/media/manga/manga_sources_page.dart':
      'Aidoku 扩展 .aix：选中即 inspect 校验并 AidokuPackageStore.install 拷进 app 存储，原路径不入库（与上面 Mihon APK 同语义）',
  // (a) 长期引用，但**仅 Windows** 路径可达，安卓那条腿根本跑不到：
  // （2026-08-13 选 exe 逻辑从 games_library_page 收敛到共享动作 galgame_add_flow）
  'lib/src/mining/galgame_add_flow.dart':
      'galgame exe：Windows 专属（见 galgame SOP），安卓无此入口',
  'lib/src/pages/implementations/texthooker_page.dart':
      'galgame exe / LunaHook tsv：Windows 专属（见 galgame SOP）',
  // 原有一条 'lib/src/settings/settings_schema_lookup.dart'（本地音频库导入）已于
  // BUG-1667 修掉并按「清单只减不增」删除：它改走 pickRealFilePathDetailed，安卓不再
  // 先复制进 app cache（6 GB 的 android.db 曾需要 2 倍内部存储才导得进来）。
};

/// 扫 `lib/` 下所有 .dart，返回调用了 `.<member>(` 的文件相对路径集合。
///
/// **受体一律不看，且容忍换行**。只匹配 `FilePicker.platform.getDirectoryPath(`
/// 这一种字面写法的守卫是假绿——实测两种写法都能静默绕过它：
/// - `dart format` 把长表达式折成 `await FilePicker.platform\n    .getDirectoryPath(`；
/// - 先 `final FilePickerPlatform fp = FilePicker.platform;` 再 `fp.getDirectoryPath(`。
/// 所以这里改成正则 `\.\s*<member>\s*\(`（`\s` 跨行）。`getDirectoryPath` /
/// `pickFiles` 这两个成员名在本仓只属于 file_picker，受体无关匹配不会误伤。
///
/// 只算**真调用**：注释先换成等长空白（`page_focus_ownership.dart` 在文档注释里
/// 举例提到了 `FilePicker.platform.pickFiles()`，那不是调用点）。
///
/// 剥离用共享的 `maskCommentsAndScriptLines`，而不是旧的「丢掉整行 `//`」。旧写法
/// 放过块注释与行尾注释，两个方向都会错：
/// - 注释掉的示例 `/* FilePicker.platform.pickFiles() */` 被当成真调用点 ⇒ 禁止型
///   断言假红；
/// - 反过来，把一处真调用暂时注释成 `/* ... */` 后它从命中集合里消失 ⇒「豁免清单
///   不得虚挂」那两条**要求型**断言凭空变红。
/// 掩码取旧行式剥离与 Dart 词法掩码的并集：整行 `//`（含三引号 JS/CSS 语料里的）
/// 照旧掩掉，同时补上块注释与行尾注释。等长掩码保留换行，正则里的 `\s` 仍能跨行
/// 匹配 `dart format` 折出来的 `FilePicker.platform\n    .pickFiles(`。
/// [_filesCalling] 的枚举面，单独抽出来只为了让「扫描规模哨兵」能断言**同一条**
/// 扫描路径（哨兵另写一份枚举只能证明磁盘上有文件，证明不了守卫真的读到了它们）。
List<File> _scannedDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'))
    .toList();

Set<String> _filesCalling(String member) {
  final RegExp call = RegExp(r'\.\s*' + member + r'\s*\(');
  final Set<String> hits = <String>{};
  for (final File e in _scannedDartFiles()) {
    final String code = maskCommentsAndScriptLines(e.readAsStringSync());
    if (call.hasMatch(code)) hits.add(e.path.replaceAll(r'\', '/'));
  }
  return hits;
}

void main() {
  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(_scannedDartFiles().length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
  });

  test('目录选择器：除统一入口与登记豁免外，不得裸调 getDirectoryPath', () {
    final Set<String> callers = _filesCalling('getDirectoryPath')
      ..remove(kPickerImpl);
    final Set<String> unexpected =
        callers.difference(kDirectoryPickerAllowlist.keys.toSet());
    expect(
      unexpected,
      isEmpty,
      reason: '目录选完要用 dart:io 遍历，安卓裸 getDirectoryPath 拼出来的路径串没有'
          '全文件访问权限读不了（甚至退化成 /）。请改用 pickRealDirectoryPath（见 '
          '$kPickerImpl）。',
    );
  });

  test('目录豁免清单不得虚挂（清单里的文件必须真的还在裸调）', () {
    final Set<String> callers = _filesCalling('getDirectoryPath')
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
    final Set<String> callers = _filesCalling('pickFiles')..remove(kPickerImpl);
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
    final Set<String> callers = _filesCalling('pickFiles')..remove(kPickerImpl);
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
