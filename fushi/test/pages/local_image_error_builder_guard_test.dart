import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2496：本地图片渲染点必须自带解码失败兜底。
///
/// 错误日志里那两条同毫秒的 `resolving an image codec / Invalid image data`（栈只到
/// `FileImage._loadAsync`）来自**没有任何 onError 监听者**的 `ImageStreamCompleter`：
/// 只有这种情况框架才走 `FlutterError.reportError`。写侧入口已拒收坏文件，但磁盘上
/// 历史坏文件与外部改动的文件仍会进来，渲染层不能靠「文件一定是好的」活着。
///
/// 守的是三种**裸**形态——它们没有别的兜底层（`CoverAspectProbe` / `PortraitCoverImage`
/// / `LandscapeCoverImage` / `FadeInImage(imageErrorBuilder:)` / `ShelfFileCover` 这些
/// 包装组件自己接 onError，不在扫描面内）：
/// 1. `Image.file(`；
/// 2. `Image(image: FileImage(` / `Image(image: ResizeImage(FileImage(`；
/// 3. `precacheImage(FileImage(`（不传 `onError` 时它自己 `FlutterError.reportError`）。
///
/// 每处调用的整个实参文本（括号配平）里必须出现 `errorBuilder:`（1/2）或
/// `onError:`（3）。范围用 `listSync(recursive: true)` 扫 `lib/` 全树，新文件自动进
/// 扫描面。
///
/// 已知例外：`crop_image_dialog_page.dart` 把 provider 交给第三方 `CropImage`，那个
/// 组件从不把传入的 `Image` 挂进树，`errorBuilder` 在那里是死代码——它的兜底是对话框
/// 自己在同一 completer 上挂带 `onError` 的 `ImageStreamListener`，本守卫第二条单独钉。
void main() {
  // 形态 → 该调用实参里必须出现的兜底参数名。
  // precacheImage 不传 onError 时会自己 FlutterError.reportError（silent），
  // 画廊前后两张相邻图同帧预热正是错误日志里「两条同毫秒」的形状。
  final Map<RegExp, String> bareForms = <RegExp, String>{
    RegExp(r'\bImage\.file\('): 'errorBuilder:',
    RegExp(r'\bImage\(\s*image:\s*(?:ResizeImage\(\s*)?FileImage\('):
        'errorBuilder:',
    RegExp(r'\bprecacheImage\(\s*(?:ResizeImage\(\s*)?FileImage\('): 'onError:',
  };

  List<File> dartFilesUnderLib() =>
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test(
    'lib/ 下每个裸 Image.file / Image(image: FileImage) 带 errorBuilder、precacheImage(FileImage) 带 onError',
    () {
      final List<String> offenders = <String>[];
      int hits = 0;
      for (final File f in dartFilesUnderLib()) {
        final String src = f.readAsStringSync().replaceAll('\r\n', '\n');
        final String code = maskComments(src);
        for (final MapEntry<RegExp, String> form in bareForms.entries) {
          for (final Match m in form.key.allMatches(code)) {
            hits++;
            // 锚点落在最外层调用的左括号后一位 → 括号配平取整个调用实参文本。
            final int open = code.indexOf('(', m.start);
            final EnclosingCall call = enclosingCall(src, open + 1);
            if (!maskComments(call.text).contains(form.value)) {
              final int line =
                  '\n'.allMatches(src.substring(0, m.start)).length + 1;
              offenders.add('${f.path.replaceAll('\\', '/')}:$line');
            }
          }
        }
      }
      // 防守卫塌成空集：仓里至少有这些已知调用点。
      expect(
        hits,
        greaterThanOrEqualTo(8),
        reason: '扫描面异常（命中太少），先核对 lib/ 路径与正则',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            '这些本地图片渲染/预热点没有兜底，坏文件解码失败会变成 '
            'FlutterError.reportError（BUG-2496）：\n${offenders.join('\n')}',
      );
    },
  );

  test('CropImageDialogPage 自己在 completer 上挂带 onError 的监听者', () {
    final String src = File(
      'lib/src/pages/implementations/crop_image_dialog_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final String code = maskComments(src);
    expect(
      RegExp(
        r'ImageStreamListener\([\s\S]*?onError:\s*_onDecodeError',
      ).hasMatch(code),
      isTrue,
      reason: 'CropImage 不渲染传入的 Image，兜底只能靠对话框自己的 onError 监听者',
    );
    expect(code, contains('.addListener(_decodeListener)'));
    expect(code, contains('removeListener(_decodeListener)'));
    expect(
      code,
      contains("logDiagnostic(\n      'CropImageDialogPage.coverDecode'"),
      reason: '坏文件仍要留诊断痕迹',
    );
  });

  test('main.dart 的 FlutterError.onError 把 silent 错误分流到 logDiagnostic', () {
    final String src = File(
      'lib/main.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int at = src.indexOf('FlutterError.onError = (details) {');
    expect(at, isNonNegative, reason: '必须装 FlutterError.onError');
    final String body = balancedBlockFrom(
      src,
      at,
      what: 'FlutterError.onError',
    );
    final String code = maskComments(body);
    // 分流判据是框架自己打的 `details.silent`，不是消息字符串清单。
    expect(
      RegExp(
        r'if\s*\(\s*details\.silent\s*\)\s*\{[\s\S]*?ErrorLogService\.instance\.logDiagnostic\(',
      ).hasMatch(code),
      isTrue,
      reason:
          'silent（图片解码失败等框架标非致命）的错误须走 logDiagnostic，'
          '不当致命、不同步 flush',
    );
    expect(
      code,
      contains('ErrorLogService.instance.logFatal('),
      reason: '非 silent 的仍是致命级同步落盘，不能顺手一起降级',
    );
  });
}
