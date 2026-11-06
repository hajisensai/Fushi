/// 点已制卡 ✓ 的判据，app 内外所有车道共用（不依赖 UI，overlay 桥 / 远程服务也能引）。
library;

import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 E0sdqm4h-F：单击已制卡 ✓ 是否**不弹选择、直接再制一张**。判据是「允许重复」
/// （[AnkiSettings.allowDupes]，设置说明即「添加卡片时跳过重复检查」）。
///
/// 这是点 ✓ 的**唯一**判据，两条车道共用：app 内的 `runAnkiMinedCardAction`（anki_mined_card_action_sheet），以及 app 外
/// 页内面板车道（Windows / macOS 裸 WebView 的 `findMinedMatches` 桥，
/// overlay_bridge_handlers）。浏览器扩展经 `/api/duplicate` 的 `allowDuplicates` 位拿到同一个
/// 值（`FushiRemoteDuplicatePolicyService`）。
///
/// 只管**单击**：右键 / 长按 ✓（popup.js 的「管理」手势，`openChooser`）永远弹选择，
/// 覆写指定旧卡 / 查看这两个入口不因开了允许重复而消失。
Future<bool> ankiMinedTapMinesNewDirectly(BaseAnkiRepository repo) async =>
    (await repo.loadSettings()).allowDupes;
