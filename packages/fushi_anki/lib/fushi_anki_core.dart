/// fushi_anki 的**零 Flutter** 子集：模型、note type 定义、Lapis 模板/样式、媒体去重
/// 报告与 AnkiConnect HTTP 服务。无头服务端（`packages/fushi_server`，`dart compile exe`）
/// 和纯 Dart 引擎 `packages/fushi_engine` 只 import 本 barrel；任何
/// `package:flutter/...`（含 foundation）进到本闭包都会传递拖进 `dart:ui` 编不过。
///
/// 重文件（`base_anki_repository.dart` / `ankidroid/anki_repository.dart` /
/// `ankiconnect/ankiconnect_repository.dart` 等：shared_preferences、flutter services、
/// foundation）只从 `fushi_anki.dart` 导出。
library fushi_anki_core;

export 'src/anki_media_dedup.dart';
export 'src/anki_models.dart';
export 'src/anki_note_type_definition.dart';
export 'src/anki_remote_media_http.dart';
export 'src/anki_template_render.dart';
export 'src/card_source_link.dart';
export 'src/ankiconnect/ankiconnect_service.dart';
export 'src/lapis_blocks.dart';
export 'src/lapis_note_type.dart';
export 'src/lapis_preset.dart';
export 'src/lapis_style_preview.dart';
export 'src/lapis_styling.dart';
export 'src/lapis_template_preview.dart';
