// 守卫：随 app 出货的代码里，不得再给 powershell 传执行策略绕过参数。
//
// 背景（真实事故）：卡巴斯基 Endpoint Security 的**行为检测**（PDM）把运行中的
// hibiki.exe 判成 `PDM:Trojan.Win32.Generic`（威胁级别「高」，对象类型「进程」，
// 直接结束进程）。没有任何文件特征命中——纯粹是动作链打分过阈：
//
//   未签名进程 → 联网拉 PE 落盘 → 生成 powershell 子进程枚举全机进程/模块
//   → 读注册表 → 生成分离子进程静默执行刚下载的 PE → 自身退出
//
// 「进程生成 powershell 且带执行策略绕过」是各家 EDR/AV 规则库里的标准高危项
// （LOLBin 滥用），在上面那条链里是权重最高的单点信号之一。
//
// 关键事实：这个参数在我们这几处**本来就是空写**。执行策略只约束 `.ps1` 脚本
// 文件的加载，对 `-Command` 传入的内联字符串完全不生效。实测（Windows
// PowerShell 5.1）：即使显式传最严的 Restricted，内联 -Command 照常执行。
// 所以删掉它零功能损失，纯粹是把一个高权重 AV 信号白送出去。
//
// 因此本守卫的判据是「出货代码里不得出现该参数」，而不是「不许用 powershell」——
// 用 powershell 取信息本身还有合法用途，白送信号没有。
//
// 扫描面**只含随 app 出货的代码**（fushi/lib + fushi/windows）。开发期脚本
// （tool/*.ps1 及调用它们的文档命令）不在此列：那些不进用户机器，且用 -File
// 跑真实 .ps1 时该参数是**有效且必要**的。
//
// 纯 dart:io，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 随 app 出货的代码根。**不含** tool/ 与 .github/：那些是开发期/CI 脚本。
const List<String> _shippedRoots = <String>[
  'fushi/lib',
  'fushi/windows',
];

/// 只看文本源码；二进制与生成物跳过。
bool _isTextSource(String path) {
  const List<String> exts = <String>[
    '.dart',
    '.iss',
    '.cpp',
    '.h',
    '.cc',
    '.ps1',
    '.bat',
    '.cmd',
  ];
  final String lower = path.toLowerCase();
  return exts.any(lower.endsWith);
}

/// 针（拆开拼装）：避免本守卫文件自身被未来扩大的扫描面匹配到。
const String _needle = '-Execution${'Policy'}';

void main() {
  test('出货代码不得给 powershell 传执行策略绕过参数（AV 行为检测高权重信号）', () {
    final Directory root = _repoRoot();
    final List<String> offenders = <String>[];
    int scanned = 0;

    for (final String rel in _shippedRoots) {
      final Directory dir = Directory('${root.path}/$rel');
      if (!dir.existsSync()) {
        fail('扫描根不存在：$rel —— 守卫的路径常量过期了，先修守卫');
      }
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!_isTextSource(entity.path)) continue;
        scanned++;
        final String text = entity.readAsStringSync();
        if (!text.contains(_needle)) continue;
        for (final String line in text.split('\n')) {
          if (line.contains(_needle)) {
            offenders.add('${entity.path}: ${line.trim()}');
          }
        }
      }
    }

    expectScanScale(
      scanned,
      what: '出货代码（fushi/lib + fushi/windows）里的文本源文件',
      atLeast: 800,
      measured: 1085,
    );

    expect(
      offenders,
      isEmpty,
      reason: '这些出货代码给 powershell 传了执行策略绕过参数：\n'
          '${offenders.join('\n')}\n\n'
          '它对 `-Command` 内联字符串**本来就不生效**（执行策略只管 .ps1 文件加载），'
          '却是 AV/EDR 行为检测里的高权重信号——卡巴 PDM 已因此把 app 进程判成木马并结束。\n'
          '删掉即可；要传参就用 `-NoProfile -NonInteractive`。\n'
          '若确实需要跑真实 .ps1 脚本文件，把脚本挪到 tool/（开发期，不随 app 出货）。',
    );
  });
}
