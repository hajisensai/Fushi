/// 绘光的光位目录：10 族 × 10 种，按族序排列（folia `lumiere/catalog.ts`）。
library;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rigs_a.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rigs_b.dart';

final List<LumiereProfile> lumiereProfiles = <LumiereProfile>[
  ...zenithProfiles,
  ...latticeProfiles,
  ...prismProfiles,
  ...causticProfiles,
  ...opticsProfiles,
  ...waveProfiles,
  ...botanyProfiles,
  ...astralProfiles,
  ...stageProfiles,
  ...motesProfiles,
];

final Map<String, LumiereProfile> _byKind = <String, LumiereProfile>{
  for (final LumiereProfile p in lumiereProfiles) p.kind: p,
};

final List<String> lumiereKinds = <String>[
  for (final LumiereProfile p in lumiereProfiles) p.kind,
];

/// 未知的 kind 退回天井。
LumiereProfile profileOf(String kind) => _byKind[kind] ?? lumiereProfiles.first;

bool hasProfile(String kind) => _byKind.containsKey(kind);
