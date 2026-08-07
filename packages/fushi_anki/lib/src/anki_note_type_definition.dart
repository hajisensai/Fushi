import 'package:flutter/foundation.dart';

/// 一个 note type 里单张卡模板（card template）的正/反面 HTML。
///
/// AnkiConnect `modelTemplates` 返回 `{模板名: {Front, Back}}`；本类是其
/// backend 无关的载体，同时充当 Lapis 模板备份文件（JSON）的一部分。
@immutable
class AnkiCardTemplate {
  const AnkiCardTemplate({
    required this.name,
    required this.front,
    required this.back,
  });

  factory AnkiCardTemplate.fromJson(Map<String, dynamic> json) =>
      AnkiCardTemplate(
        name: json['name'] as String? ?? '',
        front: json['front'] as String? ?? '',
        back: json['back'] as String? ?? '',
      );

  final String name;
  final String front;
  final String back;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'front': front,
        'back': back,
      };
}

/// 从后端读回的 note type 完整定义（字段顺序 / 卡模板 / CSS）。
///
/// 这是「Lapis 模板备份」的核心载荷：备份 = 把本对象序列化成 JSON 落盘；
/// 恢复 = 反序列化后把 [css] 与 [templates] 写回后端。字段列表只读不写
/// （改字段结构会动用户数据，不属于样式客制化范围）。
@immutable
class AnkiNoteTypeDefinition {
  const AnkiNoteTypeDefinition({
    required this.name,
    required this.fields,
    required this.templates,
    required this.css,
  });

  factory AnkiNoteTypeDefinition.fromJson(Map<String, dynamic> json) =>
      AnkiNoteTypeDefinition(
        name: json['name'] as String? ?? '',
        fields: (json['fields'] as List?)?.cast<String>() ?? const <String>[],
        templates: (json['templates'] as List?)
                ?.map((dynamic e) =>
                    AnkiCardTemplate.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <AnkiCardTemplate>[],
        css: json['css'] as String? ?? '',
      );

  final String name;
  final List<String> fields;
  final List<AnkiCardTemplate> templates;
  final String css;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'fields': fields,
        'templates': templates.map((AnkiCardTemplate t) => t.toJson()).toList(),
        'css': css,
      };
}
