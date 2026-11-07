/// 「制卡到已配对设备」下的「保存到」：手机选卡落到主机的哪里（docs/specs/2026-11-05-server-srs-design.md
/// §4.8）。选项来自主机的 `POST /api/mine/targets`，选择按主机（hostId）存在本机。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiChoiceOption, showFushiChoiceDialog;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:material_ui/material_ui.dart';

/// 「保存到」里的一项。[target] 为 null = 主机默认。
class MineToServerTargetOption {
  const MineToServerTargetOption({
    required this.target,
    required this.label,
    this.subtitle,
  });

  final RemoteMiningTarget? target;
  final String label;
  final String? subtitle;

  bool get isAnki => target?.kind == kRemoteMiningKindAnki;

  /// 对话框里的选项值（[RemoteMiningTarget] 的稳定编码；主机默认 = 空串）。
  String get key => mineToServerTargetKey(target);
}

String mineToServerTargetKey(RemoteMiningTarget? target) {
  if (target == null || target.isEmpty) return '';
  return <String?>[
    target.kind,
    target.profile,
    target.deck,
  ].map((String? v) => v ?? '').join('\u0000');
}

/// 把主机的 `/api/mine/targets` 回包摊成选项：主机默认 → 各份复习 profile（默认牌组 + 各牌组）→ Anki
/// （默认牌组 + 各牌组，主机有 Anki 时）。
List<MineToServerTargetOption> mineToServerTargetOptions(
  Map<String, dynamic> json,
) {
  String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
  final List<MineToServerTargetOption> options = <MineToServerTargetOption>[
    MineToServerTargetOption(
      target: null,
      label: t.anki_mine_to_server_target_default,
      subtitle: t.anki_mine_to_server_target_default_hint,
    ),
  ];
  final Object? review = json['review'];
  if (review is List) {
    for (final Object? entry in review) {
      if (entry is! Map) continue;
      final String? uid = text(entry['profile']);
      if (uid == null) continue;
      final String head = t.anki_mine_to_server_target_review(
        profile: text(entry['name']) ?? uid.substring(0, 8),
      );
      options.add(
        MineToServerTargetOption(
          target: RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: uid,
          ),
          label: head,
          subtitle: t.anki_mine_to_server_target_deck_default,
        ),
      );
      final Object? decks = entry['decks'];
      if (decks is List) {
        for (final Object? deck in decks) {
          final String? name = text(deck);
          if (name == null) continue;
          options.add(
            MineToServerTargetOption(
              target: RemoteMiningTarget(
                kind: kRemoteMiningKindReview,
                profile: uid,
                deck: name,
              ),
              label: '$head · $name',
            ),
          );
        }
      }
    }
  }
  final Object? anki = json['anki'];
  if (anki is Map) {
    final String head = t.srs_mining_target_anki;
    options.add(
      MineToServerTargetOption(
        target: const RemoteMiningTarget(kind: kRemoteMiningKindAnki),
        label: head,
        subtitle: t.anki_mine_to_server_target_deck_default,
      ),
    );
    final Object? decks = anki['decks'];
    if (decks is List) {
      for (final Object? deck in decks) {
        final String? name = text(deck);
        if (name == null) continue;
        options.add(
          MineToServerTargetOption(
            target: RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: name),
            label: '$head · $name',
          ),
        );
      }
    }
  }
  return options;
}

/// 设置行副标题：此刻卡落到哪（按选的时候存下的名字；没选过 = 主机默认）。
String mineToServerTargetSubtitle(AppModel appModel) {
  final List<String> labels = appModel.mineToServerTargetLabels.values.toList();
  if (labels.isEmpty) return t.anki_mine_to_server_target_default;
  return labels.join(' / ');
}

/// 问主机能落到哪，弹单选框，存下所选。主机不支持挑（老主机 / 桌面 host）或连不上时提示一句。
Future<void> pickMineToServerTarget(
  BuildContext context,
  AppModel appModel,
) async {
  final RemoteMiningTargetsReply? reply = await appModel
      .createRemoteMiningClient()
      .miningTargets();
  final String? hostId = reply?.hostId;
  if (reply == null || hostId == null) {
    FushiToast.show(msg: t.anki_mine_to_server_target_unavailable);
    return;
  }
  final List<MineToServerTargetOption> options = mineToServerTargetOptions(
    reply.json,
  );
  if (!context.mounted) return;
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: t.anki_mine_to_server_target,
    icon: FushiIcons.ankiCard,
    selected: mineToServerTargetKey(appModel.mineToServerTargets[hostId]),
    options: <FushiChoiceOption<String>>[
      for (final MineToServerTargetOption o in options)
        FushiChoiceOption<String>(
          value: o.key,
          label: o.label,
          subtitle: o.subtitle,
          icon: o.target == null
              ? FushiIcons.devices
              : o.isAnki
              ? FushiIcons.ankiCard
              : FushiIcons.profiles,
        ),
    ],
  );
  if (picked == null) return;
  final MineToServerTargetOption choice = options.firstWhere(
    (MineToServerTargetOption o) => o.key == picked,
  );
  await appModel.setMineToServerTarget(
    hostId,
    choice.target,
    label: choice.label,
  );
}

/// 控制通道（`fushi_cli config run interconnect.mine_to_server_target`）：不弹框，按参数直接设。
/// 选项仍向主机现问：只能设主机列出来的落点，设不存在的会被拒绝而不是静默退回。
Future<Object?> setMineToServerTargetFromCli(
  AppModel appModel,
  Map<String, String> args,
) async {
  final String kind = (args['kind'] ?? '').trim();
  final String? profile = (args['profile'] ?? '').trim().isEmpty
      ? null
      : args['profile']!.trim();
  final String? deck = (args['deck'] ?? '').trim().isEmpty
      ? null
      : args['deck']!.trim();
  if (kind != 'default' &&
      kind != kRemoteMiningKindReview &&
      kind != kRemoteMiningKindAnki) {
    throw ArgumentError.value(kind, 'kind', 'default | review | anki');
  }
  final RemoteMiningTargetsReply? reply = await appModel
      .createRemoteMiningClient()
      .miningTargets();
  final String? hostId = reply?.hostId;
  if (reply == null || hostId == null) {
    throw StateError(t.anki_mine_to_server_target_unavailable);
  }
  final RemoteMiningTarget? wanted = kind == 'default'
      ? null
      : RemoteMiningTarget(kind: kind, profile: profile, deck: deck);
  final MineToServerTargetOption? choice = mineToServerTargetOptions(reply.json)
      .where(
        (MineToServerTargetOption o) => o.key == mineToServerTargetKey(wanted),
      )
      .firstOrNull;
  if (choice == null) {
    throw ArgumentError('The paired device does not offer this location.');
  }
  await appModel.setMineToServerTarget(
    hostId,
    choice.target,
    label: choice.label,
  );
  return <String, Object?>{
    'host': hostId,
    'target': choice.target?.toJson(),
    'label': choice.label,
  };
}
