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
/// BUG-2099 之后这份清单大幅缩短：凡是**按扩展名**选文件的调用点全部收编到
/// [kPickerImpl] 的 `pickSystemFilePath(s)` / `pickFilesByExtensions`，因为把扩展名
/// 过滤交给平台在移动端会让文件**置灰点不动**（安卓 SAF 只认 MIME，file_picker 把
/// `MimeTypeMap` 查不到的扩展名静默丢掉；iOS 的 `dyn.*` UTI 同理）。
/// 剩下的都是**不按扩展名过滤**的调用（`FileType.image` / `FileType.any`），或
/// Windows 专属入口——它们不受那条 MIME 丢弃路径影响。
const Map<String, String> kFilePickerAllowlist = <String, String>{
  // 不按扩展名过滤（FileType.image / FileType.any）：没有可被丢弃的扩展名清单。
  'lib/src/media/audiobook/book_import_dialog.dart':
      '书籍封面：FileType.image，选中即拷进 app 存储与原路径脱钩'
          '（书文件本身已收编到 pickFilesByExtensions）',
  'lib/src/pages/implementations/miscellaneous_settings_page.dart':
      '应用图标：FileType.image，拷进 app 存储（image_picker 在 Windows 无实现，TODO-1239）',
  'lib/src/utils/misc/gallery_image_picker.dart':
      '制卡图片：FileType.image，选中即读字节写进卡片，不长期引用',
  'lib/src/media/manga/manga_ocr_settings_section.dart':
      '手动导入的 OCR 模型文件：FileType.any（模型文件无统一扩展名），选中即按清单'
          '校验字节数并拷进 app 的模型目录（MangaOcrModelImporter，原子 rename），'
          '原路径不入库。同一入口的「选择文件夹」走 pickRealDirectoryPath。',
  // Windows 专属入口（见 galgame SOP）：桌面原生对话框直接吃扩展名字符串，过滤
  // 可靠，且安卓那条腿根本跑不到。
  'lib/src/mining/galgame_add_flow.dart':
      'galgame exe：Windows 专属（见 galgame SOP），安卓无此入口',
  'lib/src/pages/implementations/texthooker_page.dart':
      'galgame exe / LunaHook tsv：Windows 专属（见 galgame SOP）',
};

/// 允许出现 `FileType.custom` 的文件 → 理由。**只减不增**。
///
/// 为什么要单独守这个字面量（BUG-2099）：安卓 SAF 只按 MIME 过滤，file_picker 的
/// `FileUtils.getMimeTypes()` 逐个扩展名查 `MimeTypeMap.getMimeTypeFromExtension()`，
/// **查不到就静默跳过**。`.mdx` / `.dsl` / `.ifo` / `.ass` / `.ssa` / `.aix` /
/// `.lua` / `.glsl` 都不在系统词表里，于是这些文件在选择器里全部灰掉、点不动
/// ——用户两次报同一个根因（「文件选择器直接对 mdx 是灰的」「导入视频字幕只能选
/// srt 不能选 ass」）。上面的登记制只拦「裸调 pickFiles」，拦不住「走了统一入口
/// 但又把 custom 传进去」，所以这条判据直接钉住字面量本身。
const Map<String, String> kCustomFileTypeAllowlist = <String, String>{
  // saveFile（保存对话框）：type 只决定「保存成什么类型」，不会让已存在的文件在
  // 选择器里置灰，不受 MIME 丢弃影响。
  'lib/src/pages/implementations/media_sources_view.dart': 'saveFile：导出刮削诊断包 zip',
  'lib/src/pages/implementations/reader_fushi/audiobook.part.dart':
      'saveFile：导出有声书片段',
  'lib/src/pages/implementations/video_fushi/clip_export.part.dart':
      'saveFile：导出视频片段',
  'lib/src/sync/sync_settings_schema/backup.part.dart': 'saveFile：导出备份 zip',
  'lib/src/utils/misc/log_exporter.dart': 'saveFile：导出日志',
  'lib/src/media/audiobook/asr_transcribe_sheet.dart': 'saveFile：导出转录字幕 srt',
  // Windows 专属入口：桌面原生对话框按扩展名过滤可靠。
  'lib/src/mining/galgame_add_flow.dart':
      'galgame exe：Windows 专属（见 galgame SOP），安卓无此入口',
  'lib/src/pages/implementations/texthooker_page.dart':
      'galgame exe / LunaHook tsv：Windows 专属（见 galgame SOP）',
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

/// 扫 `lib/` 下所有 .dart，返回**正文里**出现 [literal] 的文件相对路径集合。
/// 与 [_filesCalling] 共用同一条枚举 + 注释掩码路径（注释里的举例不算数）。
Set<String> _filesContaining(String literal) {
  final Set<String> hits = <String>{};
  for (final File e in _scannedDartFiles()) {
    final String code = maskCommentsAndScriptLines(e.readAsStringSync());
    if (code.contains(literal)) hits.add(e.path.replaceAll(r'\', '/'));
  }
  return hits;
}

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

  test('按扩展名选文件：lib/ 下不得再裸用 FileType.custom（BUG-2099）', () {
    final Set<String> users = _filesContaining('FileType.custom')
      ..remove(kPickerImpl);
    final Set<String> unexpected =
        users.difference(kCustomFileTypeAllowlist.keys.toSet());
    expect(
      unexpected,
      isEmpty,
      reason: '安卓 SAF 只认 MIME：file_picker 会把 MimeTypeMap 查不到的扩展名'
          '（mdx / dsl / ifo / ass / ssa / aix / lua / glsl…）静默丢掉，这些文件'
          '在选择器里是灰的、点不动。按扩展名选文件请走 $kPickerImpl 的 '
          'pickSystemFilePath(s) / pickFilesByExtensions（移动端自动降级成 '
          'FileType.any + Dart 端校验，桌面维持原生过滤）。',
    );
  });

  test('FileType.custom 豁免清单不得虚挂', () {
    final Set<String> users = _filesContaining('FileType.custom')
      ..remove(kPickerImpl);
    for (final String path in kCustomFileTypeAllowlist.keys) {
      expect(
        users,
        contains(path),
        reason: '$path 已不再用 FileType.custom，请把它从豁免清单删掉（只减不增）。',
      );
    }
  });

  test('统一入口文件本身存在（清单里的路径不是拼错的）', () {
    expect(File(kPickerImpl).existsSync(), isTrue);
    for (final String path in <String>[
      ...kDirectoryPickerAllowlist.keys,
      ...kFilePickerAllowlist.keys,
      ...kCustomFileTypeAllowlist.keys,
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path 不存在');
    }
  });
}
