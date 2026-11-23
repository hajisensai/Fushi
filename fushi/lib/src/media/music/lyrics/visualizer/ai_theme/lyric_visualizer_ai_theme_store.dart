/// AI 歌词动画主题的每首缓存（[AiFeature.musicVisualizerTheme]）。
///
/// 一首一个 JSON 文件（`<支持目录>/music_visualizer_ai_themes/<sha1(trackUid)>.json`）：
/// 重开同一首直接复用，不再花一次请求。AI 产物，按 `fushi/CLAUDE.md` §13 设备本地——这个目录
/// 不在备份 / 同步 / Profile 的收集范围里（备份只收数据库与登记过的媒体目录）。
///
/// 可撤销（§13「AI 的写操作必须可回滚」）：记录里除了当前主题还留着**上一版**（可能是「没有
/// 主题 = 封面取色」）。生成 / 改回封面取色都把当前那份挪进上一版；撤销就两者互换，所以撤销
/// 本身也能再撤销。两者都空时删文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import 'package:fushi/src/ai/ai_music_visualizer_theme_assistant.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 一首的缓存记录。
@immutable
class LyricVisualizerAiThemeRecord {
  const LyricVisualizerAiThemeRecord({
    this.current,
    this.previous,
    this.hasPrevious = false,
    this.updatedAtMs = 0,
  });

  /// 正在用的主题；null = 封面取色（用户改回过，或从没生成过）。
  final AiMusicVisualizerTheme? current;

  /// 上一版（[hasPrevious] 为真时有意义；null = 上一版是封面取色）。
  final AiMusicVisualizerTheme? previous;
  final bool hasPrevious;
  final int updatedAtMs;

  static const LyricVisualizerAiThemeRecord empty =
      LyricVisualizerAiThemeRecord();

  /// 什么都没有（不必落盘）。
  bool get isEmpty => current == null && previous == null;

  /// 换上 [next]，当前那份进上一版。
  LyricVisualizerAiThemeRecord replacedWith(
    AiMusicVisualizerTheme? next, {
    required int nowMs,
  }) => LyricVisualizerAiThemeRecord(
    current: next,
    previous: current,
    hasPrevious: true,
    updatedAtMs: nowMs,
  );

  /// 撤销：当前与上一版互换（没有上一版原样返回）。
  LyricVisualizerAiThemeRecord reverted({required int nowMs}) => hasPrevious
      ? LyricVisualizerAiThemeRecord(
          current: previous,
          previous: current,
          hasPrevious: true,
          updatedAtMs: nowMs,
        )
      : this;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'current': current?.toJson(),
    'previous': previous?.toJson(),
    'hasPrevious': hasPrevious,
    'updatedAt': updatedAtMs,
  };

  /// 坏文件 / 未知版本当空记录（缓存而已，丢了顶多再生成一次）。
  static LyricVisualizerAiThemeRecord fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return empty;
    final AiMusicVisualizerTheme? current = AiMusicVisualizerTheme.fromJson(
      json['current'],
    );
    final AiMusicVisualizerTheme? previous = AiMusicVisualizerTheme.fromJson(
      json['previous'],
    );
    final Object? at = json['updatedAt'];
    return LyricVisualizerAiThemeRecord(
      current: current,
      previous: previous,
      hasPrevious: json['hasPrevious'] == true,
      updatedAtMs: at is int ? at : 0,
    );
  }
}

/// 文件存取。目录可注入（测试用临时目录）。
class LyricVisualizerAiThemeStore {
  LyricVisualizerAiThemeStore({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join(
      (await AppPaths.supportRootDirectory()).path,
      'music_visualizer_ai_themes',
    ),
  );

  /// 文件名不含曲目 uid 原文（uid 里可能有路径 / URL 字符）。
  static String fileNameFor(String trackUid) =>
      '${sha1.convert(utf8.encode(trackUid))}.json';

  Future<File> _fileFor(String trackUid) async =>
      File(p.join((await _directory()).path, fileNameFor(trackUid)));

  Future<LyricVisualizerAiThemeRecord> load(String trackUid) async {
    if (trackUid.isEmpty) return LyricVisualizerAiThemeRecord.empty;
    final File f = await _fileFor(trackUid);
    try {
      if (!await f.exists()) return LyricVisualizerAiThemeRecord.empty;
      return LyricVisualizerAiThemeRecord.fromJson(
        jsonDecode(await f.readAsString()),
      );
    } on FormatException {
      return LyricVisualizerAiThemeRecord.empty;
    } on FileSystemException {
      return LyricVisualizerAiThemeRecord.empty;
    }
  }

  /// 写入（空记录删文件）。先写临时文件再改名，写到一半退出不留坏文件。
  Future<void> save(
    String trackUid,
    LyricVisualizerAiThemeRecord record,
  ) async {
    if (trackUid.isEmpty) return;
    final File f = await _fileFor(trackUid);
    if (record.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
