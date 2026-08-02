// 守卫：入库的精简 ffmpeg 二进制必须**自包含**——不得依赖构建机上的
// 包管理器动态库（Homebrew / MacPorts / Linuxbrew / 用户家目录）。
//
// 背景（BUG-1443）：`third_party/ffmpeg-min/macos/ffmpeg` 是 ffmpeg-min workflow
// 在 GitHub macos runner 上 `brew install x264 svt-av1 webp` 之后编出来的。配方
// （tool/ffmpeg-min/build-ffmpeg-min.sh）只给 Windows 分支传了
// `--extra-ldflags=-static --pkg-config-flags=--static`，macOS 分支没有任何静态化
// 处理，于是三个 Homebrew 库全部以 **动态依赖** 留在产物里：
//
//   /opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib
//   /opt/homebrew/opt/webp/lib/libwebp.7.dylib
//   /opt/homebrew/opt/webp/lib/libwebpmux.3.dylib
//   /opt/homebrew/opt/x264/lib/libx264.165.dylib
//
// 用户机没有 Homebrew（绝大多数 Mac 都没有）→ dyld 找不到 → `Abort trap: 6`
// (exit 134) → 桌面制卡链（帧封面 / 句子音频 / cue 动图 / 片段导出 / 内封字幕
// 抽取）在 macOS 上全废。CI run 30733265391 的
// "Install vendored ffmpeg-min runtime into macOS bundle" 步就是这样炸的。
//
// 为什么既有守卫抓不到：
//   - ffmpeg_min_vendored_recipe_guard_test 只比对**内嵌 configure 串**与配方的
//     组件清单，`--enable-libsvtav1` 在两边都在，完全一致 → 绿。configure 串
//     描述的是「编了什么能力」，不描述「怎么链的」。
//   - desktop_ffmpeg_bundling_guard_test 只查 workflow 里有没有装配步。
//   - ffmpeg-min.yml 的 smoke-test 跑在**刚 brew install 过的同一台机器**上，
//     dylib 就在 /opt/homebrew 下，必然通过——它天然测不到「干净机器」。
//   - release-desktop.yml 的 `-version` 冒烟只在 macOS job 跑，而那是发版流水线：
//     等它红的时候，已经是发版被阻塞的时刻。
//
// 本守卫把这条能力搬到「任何平台的普通单测」里：Mach-O 的 LC_LOAD_DYLIB / ELF 的
// DT_NEEDED+RPATH 路径都是**明文字符串**存在二进制里的，无需 otool/objdump/dyld，
// 纯字节扫描即可断言。Windows CI、Linux CI 上同样有效。
//
// 判据不是「有没有出现某个魔法前缀」（那种黑名单永远漏），而是反过来：
// **凡是二进制里出现的、指向共享库的绝对路径，都必须落在系统目录白名单里**。
// 系统目录（/usr/lib、/System/Library、/lib、Windows 的裸 DLL 名）是每台机器都有
// 的；其它一切绝对路径都意味着「只有构建机上才有的东西」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许出现的共享库绝对路径前缀。
///
/// macOS：`/usr/lib/` 与 `/System/Library/` 由 dyld shared cache 提供，每台 Mac 必有
/// （libSystem.B.dylib / libz.1.dylib 走这里）。
/// Linux：`/lib/`、`/usr/lib/` 是 glibc 与系统库的家（本仓暂不 vendor Linux，先留着）。
///
/// 注意这里**不含** `/usr/local/`：那是 Homebrew（Intel Mac）与手工 make install 的
/// 落点，正是本守卫要抓的东西。
const List<String> _systemLibraryPrefixes = <String>[
  '/usr/lib/',
  '/System/Library/',
  '/lib/',
];

/// 已知的「构建机专有」前缀，只用于把失败信息写得能一眼看懂。
///
/// 命中与否**不改变**判定结果——判定由 [_systemLibraryPrefixes] 白名单决定。
const Map<String, String> _knownBuildEnvPrefixes = <String, String>{
  '/opt/homebrew/': 'Homebrew（Apple Silicon）',
  '/usr/local/Cellar/': 'Homebrew（Intel Mac）',
  '/usr/local/opt/': 'Homebrew（Intel Mac，opt 软链）',
  '/opt/local/': 'MacPorts',
  '/home/linuxbrew/': 'Linuxbrew',
  '/Users/': '构建机用户家目录',
  '/home/': '构建机用户家目录',
};

/// 一次扫一块的大小。二进制最大 ~17MB，1MiB 一块 = 十几次读，
/// 内存占用恒定，不把整个 exe 读进堆（third_party 下还会长更大的东西）。
const int _chunkSize = 1 << 20;

/// 相邻块之间的重叠字节数，防止一条路径串正好被块边界切断。
/// Mach-O 的 LC_LOAD_DYLIB 路径受 load command 大小限制，远小于 512。
const int _chunkOverlap = 512;

/// 绝对路径形状的字符串：以 `/` 开头，只含路径合法字符。
///
/// 二进制里的 C 字符串以 NUL 结尾，NUL 不在字符类里，所以一次匹配不会把两条相邻
/// 字符串粘成一条。
final RegExp _absolutePathPattern = RegExp(r'/[A-Za-z0-9_.+@/-]{3,255}');

/// 判断一个路径的 basename 是否是共享库。
///
/// macOS `libfoo.4.dylib` / Linux `libfoo.so.2.1` / `libfoo.so` 都算。
bool _looksLikeSharedLibrary(String path) {
  final int slash = path.lastIndexOf('/');
  final String base = slash < 0 ? path : path.substring(slash + 1);
  if (base.endsWith('.dylib')) return true;
  return RegExp(r'\.so(\.\d+)*$').hasMatch(base);
}

/// 流式扫描 [file]，返回其中所有**指向共享库、且不在系统白名单内**的绝对路径。
///
/// 返回值有序去重，便于失败信息稳定可读。
Set<String> scanForeignSharedLibraryPaths(File file) {
  final Set<String> found = <String>{};
  final RandomAccessFile handle = file.openSync();
  try {
    final int length = handle.lengthSync();
    int offset = 0;
    while (offset < length) {
      final int want =
          (offset + _chunkSize + _chunkOverlap).clamp(0, length) - offset;
      handle.setPositionSync(offset);
      final List<int> bytes = handle.readSync(want);
      // latin1 是字节到码点的恒等映射：任何字节序列都能安全解码成可正则搜索的
      // 字符串，且不会像 utf8 那样把非法序列折成替换字符而错位。
      final String text = latin1.decode(bytes, allowInvalid: true);
      for (final RegExpMatch match in _absolutePathPattern.allMatches(text)) {
        final String path = match.group(0)!;
        if (!_looksLikeSharedLibrary(path)) continue;
        final bool isSystem = _systemLibraryPrefixes
            .any((String prefix) => path.startsWith(prefix));
        if (!isSystem) found.add(path);
      }
      offset += _chunkSize;
    }
  } finally {
    handle.closeSync();
  }
  final List<String> sorted = found.toList()..sort();
  return sorted.toSet();
}

/// 给一条外部路径配上人类可读的来源说明。
String _describeOrigin(String path) {
  for (final MapEntry<String, String> entry in _knownBuildEnvPrefixes.entries) {
    if (path.startsWith(entry.key)) return '${entry.value}（${entry.key}）';
  }
  return '构建机专有路径';
}

/// 从当前 cwd 向上找含 third_party/ffmpeg-min 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (Directory('${dir.path}/third_party/ffmpeg-min').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 third_party/ffmpeg-min 的仓库根（从 ${Directory.current.path} 向上）');
}

String _fixHint(String platformDir) => '''

这个二进制在**没装对应包管理器的用户机器上直接 dyld 崩溃**（BUG-1443：
macOS 上 `Abort trap: 6` / exit 134），桌面制卡链全废。

修法（不是改守卫）：
  1. 改 tool/ffmpeg-min/build-ffmpeg-min.sh，让 $platformDir 分支把第三方库
     **静态**链进产物（Windows 分支的 `--extra-ldflags=-static
     --pkg-config-flags=--static` 就是这么做的，所以 windows/ffmpeg.exe 只
     import kernel32/msvcrt/ws2_32/secur32/bcrypt 这些系统 DLL）；
  2. gh workflow run ffmpeg-min.yml --ref develop -f ffmpeg_ref=n7.1.5；
  3. 下载对应 artifact 替换 third_party/ffmpeg-min/$platformDir/ 下的
     ffmpeg 与 ffprobe（macOS 侧记得 `git update-index --chmod=+x`）；
  4. 本守卫转绿即证明产物自包含。
禁止把发现的路径加进白名单——白名单只放**每台机器都有**的系统目录。''';

void main() {
  final Directory root = _repoRoot();
  final Directory vendorRoot = Directory('${root.path}/third_party/ffmpeg-min');

  group('ffmpeg-min 入库二进制自包含守卫（BUG-1443）', () {
    test('探测器本身有效：合成字节流里的 Homebrew dylib 路径必须被抓到', () {
      // 这条是守卫的自检。没有它，一个永远匹配不到东西的正则（比如某天有人把
      // 字符类改坏）会让整套断言退化成「恒绿」，而缺陷照样发版。
      // 断言字面量刻意不作为常量共享给扫描函数——它是独立的期望值。
      final Directory tmp = Directory.systemTemp.createTempSync('ffmin-guard');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File fake = File('${tmp.path}/fake-macho');
      fake.writeAsBytesSync(<int>[
        0xcf, 0xfa, 0xed, 0xfe, // Mach-O 64 魔数，只为形似
        ...latin1.encode('/usr/lib/libSystem.B.dylib'), 0,
        ...latin1.encode('/System/Library/Frameworks/Foo.framework/Foo'), 0,
        ...latin1.encode('/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib'),
        0,
        ...latin1.encode('/usr/local/Cellar/x264/r3108/lib/libx264.165.dylib'),
        0,
        ...latin1.encode('/opt/homebrew/opt/webp/lib/libwebp.7.dylib'), 0,
      ]);

      final Set<String> found = scanForeignSharedLibraryPaths(fake);
      expect(
        found,
        <String>{
          '/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib',
          '/opt/homebrew/opt/webp/lib/libwebp.7.dylib',
          '/usr/local/Cellar/x264/r3108/lib/libx264.165.dylib',
        },
        reason: '外部 dylib 必须全部被抓到，系统目录下的必须放过',
      );
    });

    test('跨块边界的路径不会被漏掉', () {
      // 分块扫描最容易出的错：路径正好横跨两块，两边各看到半截 → 静默漏报。
      // 这里把外部路径故意摆在第一块尾部、跨到第二块。
      final Directory tmp = Directory.systemTemp.createTempSync('ffmin-split');
      addTearDown(() => tmp.deleteSync(recursive: true));
      const String needle = '/opt/homebrew/opt/x264/lib/libx264.165.dylib';
      final File fake = File('${tmp.path}/split-macho');
      final List<int> bytes = <int>[
        ...List<int>.filled(_chunkSize - (needle.length ~/ 2), 0x41),
        0,
        ...latin1.encode(needle),
        0,
        ...List<int>.filled(4096, 0x41),
      ];
      fake.writeAsBytesSync(bytes);

      expect(
        scanForeignSharedLibraryPaths(fake),
        contains(needle),
        reason: '跨块路径漏报 = 守卫在真二进制上随机假绿',
      );
    });

    test('vendored 目录非空（防止目录被挪走后守卫静默空转）', () {
      expect(vendorRoot.existsSync(), isTrue, reason: '缺 ${vendorRoot.path}');
      final List<File> binaries = _vendoredBinaries(vendorRoot);
      expect(
        binaries.length,
        greaterThanOrEqualTo(4),
        reason: 'third_party/ffmpeg-min 下至少应有 windows + macos 各两个 exe，'
            '实际只找到 ${binaries.length} 个：'
            '${binaries.map((File f) => f.path).join(", ")}',
      );
    });

    for (final File binary in _vendoredBinaries(vendorRoot)) {
      final String relative = binary.path
          .substring(vendorRoot.path.length + 1)
          .replaceAll(r'\', '/');
      final String platformDir = relative.split('/').first;

      test('$relative 不依赖构建机上的包管理器动态库', () {
        final Stopwatch watch = Stopwatch()..start();
        final Set<String> foreign = scanForeignSharedLibraryPaths(binary);
        watch.stop();
        // 耗时打出来，方便判断守卫是否成了单测里的慢点。
        // ignore: avoid_print
        print('[ffmpeg-min self-contained] $relative '
            '(${binary.lengthSync()} B) 扫描耗时 ${watch.elapsedMilliseconds}ms');

        expect(
          foreign,
          isEmpty,
          reason: '${binary.path} 依赖构建机专有的共享库：\n'
              '${foreign.map((String p) => "  $p  ← ${_describeOrigin(p)}").join("\n")}'
              '\n${_fixHint(platformDir)}',
        );
      });
    }
  });
}

/// 列出 third_party/ffmpeg-min 下所有可执行产物（跳过随包的系统 DLL 与说明文件）。
///
/// 不硬编码平台/文件名清单：将来加 Linux vendor 或换文件名，新产物自动进守卫。
List<File> _vendoredBinaries(Directory vendorRoot) {
  if (!vendorRoot.existsSync()) return <File>[];
  return vendorRoot.listSync(recursive: true).whereType<File>().where((File f) {
    final String name = f.uri.pathSegments.last;
    // 随包的 MinGW 运行时 DLL 也一起扫——它们同样会被拷进用户机器。
    return !name.endsWith('.md') && !name.endsWith('.txt');
  }).toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
}
