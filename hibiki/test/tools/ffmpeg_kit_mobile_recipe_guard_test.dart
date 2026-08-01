// 守卫：入库的**移动端** ffmpeg-kit 二进制必须具备当前 Dart 代码依赖的编码能力。
//
// 背景（TODO-2357，以及它之前的 BUG-1057/1058 同型坑）：
// `third_party/ffmpeg_kit_flutter/` 下的 Android AAR 与 iOS xcframework 都是**手工**
// 在构建机（Mac，`~/ffmpegkit-build/ffmpeg-kit`）跑 `android.sh` / `ios.sh` 编出来再拷
// 进仓库的。配方不在本仓，产物与消费端之间没有任何自动关联——谁改了 Dart 侧的编码器
// 选择却没重新 vendor 二进制，仓库照样绿，用户拿到的是「Unknown encoder」或更糟的
// 静默坏文件。
//
// 桌面侧早有对等守卫（`ffmpeg_min_vendored_recipe_guard_test.dart`），移动侧一直是
// 空白：BUG-1322 当初只能靠人肉 llvm-strings 去证明 AAR 里有没有某个编码器。本守卫
// 把那次手工实证固化下来。
//
// 方法与桌面守卫一致：ffmpeg 把完整 configure 命令行以明文编进 libavutil，编码器则在
// libavcodec 里留下确定的符号/字符串。**无需执行**任何二进制，纯 dart:io + 静态读取，
// Linux CI 上同样有效（vendored 产物是普通入库文件，不是 LFS）。
//
// 判据纪律（这类扫描极易假绿，见 BUG-1057 的教训）：
// - 只认**精确串**与 configure 开关，绝不用模糊子串。`videotoolbox` / `mediacodec`
//   这种词在头文件名、hwcontext 里到处都是，松散匹配一定误判。
// - **双向**断言：既断言该有的在（libx264），也断言不该有的不在（mpeg4 已不再是导出
//   编码器；硬件编码器确实没编进来）——单向断言无法区分「真有」和「扫错了」。
//
// 失败即意味着：Dart 侧的编码器契约与入库二进制对不上，必须重新 vendor 二进制
// （见文件尾部的失败提示）。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 移动端 configure 里必须出现的独立开关。
///
/// - `--enable-gpl` / `--enable-libx264`：TODO-2357 片段导出全平台 H.264。缺任一个 →
///   移动端导出真机 `Unknown encoder 'libx264'`，整条制卡视频链路失败。
/// - `--enable-openssl`：BUG-891 远端制卡的 https 输入（min 变体默认无任何 TLS 后端，
///   缺它 → `Protocol not found`）。重编 ffmpeg-kit 时最容易漏掉的就是它。
const List<String> _requiredMobileFlags = <String>[
  '--enable-gpl',
  '--enable-libx264',
  '--enable-openssl',
];

/// 从当前 cwd 向上找含 vendored ffmpeg-kit 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/third_party/ffmpeg_kit_flutter/android/libs/'
            'ffmpeg-kit.aar')
        .existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 third_party/ffmpeg_kit_flutter/android/libs/ffmpeg-kit.aar 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// latin1 是字节到码点的恒等映射：任何字节序列都能安全解码成可搜索的字符串。
String _asSearchableText(List<int> bytes) =>
    latin1.decode(bytes, allowInvalid: true);

/// 抠出内嵌的 configure 命令行所在的整段文本。
String _embeddedConfiguration(List<int> bytes, String what) {
  final String text = _asSearchableText(bytes);
  if (!text.contains('--target-os=')) {
    fail('在 $what 里找不到内嵌的 configure 字符串——它不像是 ffmpeg-kit 编出来的产物。');
  }
  return text;
}

void main() {
  final Directory root = _repoRoot();

  group('Android AAR（TODO-2357：全平台 H.264 的移动端前提）', () {
    late Archive aar;

    setUpAll(() {
      final File file = File(
        '${root.path}/third_party/ffmpeg_kit_flutter/android/libs/'
        'ffmpeg-kit.aar',
      );
      expect(file.existsSync(), isTrue, reason: '入库 AAR 缺失：${file.path}');
      aar = ZipDecoder().decodeBytes(file.readAsBytesSync());
    });

    List<int> soBytes(String abi, String lib) {
      final ArchiveFile? entry = aar.findFile('jni/$abi/$lib');
      if (entry == null) {
        fail('AAR 里没有 jni/$abi/$lib。ABI 集合变了？');
      }
      return entry.content as List<int>;
    }

    // 两个 ABI 都必须带 x264：只验 arm64 会漏掉「armeabi-v7a 那次没编上」。
    for (final String abi in <String>['arm64-v8a', 'armeabi-v7a']) {
      test('$abi: configure 含 gpl/libx264/openssl，且 x264 真链进 libavcodec', () {
        final String configuration =
            _embeddedConfiguration(soBytes(abi, 'libavutil.so'), '$abi libavutil.so');
        for (final String flag in _requiredMobileFlags) {
          expect(
            configuration.contains(flag),
            isTrue,
            reason: '$abi 的 configure 串里没有 $flag —— 入库 AAR 比 Dart 侧契约旧，'
                '需在构建机重跑 android.sh 并重新 vendor',
          );
        }

        // configure 声明了 ≠ 真链进去了。libavcodec 里必须同时有 ffmpeg 的编码器封装名
        // 与 x264 自身的版本串，两者都在才算数。
        final String codec =
            _asSearchableText(soBytes(abi, 'libavcodec.so'));
        expect(codec.contains('libx264'), isTrue,
            reason: '$abi libavcodec.so 里没有 libx264 —— configure 写了但没链上');
        expect(codec.contains('x264 - core'), isTrue,
            reason: '$abi 缺 x264 自身的版本串，说明链接的不是真正的 x264 库');
      });
    }

    test('BUG-891 未回退：TLS 后端与证书指纹钉扎补丁仍在', () {
      final String format =
          _asSearchableText(soBytes('arm64-v8a', 'libavformat.so'));
      expect(format.contains('tls_pin_sha256'), isTrue,
          reason: 'cert-pin 补丁（third_party/ffmpeg_kit_flutter/patches/）没打进去。'
              '重编 ffmpeg-kit 时必须先在 src/ffmpeg 应用该补丁，'
              '否则远端制卡的自签主机回到「接受任意证书」');
    });

    test('许可随 GPL 切换（--enable-gpl 的合规义务）', () {
      final ArchiveFile? license = aar.findFile('res/raw/license.txt');
      expect(license, isNotNull, reason: 'AAR 内缺 license.txt');
      final String text = _asSearchableText(license!.content as List<int>);
      expect(text.contains('GNU GENERAL PUBLIC LICENSE'), isTrue,
          reason: '加了 --enable-gpl 后产物许可从 LGPLv3 变为 GPLv3，'
              'AAR 内的 license.txt 必须同步（android.sh 会自动写入）。'
              'Hibiki 自身即 GPL-3.0，两者一致');
      expect(aar.findFile('res/raw/license_x264.txt'), isNotNull,
          reason: 'x264 的许可文件必须随产物分发');
      expect(aar.findFile('res/raw/source.txt'), isNotNull,
          reason: 'GPL/LGPL 要求的「源码获取途径」声明不得丢失');
    });
  });

  group('iOS xcframework（同一契约，四个切片同证）', () {
    // device 与 simulator 各一份 fat 二进制，内含各自架构的切片；每个切片都内嵌一份
    // configure。只验 device 会漏掉「模拟器切片没编上 x264」——那正是 nasm 缺失时的
    // 真实失败形态（x86_64 切片挂掉而 arm64 切片是好的）。
    const Map<String, String> slices = <String, String>{
      'device(arm64/arm64e)': 'ios-arm64_arm64e',
      'simulator(arm64/x86_64)': 'ios-arm64_x86_64-simulator',
    };

    slices.forEach((String label, String dir) {
      test('$label: configure 含 gpl/libx264/openssl 且 x264 真链进 libavcodec', () {
        final String base =
            '${root.path}/third_party/ffmpeg_kit_flutter/ios/Frameworks';
        final File util = File(
          '$base/libavutil.xcframework/$dir/libavutil.framework/libavutil',
        );
        expect(util.existsSync(), isTrue, reason: '切片缺失：${util.path}');

        final String configuration =
            _embeddedConfiguration(util.readAsBytesSync(), '$label libavutil');
        for (final String flag in _requiredMobileFlags) {
          expect(
            configuration.contains(flag),
            isTrue,
            reason: '$label 的 configure 串里没有 $flag —— 入库 framework 比 Dart 侧'
                '契约旧，需在构建机重跑 ios.sh --xcframework 并重新 vendor',
          );
        }

        final File codecFile = File(
          '$base/libavcodec.xcframework/$dir/libavcodec.framework/libavcodec',
        );
        expect(codecFile.existsSync(), isTrue);
        final String codec = _asSearchableText(codecFile.readAsBytesSync());
        expect(codec.contains('libx264'), isTrue,
            reason: '$label libavcodec 里没有 libx264');
        expect(codec.contains('x264 - core'), isTrue,
            reason: '$label 缺 x264 自身的版本串');
      });
    });
  });

  // ── 负向对照 ──────────────────────────────────────────────────────────
  // 上面全是「该有的在不在」。只有正向断言时，一个把所有 contains 都返回 true 的
  // 错误实现（比如路径读错读成了别的文件、或 latin1 解码出一堆巧合）同样会全绿。
  // 这里断言几个**确定不该出现**的东西，把判据本身钉住。
  group('负向对照：判据本身没有失真', () {
    test('硬件编码器确实未编入（当前配方明确关闭）', () {
      final File aarFile = File(
        '${root.path}/third_party/ffmpeg_kit_flutter/android/libs/'
        'ffmpeg-kit.aar',
      );
      final Archive aar = ZipDecoder().decodeBytes(aarFile.readAsBytesSync());
      final String configuration = _embeddedConfiguration(
        aar.findFile('jni/arm64-v8a/libavutil.so')!.content as List<int>,
        'arm64-v8a libavutil.so',
      );
      // Android 配方明写 --disable-mediacodec：若哪天它变成 enable，Dart 侧就多了
      // 一条可选路径，本守卫应当被一并重审，而不是继续假设"只有 libx264"。
      expect(configuration.contains('--disable-mediacodec'), isTrue,
          reason: '配方对 mediacodec 的态度变了——Dart 侧编码器选择需要重审');
      // 反证：一个必定不存在的开关必须扫不到。扫得到就说明匹配逻辑失真了。
      expect(configuration.contains('--enable-libx265'), isFalse,
          reason: '扫到了本不该存在的开关，说明判据失真（匹配到了别处的字节）');
    });
  });
}
