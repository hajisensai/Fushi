// 守卫：入库的 macOS 精简 ffmpeg/ffprobe 的架构必须与 app 本体一致——**恰好 arm64**。
//
// 2026-10 起 macOS 版只出 Apple Silicon（arm64），不再支持 Intel Mac：Runner 工程
// `EXCLUDED_ARCHS = x86_64`，release-desktop.yml 有「Verify macOS app is arm64-only」门。
// 随包 helper 因此也只要 arm64；多出来的 x86_64 切片是 ~21 MB/个的死重。
//
// 背景（BUG-1668）：当年 app 本体是 universal、helper 却是 arm64-only，Intel Mac 上
// app 照常启动、每次 `Process.start('…/Contents/MacOS/ffmpeg')` 却被内核以 EBADARCH
// 拒掉，制卡音频/封面、内封字幕、片段导出全线静默失效。那条不变式（helper 架构覆盖
// app 本体架构）现在由 release-desktop.yml 的装配步按 `lipo -archs` 逐个核对；本守卫
// 不依赖 `lipo`/`file`（Windows、Linux CI 上同样有效），纯字节解析 Mach-O / FAT header，
// 钉住入库二进制恰好是 arm64：
//   - 缺 arm64 → 所有受支持的 Mac 上 helper 都跑不起来；
//   - 多出 x86_64 → 有人 vendor 回了旧的 universal 产物（死重，也说明 ffmpeg-min.yml
//     又在出双架构）。
//
// 失败修法：重跑 .github/workflows/ffmpeg-min.yml（macOS job 只出 arm64），把 artifact
// 重新 vendor 到 third_party/ffmpeg-min/macos/，并记得 `git update-index --chmod=+x`。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Mach-O / FAT 魔数。FAT 头恒为大端；瘦 Mach-O 头按自身字节序。
const int _kFatMagic = 0xCAFEBABE;
const int _kFatMagic64 = 0xCAFEBABF;
const int _kMachoMagic32 = 0xFEEDFACE;
const int _kMachoMagic64 = 0xFEEDFACF;

/// cputype 常量（mach/machine.h）。`| 0x01000000` 是 CPU_ARCH_ABI64。
const int _kCpuTypeX8664 = 0x01000007;
const int _kCpuTypeArm64 = 0x0100000C;

const Map<int, String> _cpuNames = <int, String>{
  _kCpuTypeX8664: 'x86_64',
  _kCpuTypeArm64: 'arm64',
  0x00000007: 'i386',
  0x0000000C: 'arm',
};

/// app 本体（`flutter build macos --release`，Runner `EXCLUDED_ARCHS = x86_64`）的架构。
/// 捆绑 helper 必须恰好是这些：少了跑不起来，多了是死重。
const List<int> _requiredCpuTypes = <int>[_kCpuTypeArm64];

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/tool/ffmpeg-min/build-ffmpeg-min.sh').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 tool/ffmpeg-min/build-ffmpeg-min.sh 的仓库根'
      '（从 ${Directory.current.path} 向上）');
}

/// 解析 Mach-O，返回其包含的全部 cputype。瘦二进制返回 1 个，universal 返回 N 个。
List<int> machoCpuTypes(Uint8List bytes) {
  if (bytes.length < 8) fail('文件太短，不是 Mach-O（${bytes.length} 字节）');
  final ByteData bd = ByteData.sublistView(bytes);
  final int magicBe = bd.getUint32(0, Endian.big);

  if (magicBe == _kFatMagic || magicBe == _kFatMagic64) {
    final int count = bd.getUint32(4, Endian.big);
    // 每条 fat_arch 20 字节（fat_arch_64 是 32），cputype 在开头。
    final int stride = magicBe == _kFatMagic ? 20 : 32;
    final List<int> types = <int>[];
    for (int i = 0; i < count; i++) {
      final int off = 8 + i * stride;
      if (off + 4 > bytes.length) break;
      types.add(bd.getUint32(off, Endian.big));
    }
    return types;
  }

  // 瘦 Mach-O：魔数按自身字节序，cputype 紧随其后。
  final int magicLe = bd.getUint32(0, Endian.little);
  if (magicLe == _kMachoMagic32 || magicLe == _kMachoMagic64) {
    return <int>[bd.getUint32(4, Endian.little)];
  }
  if (magicBe == _kMachoMagic32 || magicBe == _kMachoMagic64) {
    return <int>[bd.getUint32(4, Endian.big)];
  }
  fail('不是 Mach-O：magic=0x${magicBe.toRadixString(16).padLeft(8, '0')}');
}

String _describe(List<int> types) =>
    types.map((int t) => _cpuNames[t] ?? '0x${t.toRadixString(16)}').join(', ');

void main() {
  final Directory root = _repoRoot();

  for (final String tool in <String>['ffmpeg', 'ffprobe']) {
    test('vendored macOS $tool 必须恰好是 arm64', () {
      final File file = File('${root.path}/third_party/ffmpeg-min/macos/$tool');
      expect(file.existsSync(), isTrue,
          reason: '缺 ${file.path}——macOS 发布包靠它，见 release-desktop.yml 的装配步。');

      final List<int> types = machoCpuTypes(file.readAsBytesSync());
      expect(
        types,
        unorderedEquals(_requiredCpuTypes),
        reason: 'third_party/ffmpeg-min/macos/$tool 的架构是 ${_describe(types)}，'
            '期望恰好 ${_describe(_requiredCpuTypes)}。macOS 版只出 Apple Silicon，'
            '缺 arm64 时 helper 在所有 Mac 上都无法执行（制卡音频与封面、内封字幕抽取、'
            '片段导出全线静默失效，BUG-1668）；多出 x86_64 是旧 universal 产物的死重。'
            '修法：重跑 .github/workflows/ffmpeg-min.yml（macOS job 只出 arm64），'
            '把 artifact 重新 vendor 到 third_party/ffmpeg-min/macos/，'
            '并 `git update-index --chmod=+x`。',
      );
    });
  }

  // 纯解析器自测：守卫的判据本身必须能分清 universal 与瘦二进制，否则它可能只是
  // 恰好在真文件上返回了「对」的答案。构造最小 FAT / 瘦 Mach-O 头各验一次。
  test('machoCpuTypes 能分清 universal 与瘦二进制', () {
    final BytesBuilder fat = BytesBuilder();
    final ByteData fatHdr = ByteData(8)
      ..setUint32(0, _kFatMagic, Endian.big)
      ..setUint32(4, 2, Endian.big);
    fat.add(fatHdr.buffer.asUint8List());
    for (final int cpu in <int>[_kCpuTypeX8664, _kCpuTypeArm64]) {
      final ByteData arch = ByteData(20)..setUint32(0, cpu, Endian.big);
      fat.add(arch.buffer.asUint8List());
    }
    expect(machoCpuTypes(fat.toBytes()), <int>[_kCpuTypeX8664, _kCpuTypeArm64]);

    final ByteData thin = ByteData(8)
      ..setUint32(0, _kMachoMagic64, Endian.little)
      ..setUint32(4, _kCpuTypeArm64, Endian.little);
    expect(machoCpuTypes(thin.buffer.asUint8List()), <int>[_kCpuTypeArm64]);
  });
}
