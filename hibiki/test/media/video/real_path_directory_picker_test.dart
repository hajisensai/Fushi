import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../helpers/scan_scale.dart';

/// TODO-949 守卫：安卓「导入视频文件夹/选单个视频」改走**系统原生 SAF 选择器**
/// （`pickRealDirectory` / `pickRealFile`），原生把 content URI 解析回真实绝对
/// 路径，而非 app 自绘目录浏览器、也非 SAF content URI 直喂 dart:io。
///
/// 纯源码扫描守卫：
/// 1) 两个导入入口必须调统一的 `pickRealDirectoryPath` / `pickRealFilePath`。
/// 2) helper 自身按平台分支（安卓走权限 + 原生 SAF 通道，非安卓维持 getDirectoryPath /
///    pickFiles），且自绘浏览器 `_RealPathBrowser` 已彻底移除。
/// 「真实路径入口」的**全部**导出名。单数/复数是两个真实存在的入口
/// （`pickRealFilePath` / `pickRealFilePaths`），裸子串 `'pickRealFilePath('`
/// 匹配不到复数版（后面是 `s` 不是 `(`）——回归成 `pickRealFilePaths(...).first`
/// 会让下面的禁止型断言全部假绿。禁止判据必须逐个名字扫。
const List<String> kRealPathFileEntries = <String>[
  'pickRealFilePath(',
  'pickRealFilePaths(',
];

void main() {
  group('source guards: import folder uses unified real-path picker', () {
    test('video_import_dialog._pickFolder calls pickRealDirectoryPath', () {
      final String src = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
      expect(
        src.contains('pickRealDirectoryPath('),
        isTrue,
        reason: '视频导入文件夹必须走统一真实路径入口，'
            '而非直接 FilePicker.getDirectoryPath()（安卓返回不可用 SAF 串）',
      );
      // 直接的 getDirectoryPath 不该再出现在 _pickFolder 里。
      final int idx = src.indexOf('Future<void> _pickFolder()');
      final int end = src.indexOf('Future<', idx + 10);
      final String body = src.substring(idx, end);
      expect(
        body.contains('getDirectoryPath'),
        isFalse,
        reason: '_pickFolder 不得再直接调 getDirectoryPath',
      );
    });

    test('android branch uses native SAF channel, no custom browser', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      // 安卓改走原生 SAF：必须调 SAF channel 的两个真实路径方法。
      expect(
        src.contains("'pickRealDirectory'"),
        isTrue,
        reason: '目录选择必须调原生 SAF pickRealDirectory 方法',
      );
      expect(
        src.contains("'pickRealFile'"),
        isTrue,
        reason: '文件选择必须调原生 SAF pickRealFile 方法',
      );
      expect(
        src.contains('FushiChannels.saf'),
        isTrue,
        reason: '必须经统一 SAF channel 常量调用原生 handler',
      );
      // 自绘目录浏览器 + 其磁盘遍历死函数彻底移除，避免两套并存。
      expect(
        src.contains('_RealPathBrowser'),
        isFalse,
        reason: '自实现目录浏览器已被原生 SAF 取代，不得残留',
      );
      expect(
        src.contains('showModalBottomSheet'),
        isFalse,
        reason: '不再弹自绘选择表单',
      );
      expect(
        src.contains('listSubdirectories') ||
            src.contains('listFilesInDirectory'),
        isFalse,
        reason: '自绘浏览器的磁盘遍历死函数已随浏览器一并移除',
      );
    });

    test('helper branches on Android + permission before picking', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      // 非安卓维持 getDirectoryPath（桌面/iOS 真实路径）。
      expect(
        src.contains('TargetPlatform.android') &&
            src.contains('getDirectoryPath'),
        isTrue,
        reason: '非安卓平台必须保留 getDirectoryPath 行为',
      );
      // 安卓必须先确保 MANAGE_EXTERNAL_STORAGE 权限（下游 dart:io 读盘需要），不得静默吞。
      expect(
        src.contains('requestExternalStoragePermissions') &&
            src.contains('hasExternalStoragePermission'),
        isTrue,
        reason: '安卓分支必须先请求并校验全文件访问权限',
      );
    });

    // board 1112：视频本体导入走真实路径（绝对路径不复制到 cache）。
    // board 1360：字幕导入回退系统文件选择器（导入即消费、不长期引用绝对路径）。
    test(
        'video _pickVideo keeps real-path picker, '
        '_pickSubtitle reverts to system picker', () {
      final String src = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
      final String pickVideo = _methodBody(src, 'Future<void> _pickVideo()');
      final String pickSubtitle =
          _methodBody(src, 'Future<void> _pickSubtitle()');

      expect(
        pickVideo.contains('pickRealFilePath('),
        isTrue,
        reason: '单文件视频选择必须走真实路径入口，'
            '而非直接 FilePicker.pickFiles（安卓会复制到 cache、清缓存即失效）',
      );
      expect(
        pickVideo.contains('FilePicker.platform.pickFiles'),
        isFalse,
        reason: '_pickVideo 不得再直接调 FilePicker.pickFiles',
      );
      expect(
        pickSubtitle.contains('pickSystemFilePath('),
        isTrue,
        reason: '字幕导入即被解析消费，维持系统文件选择器（board 1360 用户诉求）',
      );
      for (final String entry in kRealPathFileEntries) {
        expect(
          pickSubtitle.contains(entry),
          isFalse,
          reason: '_pickSubtitle 不得再走真实路径入口 $entry（board 1360 回退系统选择器）',
        );
      }
    });

    test('audiobook audio/subtitle rows use file picker helper', () {
      final String audiobook =
          File('lib/src/media/audiobook/audiobook_import_dialog.dart')
              .readAsStringSync();
      final String book =
          File('lib/src/media/audiobook/book_import_dialog.dart')
              .readAsStringSync();

      final String audiobookAudio =
          _methodBody(audiobook, 'Future<void> _pickAudioFiles()');
      final String bookAudio = _methodBody(book, 'Future<void> _pickAudio()');
      final String audiobookAlignment =
          _methodBody(audiobook, 'Future<void> _pickAlignment()');
      final String bookSubtitle =
          _methodBody(book, 'Future<void> _pickSubtitle()');

      expect(
        audiobookAudio.contains('pickRealFilePaths('),
        isTrue,
        reason: '有声书补音频必须走文件选择 helper；iOS 的 FileType.audio '
            '会打开 MPMediaPickerController 资料库入口',
      );
      expect(
        bookAudio.contains('pickRealFilePaths('),
        isTrue,
        reason: '书籍导入附带音频必须走文件选择 helper；不得打开 iOS 资料库',
      );
      for (final String body in <String>[audiobookAudio, bookAudio]) {
        expect(body.contains('FileType.audio'), isFalse,
            reason: 'iOS FileType.audio 会走媒体资料库，不是 Files 文件选择');
        expect(body.contains('FilePicker.platform.pickFiles'), isFalse,
            reason: '音频选择应集中到 helper，避免各入口重新踩 iOS 分流');
      }

      expect(
        audiobookAlignment.contains('pickSystemFilePath('),
        isTrue,
        reason: '有声书对齐字幕/SMIL/JSON 导入即被消费，维持系统文件选择器（board 1360）；'
            'iOS .srt UTI 过滤问题由 helper 内部处理',
      );
      for (final String entry in kRealPathFileEntries) {
        expect(
          audiobookAlignment.contains(entry),
          isFalse,
          reason: '_pickAlignment 不得再走真实路径入口 $entry（board 1360 回退系统选择器）',
        );
      }
      expect(
        bookSubtitle.contains('pickSystemFilePath('),
        isTrue,
        reason: '书籍导入字幕导入即被消费，维持系统文件选择器（board 1360），和视频字幕一致',
      );
      for (final String entry in kRealPathFileEntries) {
        expect(
          bookSubtitle.contains(entry),
          isFalse,
          reason: '_pickSubtitle 不得再走真实路径入口 $entry（board 1360 回退系统选择器）',
        );
      }
    });

    test('production code never opens iOS media library via FileType.audio',
        () {
      final Directory libDir = Directory('lib');
      final List<String> offenders = <String>[];
      int scanned = 0;
      for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scanned++;
        final String src = entity.readAsStringSync();
        if (src.contains('FileType.audio')) offenders.add(entity.path);
      }

      // 这条判据是「命中数为 0」：扫描一旦塌成空集，它 100% 假绿，
      // 是全清单里最需要哨兵的形态之一。
      expectScanScale(scanned,
          what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);

      expect(
        offenders,
        isEmpty,
        reason: 'iOS FileType.audio opens MPMediaPickerController / media '
            'library. Audio-file imports must use pickRealFilePath(s) so the '
            'user stays in Files and .srt/audio sidecars share one path.',
      );
    });

    test('pickRealFilePath falls back to file_picker without full access', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      final String fileEntry =
          _methodBody(src, 'Future<String?> pickRealFilePath(');
      // 文件入口存在，且无全文件访问权限时回退（不静默返回 null / 不硬性要求授权）。
      expect(fileEntry.isNotEmpty, isTrue,
          reason: '必须存在 pickRealFilePath 文件入口');
      expect(
        fileEntry.contains('_fallbackPickFile'),
        isTrue,
        reason: '桌面/iOS 及安卓无全文件访问必须回退 file_picker（逃生口）',
      );
    });

    test('iOS filtered files are validated after picking public items', () {
      final String src =
          File('lib/src/media/import/real_path_directory_picker.dart')
              .readAsStringSync();
      expect(
        src.contains('Future<List<String>> pickRealFilePaths('),
        isTrue,
        reason: '有声书音频多选需要公共多文件 helper',
      );
      expect(
        src.contains('defaultTargetPlatform == TargetPlatform.iOS') &&
            src.contains('FileType.any') &&
            src.contains('_filterPickedFilesByExtension'),
        isTrue,
        reason: 'iOS .srt 等扩展可能解析成 dyn.* UTI，被 custom 过滤器隐藏；'
            '应先用 public.item 打开 Files，再按扩展名校验',
      );
    });
  });
}

/// 取从 [signature] 起到下一个顶层 `Future<`/`class ` 声明前的方法体切片，供
/// 源码守卫按方法定位。粗粒度但足够断言「这个方法里出现/不出现某调用」。
String _methodBody(String src, String signature) {
  final int idx = src.indexOf(signature);
  if (idx < 0) return '';
  final int nextFuture = src.indexOf('Future<', idx + signature.length);
  final int nextClass = src.indexOf('\nclass ', idx + signature.length);
  int end = src.length;
  for (final int cand in <int>[nextFuture, nextClass]) {
    if (cand >= 0 && cand < end) end = cand;
  }
  return src.substring(idx, end);
}
