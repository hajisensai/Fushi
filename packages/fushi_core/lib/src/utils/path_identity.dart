/// 「这两个字符串指的是不是磁盘上同一个文件」的单一判据。
///
/// 仓内历史上有三套互不相通的口径：
/// - `normalizeVideoPath`（`external_video.dart`）：只统一分隔符 + 去冗余段，
///   **不绝对化、不折大小写**。它是 `externalVideoBookUid` 的输入，语义已经固化
///   进用户库里的 uid，绝不能改——但也正因为不折大小写，`D:\a\b.mkv` 与
///   `d:\a\b.mkv` 在它眼里是两个文件；
/// - `video_sidecar_target_resolver.dart` 等 4 个 metadata 文件里逐字重复的私有
///   `_pathKey`：绝对化 + Windows 小写，这才是「同一物理文件」该有的判据；
/// - `p.equals` / `p.canonicalize` 家族。
///
/// **删除路径必须用最强的那一套**：护栏漏一次命中就是删掉用户还在引用的文件。
/// 本函数把 `_pathKey` 那套提成公共原语，删除链路统一走它。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// [path] 的平台身份键：绝对化 + 规范化，Windows 上再折大小写。
///
/// 折叠范围与 metadata 侧那份 `_pathKey` 逐字一致（只 Windows）：Linux/Android
/// 大小写敏感，折了反而会把两个真不同的文件判成同一个。
///
/// 只用于**比较**，返回值不是可用来开文件的真实路径（大小写已被破坏）。
/// 相对路径按当前进程工作目录绝对化——所以调用方在删除路径上必须先把相对路径
/// 挡掉，别指望这里替你判断它指向哪。
String platformPathKey(String path) {
  final String normalized = p.normalize(p.absolute(path.trim()));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

/// [a] 与 [b] 是否指向同一个文件（按 [platformPathKey]）。
bool isSamePathIdentity(String a, String b) =>
    platformPathKey(a) == platformPathKey(b);
