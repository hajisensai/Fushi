/// 光位目录（上半）：天光、窗隙、棱镜、焦散、光路五族，每族 10 个（folia `lumiere/rigs/*.ts`，数值原样搬）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_line_art.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rig.dart';

const LumiereMood _q = LumiereMood.quiet;
const LumiereMood _n = LumiereMood.neutral;
const LumiereMood _l = LumiereMood.loud;
const WindowTypography _h = WindowTypography.horizontal;
const WindowTypography _v = WindowTypography.vertical;
const WindowTypography _x = WindowTypography.crossed;

// ---------------------------------------------------------------------------
// 天光（顶光）
// ---------------------------------------------------------------------------

const LumiereFamily _zenith = LumiereFamily('zenith');

final RigBuilder _zenithShaftLight = rig(<BeamSpec>[
  kShaft,
  kFan,
  kFan.copyWith(
    spread: 0.55,
    length: 0.42,
    softness: 1,
    intensity: 0.16,
    streaks: 0.9,
    streakFreq: 40,
    streakSpeed: -0.03,
    core: 0.2,
    noSway: true,
  ),
]);

final List<LumiereProfile> zenithProfiles = <LumiereProfile>[
  _zenith(
    kind: 'zenith-shaft',
    label: '天井',
    mood: _n,
    light: _zenithShaftLight,
    typography: _x,
    decay: const DecaySpec(1, 1),
    starfall: kStarfall,
  ),
  _zenith(
    kind: 'zenith-fan',
    label: '扇光',
    mood: _l,
    light: rig(<BeamSpec>[
      for (final int k in <int>[-2, -1, 0, 1, 2])
        kShaft.copyWith(
          angle: kDown + k * 0.24,
          spread: 0.035,
          width: 0.012,
          length: 0.9,
          intensity: 0.7 - k.abs() * 0.08,
          streaks: 0.4,
          streakFreq: 5,
          sway: Oscillation(0.05, 11, k * 0.1),
        ),
    ]),
    typography: _h,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall.copyWith(rain: 110, rainSpread: 0.6),
  ),
  _zenith(
    kind: 'zenith-halo',
    label: '圣环',
    mood: _n,
    light: rig(<BeamSpec>[
      kShaft.copyWith(spread: 0.07),
      kFan.copyWith(spread: 0.42, intensity: 0.24),
    ], glare: kGlare.copyWith(radius: 0.2, intensity: 1.2, streak: 0.7)),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      protractorHalo(
        cx: c.aspect * 0.5,
        cy: 0.03,
        radius: 0.42,
        alpha: 0.7,
        spokeStep: math.pi / 18,
      ),
      protractorHalo(
        cx: c.aspect * 0.5,
        cy: 0.03,
        radius: 0.24,
        alpha: 0.4,
        delay: 0.2,
      ),
      scatteredSparks(
        aspect: c.aspect,
        count: 20,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    region: const TextRegion(0.5, 0.5, 0.72, 0.62),
    typography: _v,
    decay: const DecaySpec(0.8, 1.2),
    starfall: kStarfall,
  ),
  _zenith(
    kind: 'zenith-drift',
    label: '游光',
    mood: _q,
    light: rig(<BeamSpec>[
      kShaft.copyWith(sway: const Oscillation(0.2, 9, 0), intensity: 0.85),
      kFan.copyWith(intensity: 0.2, sway: const Oscillation(0.2, 9, 0)),
    ], fog: kFog.copyWith(density: 0.9)),
    typography: _h,
    decay: const DecaySpec(0.7, 1.4),
    camera: const CameraSpec(0.02, 0.01, 0),
  ),
  _zenith(
    kind: 'zenith-twin',
    label: '双柱',
    mood: _n,
    light: rig(<BeamSpec>[
      kShaft.copyWith(
        x: 0.33,
        spread: 0.06,
        sway: const Oscillation(0.06, 12, 0),
      ),
      kShaft.copyWith(
        x: 0.67,
        spread: 0.06,
        sway: const Oscillation(0.06, 12, 0.5),
      ),
    ], glare: null),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      viewfinderFrame(
        aspect: c.aspect,
        left: 0.07,
        top: 0.21,
        right: 0.93,
        bottom: 0.8,
        alpha: 0.32,
      ),
      scatteredSparks(
        aspect: c.aspect,
        count: 18,
        random: c.random,
        delay: 0.2,
      ),
    ]),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _zenith(
    kind: 'zenith-rain',
    label: '光雨',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 6; i++)
          kShaft.copyWith(
            x: const <double>[0.18, 0.34, 0.5, 0.66, 0.82, 0.42][i],
            spread: 0.012,
            width: 0.01,
            length: 1.1,
            intensity: 0.45,
            streaks: 0.7,
            streakFreq: 3,
            pulse: Oscillation(0.35, 1.7 + i * 0.37, i * 0.21),
            noSway: true,
          ),
      ],
      fog: kFog.copyWith(driftY: 0.05),
      glare: kGlare.copyWith(intensity: 0.5),
    ),
    typography: _v,
    decay: const DecaySpec(1.3, 0.6),
    starfall: kStarfall.copyWith(
      rain: 220,
      rainSpeed: 0.45,
      rainSpread: 1.4,
      brightness: 1.1,
    ),
  ),
  _zenith(
    kind: 'zenith-well',
    label: '光井',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.05,
          width: 0.02,
          length: 1.4,
          intensity: 0.8,
          core: 0.9,
        ),
      ],
      fog: kFog.copyWith(density: 0.7, ambient: 0.015),
      glare: kGlare.copyWith(intensity: 0.6),
    ),
    lineArt: (RigContext c) => LineArtSpec(
      <LinePath>[
        LinePath(
          points: ellipsePts(c.aspect * 0.5, 0.8, 0.26, 0.05),
          width: 0.0018,
          alpha: 0.7,
          delay: 0.1,
          span: 0.5,
        ),
        LinePath(
          points: ellipsePts(c.aspect * 0.5, 0.8, 0.17, 0.032),
          width: 0.0012,
          alpha: 0.45,
          delay: 0.2,
          span: 0.4,
          dash: (0.004, 0.008),
        ),
      ],
      <LineNode>[LineNode((c.aspect * 0.5, 0.8), 0.03, 0.3, 0)],
    ),
    motes: kMotes.copyWith(count: 160),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _zenith(
    kind: 'zenith-crown',
    label: '冠冕',
    mood: _l,
    light: (RigContext c) {
      final LightRig base = _zenithShaftLight(c);
      return LightRig(
        beams: base.beams,
        fog: base.fog,
        glare: const GlareSpec(
          x: 0.5,
          y: 0,
          radius: 0.18,
          intensity: 1.3,
          streak: 0.8,
        ),
      );
    },
    burst: const BurstSpec(BurstMode.sung, 0.4, 1, 0, 4, Rgb(1, 0.6, 0.4)),
    typography: _h,
    decay: const DecaySpec(1.25, 0.7),
    starfall: const StarfallSpec(
      stars: 520,
      opening: 2.6,
      rain: 120,
      rainSpeed: 0.32,
      rainSpread: 0.5,
      brightness: 1.1,
    ),
    camera: const CameraSpec(0.05, 0, -0.01),
  ),
  _zenith(
    kind: 'zenith-descent',
    label: '垂降',
    mood: _n,
    light: rig(<BeamSpec>[
      kShaft.copyWith(reveal: 3),
      kFan.copyWith(reveal: 3.5),
    ]),
    typography: _x,
    decay: const DecaySpec(1, 1),
    starfall: kStarfall.copyWith(rain: 40),
  ),
  _zenith(
    kind: 'zenith-ember',
    label: '余烬',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          intensity: 0.45,
          tint: const Rgb(1, 0.7, 0.5),
          pulse: const Oscillation(0.2, 5, 0),
        ),
        kFan.copyWith(intensity: 0.12, tint: const Rgb(1, 0.6, 0.4)),
      ],
      fog: kFog.copyWith(density: 1.2, ambient: 0.04, driftY: -0.05),
      glare: kGlare.copyWith(intensity: 0.4),
    ),
    motes: kMotes.copyWith(
      count: 320,
      driftY: -0.035,
      swirl: 0.03,
      gain: 1.6,
      ambient: 0.04,
    ),
    region: const TextRegion(0.5, 0.5, 0.72, 0.62),
    typography: _v,
    decay: const DecaySpec(1.4, 0.8),
    camera: const CameraSpec(0.02, 0, -0.012),
  ),
];

// ---------------------------------------------------------------------------
// 窗隙
// ---------------------------------------------------------------------------

final LumiereFamily _lattice = LumiereFamily(
  'lattice',
  region: const TextRegion(0.56, 0.58, 0.66, 0.5),
  motes: kMotes.copyWith(driftX: 0.008, driftY: -0.006),
);

final BeamSpec _windowBeam = kShaft.copyWith(
  x: 0.1,
  y: 0.06,
  angle: 0.62,
  spread: 0.1,
  width: 0.34,
  length: 1.3,
  softness: 0.35,
  intensity: 1,
  streaks: 0.25,
  streakFreq: 4,
  core: 0.3,
  sway: const Oscillation(0.01, 17, 0),
);

ArtBuilder _latticeSparks([
  (double, double, double, double) region = (0.3, 0.3, 0.95, 0.9),
]) =>
    (RigContext c) => scatteredSparks(
      aspect: c.aspect,
      count: 14,
      random: c.random,
      delay: 0.3,
      region: region,
    );

final GlareSpec _latticeGlare = kGlare.copyWith(
  x: 0.1,
  y: 0.06,
  radius: 0.14,
  intensity: 0.7,
);

final List<LumiereProfile> latticeProfiles = <LumiereProfile>[
  _lattice(
    kind: 'lattice-blinds',
    label: '百叶',
    mood: _n,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          gobo: const GoboSpec(GoboPattern.blinds, 13, 0.52, 0.02),
        ),
      ],
      fog: kFog.copyWith(driftX: 0.012, driftY: -0.02),
      glare: kGlare.copyWith(x: 0.1, y: 0.06, radius: 0.16, intensity: 0.8),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      blindsWindow(
        x: c.aspect * 0.03,
        y: 0.02,
        w: c.aspect * 0.16,
        h: 0.26,
        slats: 9,
        alpha: 0.5,
      ),
      _latticeSparks()(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _lattice(
    kind: 'lattice-cross',
    label: '十字窗',
    mood: _q,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          x: 0.9,
          angle: math.pi - 0.7,
          width: 0.3,
          intensity: 0.9,
          gobo: const GoboSpec(GoboPattern.cross, 0, 0.16, 0),
        ),
      ],
      fog: kFog.copyWith(driftX: -0.008),
      glare: kGlare.copyWith(x: 0.9, y: 0.06, radius: 0.14, intensity: 0.7),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      crossWindow(c.aspect * 0.8, 0.01, c.aspect * 0.16, 0.26),
      _latticeSparks((0.05, 0.3, 0.7, 0.9))(c),
    ]),
    region: const TextRegion(0.4, 0.52, 0.6, 0.62),
    typography: _v,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _lattice(
    kind: 'lattice-arch',
    label: '拱窗',
    mood: _l,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          x: 0.14,
          y: -0.02,
          angle: 0.95,
          width: 0.14,
          spread: 0.06,
          length: 1.6,
          intensity: 1.3,
          streaks: 0.55,
          streakFreq: 8,
          core: 0.6,
        ),
        _windowBeam.copyWith(
          x: 0.14,
          y: -0.02,
          angle: 0.95,
          width: 0.3,
          spread: 0.2,
          length: 0.9,
          softness: 0.9,
          intensity: 0.3,
          streaks: 0.8,
          streakFreq: 22,
        ),
      ],
      fog: kFog.copyWith(density: 1.1),
      glare: kGlare.copyWith(
        x: 0.14,
        y: 0,
        radius: 0.18,
        intensity: 1.1,
        streak: 0.6,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      archWindow(c.aspect * 0.08, -0.06, c.aspect * 0.12, 0.32),
      _latticeSparks()(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall.copyWith(rain: 90, rainSpread: 0.8),
  ),
  _lattice(
    kind: 'lattice-rose',
    label: '玫瑰窗',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (final int k in <int>[-2, -1, 0, 1, 2, 3])
          kShaft.copyWith(
            y: 0.08,
            angle: math.pi / 2 + (k - 0.5) * 0.2,
            spread: 0.035,
            width: 0.03,
            length: 1,
            intensity: 0.65 - (k - 0.5).abs() * 0.06,
            streaks: 0.4,
            streakFreq: 5,
            sway: Oscillation(0.015, 13, k * 0.1),
          ),
      ],
      glare: kGlare.copyWith(
        y: 0.08,
        radius: 0.16,
        intensity: 1.1,
        streak: 0.5,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      roseWindow(c.aspect * 0.5, 0.08, 0.12),
      scatteredSparks(
        aspect: c.aspect,
        count: 16,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    region: const TextRegion(0.5, 0.6, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall,
  ),
  _lattice(
    kind: 'lattice-slit',
    label: '门缝',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.1,
          y: 0.42,
          angle: 0.06,
          spread: 0.02,
          width: 0.012,
          length: 2.4,
          intensity: 1,
          streaks: 0.3,
          streakFreq: 3,
          core: 0.8,
          sway: const Oscillation(0.01, 15, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.8, ambient: 0.015),
      glare: kGlare.copyWith(
        x: 0.1,
        y: 0.42,
        radius: 0.08,
        intensity: 0.8,
        streak: 0.9,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      doorSlit(c.aspect * 0.1, 0.08, 0.86, 0.012),
      scatteredSparks(
        aspect: c.aspect,
        count: 10,
        random: c.random,
        delay: 0.3,
        region: (0.2, 0.2, 0.95, 0.9),
      ),
    ]),
    region: const TextRegion(0.55, 0.5, 0.6, 0.64),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _lattice(
    kind: 'lattice-shoji',
    label: '障子',
    mood: _q,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          x: 0.12,
          y: 0.1,
          angle: 0.4,
          width: 0.5,
          spread: 0.18,
          softness: 0.95,
          intensity: 0.7,
          streaks: 0.1,
          core: 0.2,
          gobo: const GoboSpec(GoboPattern.blinds, 10, 0.86, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.7, tyndallBase: 0.25),
      glare: null,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      gridPanel(c.aspect * 0.02, 0.06, c.aspect * 0.18, 0.4, 3, 5),
      scatteredSparks(
        aspect: c.aspect,
        count: 10,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _lattice(
    kind: 'lattice-grille',
    label: '格栅',
    mood: _n,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          width: 0.4,
          spread: 0.12,
          intensity: 1,
          gobo: const GoboSpec(GoboPattern.lattice, 9, 0.62, 0.04),
        ),
      ],
      fog: kFog.copyWith(driftX: 0.01),
      glare: _latticeGlare,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      gridPanel(
        c.aspect * 0.02,
        0.02,
        c.aspect * 0.16,
        0.26,
        4,
        4,
        diagonal: true,
      ),
      _latticeSparks()(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _lattice(
    kind: 'lattice-sweep',
    label: '扫窗',
    mood: _n,
    light: rig(
      <BeamSpec>[
        _windowBeam.copyWith(
          angle: 0.75,
          width: 0.3,
          intensity: 1,
          sway: const Oscillation(0.32, 10, 0),
          gobo: const GoboSpec(GoboPattern.blinds, 11, 0.55, 0.05),
        ),
      ],
      fog: kFog.copyWith(driftX: 0.01),
      glare: _latticeGlare,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      blindsWindow(
        x: c.aspect * 0.03,
        y: 0.02,
        w: c.aspect * 0.16,
        h: 0.26,
        slats: 8,
        alpha: 0.45,
      ),
      _latticeSparks()(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
    camera: const CameraSpec(0.02, 0.012, 0),
  ),
  _lattice(
    kind: 'lattice-komorebi',
    label: '叶隙',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.35,
          y: -0.05,
          angle: 1.35,
          spread: 0.2,
          width: 0.2,
          length: 1.3,
          softness: 0.7,
          intensity: 1,
          streaks: 0.2,
          core: 0.3,
          gobo: const GoboSpec(GoboPattern.leaves, 7, 0.52, 0.12),
          sway: const Oscillation(0.03, 7, 0),
        ),
        kShaft.copyWith(
          x: 0.72,
          y: -0.05,
          angle: 1.8,
          spread: 0.14,
          width: 0.12,
          length: 1.1,
          softness: 0.7,
          intensity: 0.7,
          streaks: 0.2,
          core: 0.3,
          gobo: const GoboSpec(GoboPattern.leaves, 8, 0.55, 0.1),
          sway: const Oscillation(0.03, 8, 0.4),
        ),
      ],
      fog: kFog.copyWith(density: 0.9, driftX: 0.01),
      glare: null,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      canopy(c.aspect, c.random),
      scatteredSparks(
        aspect: c.aspect,
        count: 12,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    motes: kMotes.copyWith(
      count: 220,
      driftX: 0.01,
      driftY: 0.004,
      swirl: 0.03,
    ),
    region: const TextRegion(0.5, 0.54, 0.72, 0.6),
    typography: _v,
    decay: const DecaySpec(0.8, 1.2),
  ),
  _lattice(
    kind: 'lattice-nave',
    label: '殿堂',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 4; i++)
          _windowBeam.copyWith(
            x: const <double>[0.12, 0.34, 0.56, 0.78][i],
            y: -0.02,
            angle: 1.1,
            width: 0.06,
            spread: 0.05,
            length: 1.5,
            softness: 0.5,
            intensity: 0.75,
            streaks: 0.5,
            streakFreq: 6,
            core: 0.5,
            sway: Oscillation(0.008, 19, i * 0.2),
          ),
      ],
      fog: kFog.copyWith(density: 1.2, driftX: 0.006, driftY: -0.03),
      glare: kGlare.copyWith(
        x: 0.45,
        y: 0,
        radius: 0.25,
        intensity: 0.6,
        streak: 0.3,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      tallWindows(c.aspect * 0.05, c.aspect * 0.95, -0.08, 0.26, 4),
      scatteredSparks(
        aspect: c.aspect,
        count: 18,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    typography: _x,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall.copyWith(rain: 80, rainSpread: 1.2),
  ),
];

// ---------------------------------------------------------------------------
// 棱镜
// ---------------------------------------------------------------------------

final LumiereFamily _prism = LumiereFamily(
  'prism',
  starfall: kStarfall.copyWith(rain: 50),
);

LineArtSpec _prismSparks(RigContext c) =>
    scatteredSparks(aspect: c.aspect, count: 16, random: c.random, delay: 0.3);

BeamSpec _tinted(
  Rgb tint, {
  required double x,
  required double y,
  required double angle,
  double intensity = 0.7,
  double reach = 0,
}) => kShaft.copyWith(
  x: x,
  y: y,
  angle: angle,
  spread: 0.012,
  width: 0.012,
  length: 1.4,
  intensity: intensity,
  streaks: 0.2,
  streakFreq: 3,
  core: 0.7,
  noSway: true,
  tint: tint,
  reach: reach,
);

final List<LumiereProfile> prismProfiles = <LumiereProfile>[
  _prism(
    kind: 'prism-split',
    label: '分光',
    mood: _l,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: -0.02,
          y: 0.36,
          angle: 0.08,
          spread: 0.01,
          width: 0.02,
          length: 3,
          intensity: 0.9,
          streaks: 0.2,
          noSway: true,
          reach: 0.78,
        ),
        kShaft.copyWith(
          x: 0.42,
          y: 0.4,
          angle: 0.3,
          spread: 0.2,
          width: 0.02,
          length: 1.1,
          softness: 0.4,
          intensity: 1.1,
          streaks: 0.35,
          streakFreq: 9,
          core: 0.2,
          spectrum: 1,
          sway: const Oscillation(0.03, 11, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(
        x: 0.42,
        y: 0.4,
        radius: 0.06,
        intensity: 1,
        streak: 0.3,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      prismTriangle(cx: c.aspect * 0.42, cy: 0.42, size: 0.2, alpha: 0.8),
      _prismSparks(c),
    ]),
    region: const TextRegion(0.62, 0.66, 0.6, 0.44),
    typography: _h,
    burst: const BurstSpec(BurstMode.sung, 0.3, 2, 1, 3.4, Rgb(0.8, 0.9, 1)),
    decay: const DecaySpec(1.2, 0.8),
  ),
  _prism(
    kind: 'prism-band',
    label: '光谱带',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: -0.05,
          y: 0.4,
          angle: 0.12,
          spread: 0.05,
          width: 0.16,
          length: 2.5,
          softness: 0.4,
          intensity: 0.9,
          streaks: 0.25,
          streakFreq: 6,
          core: 0.3,
          spectrum: 1,
          sway: const Oscillation(0.02, 14, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: null,
    ),
    region: const TextRegion(0.5, 0.56, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _prism(
    kind: 'prism-fringe',
    label: '虹边',
    mood: _q,
    light: rig(<BeamSpec>[
      kShaft.copyWith(
        spread: 0.1,
        softness: 0.3,
        spectrum: 0.35,
        intensity: 0.9,
      ),
      kShaft.copyWith(
        spread: 0.3,
        length: 0.6,
        softness: 0.9,
        intensity: 0.25,
        streaks: 0.8,
        streakFreq: 24,
        core: 0.4,
        spectrum: 0.5,
      ),
    ]),
    region: const TextRegion(0.5, 0.5, 0.72, 0.62),
    typography: _v,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _prism(
    kind: 'prism-shard',
    label: '碎晶',
    mood: _l,
    light: (RigContext c) => LightRig(
      beams: <BeamSpec>[
        for (int i = 0; i < 5; i++)
          () {
            final double x = 0.15 + c.random() * 0.7;
            final double y = 0.15 + c.random() * 0.5;
            final double angle = c.random() * kTau;
            final double reach = 0.5 + c.random() * 0.3;
            final double phase = c.random();
            return kShaft.copyWith(
              x: x,
              y: y,
              angle: angle,
              spread: 0.12,
              width: 0.01,
              length: 0.5,
              softness: 0.5,
              intensity: 0.8,
              streaks: 0.3,
              streakFreq: 6,
              core: 0.3,
              spectrum: 1,
              reach: reach,
              sway: Oscillation(0.1, 9.0 + i, phase),
            );
          }(),
      ],
      fog: kFog.copyWith(density: 0.9, driftY: -0.03),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      shards(c.aspect, c.random, 8),
      scatteredSparks(
        aspect: c.aspect,
        count: 18,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    typography: _x,
    burst: const BurstSpec(BurstMode.sweep, 0.4, 3, 0, 3, Rgb(0.85, 0.9, 1)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _prism(
    kind: 'prism-lines',
    label: '谱线',
    mood: _q,
    light: rig(
      <BeamSpec>[
        _tinted(const Rgb(1, 0.35, 0.3), x: 0.22, y: -0.05, angle: math.pi / 2),
        _tinted(
          const Rgb(1, 0.8, 0.3),
          x: 0.36,
          y: -0.05,
          angle: math.pi / 2,
          intensity: 0.5,
        ),
        _tinted(
          const Rgb(0.5, 1, 0.5),
          x: 0.47,
          y: -0.05,
          angle: math.pi / 2,
          intensity: 0.8,
        ),
        _tinted(
          const Rgb(0.4, 0.8, 1),
          x: 0.61,
          y: -0.05,
          angle: math.pi / 2,
          intensity: 0.6,
        ),
        _tinted(
          const Rgb(0.6, 0.45, 1),
          x: 0.78,
          y: -0.05,
          angle: math.pi / 2,
          intensity: 0.45,
        ),
      ],
      fog: kFog.copyWith(density: 0.7, ambient: 0.015),
      glare: null,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      spectrumLines(c.aspect * 0.12, c.aspect * 0.88, 0.84, 0.16, c.random, 18),
      scatteredSparks(
        aspect: c.aspect,
        count: 10,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    region: const TextRegion(0.5, 0.48, 0.72, 0.6),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _prism(
    kind: 'prism-merge',
    label: '合光',
    mood: _n,
    light: rig(
      <BeamSpec>[
        _tinted(
          const Rgb(1, 0.35, 0.3),
          x: -0.02,
          y: 0.18,
          angle: 0.47,
          reach: 0.72,
          intensity: 0.8,
        ),
        _tinted(
          const Rgb(0.45, 1, 0.45),
          x: -0.02,
          y: 0.4,
          angle: 0.1,
          reach: 0.62,
          intensity: 0.8,
        ),
        _tinted(
          const Rgb(0.4, 0.6, 1),
          x: -0.02,
          y: 0.66,
          angle: -0.29,
          reach: 0.68,
          intensity: 0.8,
        ),
        kShaft.copyWith(
          x: 0.36,
          y: 0.46,
          angle: 0.02,
          spread: 0.02,
          width: 0.02,
          length: 2,
          intensity: 1.1,
          streaks: 0.2,
          streakFreq: 3,
          core: 0.7,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(
        x: 0.36,
        y: 0.46,
        radius: 0.06,
        intensity: 1.1,
        streak: 0.5,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      prismTriangle(cx: c.aspect * 0.34, cy: 0.46, size: 0.12, alpha: 0.6),
      _prismSparks(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _prism(
    kind: 'prism-cube',
    label: '分束',
    mood: _n,
    light: (RigContext c) => LightRig(
      beams: <BeamSpec>[
        kShaft.copyWith(
          x: -0.02,
          y: 0.34,
          angle: 0,
          spread: 0.01,
          width: 0.03,
          length: 3,
          intensity: 0.9,
          streaks: 0.2,
          noSway: true,
          reach: 0.44 * c.aspect,
        ),
        kShaft.copyWith(
          x: 0.42,
          y: 0.34,
          angle: 0,
          spread: 0.01,
          width: 0.03,
          length: 3,
          intensity: 0.7,
          streaks: 0.2,
          noSway: true,
          spectrum: 0.3,
        ),
        kShaft.copyWith(
          x: 0.42,
          y: 0.34,
          angle: math.pi / 2,
          spread: 0.01,
          width: 0.03,
          length: 3,
          intensity: 0.6,
          streaks: 0.2,
          noSway: true,
          spectrum: 0.3,
        ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(
        x: 0.42,
        y: 0.34,
        radius: 0.05,
        intensity: 0.9,
        streak: 0.4,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      cubeSplitter(c.aspect * 0.42, 0.34, 0.08),
      scatteredSparks(
        aspect: c.aspect,
        count: 12,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    region: const TextRegion(0.6, 0.62, 0.6, 0.44),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _prism(
    kind: 'prism-wheel',
    label: '虹扇',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int k = 0; k < 3; k++)
          kShaft.copyWith(
            x: 0.5,
            y: 0.08,
            angle: math.pi / 2 + (k - 1) * 0.7,
            spread: 0.18,
            width: 0.01,
            length: 1.1,
            softness: 0.4,
            intensity: 0.8,
            streaks: 0.3,
            streakFreq: 8,
            core: 0.2,
            spectrum: 1,
            sway: Oscillation(0.5, 16, k / 3),
          ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(y: 0.08, radius: 0.1, intensity: 1.1, streak: 0.4),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      prismTriangle(cx: c.aspect * 0.5, cy: 0.1, size: 0.1, alpha: 0.6),
      _prismSparks(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1.2, 0.8),
  ),
  _prism(
    kind: 'prism-droplet',
    label: '虹霓',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.5,
          y: 1.2,
          angle: -math.pi / 2,
          spread: 0.55,
          width: 0.1,
          length: 1.1,
          softness: 0.25,
          intensity: 0.55,
          streaks: 0.1,
          core: 0,
          spectrum: 1,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 0.7, driftY: 0.02),
      glare: null,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      rainbowArcs(c.aspect * 0.5, 1.02, 0.62),
      scatteredSparks(
        aspect: c.aspect,
        count: 12,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    starfall: kStarfall.copyWith(
      rain: 160,
      rainSpeed: 0.5,
      rainSpread: 1.6,
      brightness: 0.8,
    ),
    region: const TextRegion(0.5, 0.46, 0.72, 0.6),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _prism(
    kind: 'prism-sweep',
    label: '扫谱',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.5,
          y: -0.1,
          angle: math.pi / 2,
          spread: 0.08,
          width: 0.1,
          length: 1.4,
          softness: 0.4,
          intensity: 0.95,
          streaks: 0.2,
          core: 0.3,
          spectrum: 1,
          sway: const Oscillation(0.35, 8, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(y: -0.05, intensity: 0.6),
    ),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
];

// ---------------------------------------------------------------------------
// 焦散
// ---------------------------------------------------------------------------

final LumiereFamily _caustic = LumiereFamily(
  'caustic',
  motes: kMotes.copyWith(driftY: -0.004, swirl: 0.03, swirlPeriod: 12),
  region: const TextRegion(0.5, 0.46, 0.72, 0.46),
);

ArtBuilder _cSparks([int count = 10]) =>
    (RigContext c) => scatteredSparks(
      aspect: c.aspect,
      count: count,
      random: c.random,
      delay: 0.3,
    );

BeamSpec _softTop({
  double? spread,
  double? width,
  double? softness,
  double intensity = 0.8,
  Oscillation? pulse,
}) => kShaft.copyWith(
  spread: spread ?? 0.22,
  width: width ?? 0.2,
  length: 1.4,
  softness: softness ?? 0.8,
  intensity: intensity,
  streaks: 0.3,
  core: 0.3,
  pulse: pulse,
);

final List<LumiereProfile> causticProfiles = <LumiereProfile>[
  _caustic(
    kind: 'caustic-pool',
    label: '池底',
    mood: _q,
    light: rig(
      <BeamSpec>[_softTop()],
      fog: kFog.copyWith(density: 0.8, driftY: -0.015, ambient: 0.02),
      glare: kGlare.copyWith(intensity: 0.6),
      caustic: const CausticSpec(
        floor: CausticFloor(0.5, 0.82, 0.42, 0.14, 0.7),
      ),
    ),
    lineArt: (RigContext c) => LineArtSpec(<LinePath>[
      LinePath(
        points: ellipsePts(c.aspect * 0.5, 0.82, c.aspect * 0.42, 0.14),
        width: 0.0014,
        alpha: 0.4,
        delay: 0.1,
        span: 0.6,
      ),
    ], _cSparks()(c).nodes),
    typography: _h,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _caustic(
    kind: 'caustic-cup',
    label: '杯影',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: -0.05,
          y: 0.3,
          angle: 0.35,
          spread: 0.08,
          width: 0.18,
          length: 1.6,
          softness: 0.5,
          intensity: 0.9,
          streaks: 0.3,
          core: 0.4,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: null,
      caustic: const CausticSpec(
        scale: 3.2,
        speed: 0.25,
        inBeam: 0.3,
        floor: CausticFloor(0.36, 0.8, 0.14, 0.07, 1.1),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      glassCup(c.aspect * 0.24, 0.52, 0.1, 0.2),
      _cSparks()(c),
    ]),
    region: const TextRegion(0.62, 0.48, 0.56, 0.64),
    typography: _v,
    decay: const DecaySpec(1, 1),
  ),
  _caustic(
    kind: 'caustic-ripple',
    label: '涟漪',
    mood: _n,
    light: rig(
      <BeamSpec>[_softTop(intensity: 0.75)],
      fog: kFog.copyWith(density: 0.8),
      glare: kGlare.copyWith(intensity: 0.5),
      caustic: const CausticSpec(
        scale: 3,
        speed: 0.5,
        inBeam: 0.6,
        floor: CausticFloor(0.5, 0.8, 0.34, 0.1, 0.5),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      ripples(c.aspect * 0.5, 0.8, 0.34, 5),
      _cSparks()(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _caustic(
    kind: 'caustic-surface',
    label: '水面',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 4; i++)
          kShaft.copyWith(
            x: const <double>[0.2, 0.42, 0.6, 0.8][i],
            y: 0.1,
            angle: 1.35 + i * 0.06,
            spread: 0.04,
            width: 0.05,
            length: 1.2,
            softness: 0.6,
            intensity: 0.7,
            streaks: 0.5,
            streakFreq: 6,
            core: 0.5,
            sway: Oscillation(0.05, 6.0 + i, i * 0.2),
          ),
      ],
      fog: kFog.copyWith(density: 1.1, driftY: -0.02),
      glare: null,
      caustic: const CausticSpec(
        scale: 2.6,
        speed: 0.6,
        inBeam: 0.9,
        floor: CausticFloor(0.5, 0.06, 0.6, 0.07, 0.9),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      waterline(c.aspect, 0.1, 0.012, 7),
      _cSparks(14)(c),
    ]),
    motes: kMotes.copyWith(count: 300, driftY: -0.02, swirl: 0.03),
    region: const TextRegion(0.5, 0.58, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1.2, 0.8),
  ),
  _caustic(
    kind: 'caustic-ring',
    label: '戒光',
    mood: _q,
    light: rig(
      <BeamSpec>[_softTop(spread: 0.14, width: 0.1, intensity: 0.7)],
      fog: kFog.copyWith(density: 0.7),
      glare: kGlare.copyWith(intensity: 0.5),
      caustic: const CausticSpec(
        scale: 4,
        speed: 0.2,
        inBeam: 0.2,
        floor: CausticFloor(0.5, 0.5, 0.2, 0.36, 0.6),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      LineArtSpec(<LinePath>[
        circle(
          c.aspect * 0.5,
          0.5,
          0.36,
          const ArtStyle(width: 0.0024, alpha: 0.6),
        ),
        circle(
          c.aspect * 0.5,
          0.5,
          0.32,
          const ArtStyle(width: 0.0009, alpha: 0.3, delay: 0.1),
        ),
      ], const <LineNode>[]),
      _cSparks()(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.4, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _caustic(
    kind: 'caustic-burn',
    label: '聚点',
    mood: _l,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.5,
          y: 0.2,
          angle: math.pi / 2,
          spread: -0.22,
          width: 0.2,
          length: 1.4,
          softness: 0.5,
          intensity: 1.2,
          streaks: 0.3,
          streakFreq: 5,
          core: 0.6,
          sway: const Oscillation(0.02, 9, 0),
        ),
        kShaft.copyWith(
          x: 0.5,
          y: -0.1,
          angle: math.pi / 2,
          spread: 0.03,
          width: 0.22,
          length: 1,
          intensity: 0.4,
          streaks: 0.4,
          reach: 0.3,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 1),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.65,
        radius: 0.05,
        intensity: 1.1,
        streak: 0.8,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      magnifier(c.aspect * 0.5, 0.2, 0.1),
      _cSparks(12)(c),
    ]),
    region: const TextRegion(0.5, 0.66, 0.72, 0.4),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.35, 1, 0, 3.6, Rgb(1, 0.7, 0.45)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _caustic(
    kind: 'caustic-shimmer',
    label: '粼粼',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: -0.05,
          y: 0.5,
          angle: 0.02,
          spread: 0.06,
          width: 0.5,
          length: 2.4,
          softness: 0.4,
          intensity: 0.8,
          streaks: 0.2,
          core: 0.2,
          gobo: const GoboSpec(GoboPattern.blinds, 18, 0.35, 0.3),
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: null,
      caustic: const CausticSpec(scale: 1.4, speed: 0.8, inBeam: 0.6),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      waterline(c.aspect, 0.86, 0.008, 9),
      _cSparks()(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.72, 0.5),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _caustic(
    kind: 'caustic-crystal',
    label: '晶影',
    mood: _n,
    light: rig(
      <BeamSpec>[
        for (int k = 0; k < 5; k++)
          kShaft.copyWith(
            x: 0.5,
            y: 0.26,
            angle: math.pi / 2 + (k - 2) * 0.45,
            spread: 0.05,
            width: 0.01,
            length: 0.8,
            softness: 0.5,
            intensity: 0.6,
            streaks: 0.3,
            core: 0.4,
            spectrum: 0.7,
            sway: Oscillation(0.05, 12, k * 0.15),
          ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(
        x: 0.5,
        y: 0.26,
        radius: 0.07,
        intensity: 1,
        streak: 0.5,
      ),
      caustic: const CausticSpec(
        scale: 3.4,
        speed: 0.2,
        inBeam: 0.4,
        floor: CausticFloor(0.5, 0.8, 0.3, 0.09, 0.5),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      crystal(c.aspect * 0.5, 0.26, 0.05),
      _cSparks(14)(c),
    ]),
    region: const TextRegion(0.5, 0.58, 0.72, 0.44),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _caustic(
    kind: 'caustic-drift',
    label: '漂流',
    mood: _q,
    light: rig(
      <BeamSpec>[
        _softTop(spread: 0.4, width: 0.4, intensity: 1, softness: 0.95),
      ],
      fog: kFog.copyWith(density: 0.8, driftX: 0.004, driftY: 0, ambient: 0.03),
      glare: kGlare.copyWith(intensity: 0.5),
      caustic: const CausticSpec(
        scale: 1,
        speed: 0.08,
        inBeam: 0.8,
        floor: CausticFloor(0.5, 0.5, 0.5, 0.4, 0.4),
      ),
    ),
    lineArt: _cSparks(8),
    region: const TextRegion(0.5, 0.5, 0.72, 0.62),
    typography: _v,
    decay: const DecaySpec(0.5, 1.8),
  ),
  _caustic(
    kind: 'caustic-storm',
    label: '骤光',
    mood: _l,
    light: rig(
      <BeamSpec>[
        _softTop(intensity: 1, pulse: const Oscillation(0.35, 0.9, 0)),
      ],
      fog: kFog.copyWith(density: 1.1),
      glare: kGlare.copyWith(intensity: 0.8),
      caustic: const CausticSpec(
        scale: 3,
        speed: 1.3,
        inBeam: 1,
        floor: CausticFloor(0.5, 0.82, 0.5, 0.14, 0.8),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      ripples(c.aspect * 0.5, 0.82, 0.5, 4),
      _cSparks(14)(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1.3, 0.7),
  ),
];

// ---------------------------------------------------------------------------
// 光路
// ---------------------------------------------------------------------------

final LumiereFamily _optics = LumiereFamily(
  'optics',
  region: const TextRegion(0.5, 0.74, 0.72, 0.3),
  heroSize: 0.075,
  motes: kMotes.copyWith(count: 180),
);

const double _axis = 0.4;

/// 一段光线：从 a 到 b（画面比例），默认在 b 处收住（open 时一直延伸）。
BeamSpec _ray(
  double aspect,
  (double, double) a,
  (double, double) b, {
  double? width,
  double? intensity,
  double? spread,
  bool open = false,
}) {
  final double dx = (b.$1 - a.$1) * aspect;
  final double dy = b.$2 - a.$2;
  return BeamSpec(
    x: a.$1,
    y: a.$2,
    angle: math.atan2(dy, dx),
    spread: spread ?? 0.004,
    width: width ?? 0.008,
    length: 3,
    softness: 0.6,
    intensity: intensity ?? 0.9,
    streaks: 0.1,
    streakFreq: 3,
    streakSpeed: 0.05,
    core: 0.8,
    reach: open ? 0 : math.sqrt(dx * dx + dy * dy) + 0.02,
  );
}

LineArtSpec _rayArt(
  double aspect,
  List<(double, double)> pts, [
  double delay = 0.2,
]) => rayPath(<Pt>[
  for (final (double, double) p in pts) (p.$1 * aspect, p.$2),
], delay: delay);

LightRig _opticsRig(List<BeamSpec> beams, [GlareSpec? glare]) => LightRig(
  beams: beams,
  fog: kFog.copyWith(density: 0.9, tyndallBase: 0.2, ambient: 0.02),
  glare: glare,
);

LineArtSpec _oSparks(RigContext c) => scatteredSparks(
  aspect: c.aspect,
  count: 10,
  random: c.random,
  delay: 0.3,
  region: (0.05, 0.05, 0.95, 0.6),
);

final List<LumiereProfile> opticsProfiles = <LumiereProfile>[
  _optics(
    kind: 'optics-convex',
    label: '会聚',
    mood: _n,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        for (final double y in <double>[0.3, 0.4, 0.5]) ...<BeamSpec>[
          _ray(c.aspect, (-0.02, y), (0.42, y)),
          _ray(c.aspect, (0.42, y), (0.7, _axis), open: true),
        ],
      ],
      const GlareSpec(
        x: 0.7,
        y: _axis,
        radius: 0.05,
        intensity: 0.9,
        streak: 0.6,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      lens(c.aspect * 0.42, _axis, 0.3, true, c.aspect),
      for (int i = 0; i < 3; i++)
        () {
          final double y = const <double>[0.3, 0.4, 0.5][i];
          return _rayArt(c.aspect, <(double, double)>[
            (0.02, y),
            (0.42, y),
            (0.7, _axis),
            (0.92, _axis + (_axis - y) * 0.8),
          ], 0.2 + i * 0.08);
        }(),
      focusMark(c.aspect * 0.7, _axis, delay: 0.5),
      _oSparks(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _optics(
    kind: 'optics-concave',
    label: '发散',
    mood: _q,
    light: (RigContext c) => _opticsRig(<BeamSpec>[
      for (final double y in <double>[0.32, 0.4, 0.48]) ...<BeamSpec>[
        _ray(c.aspect, (-0.02, y), (0.42, y), intensity: 0.7),
        _ray(
          c.aspect,
          (0.42, y),
          (0.42 + (0.42 - 0.26), y + (y - _axis) * 1.6),
          intensity: 0.7,
          spread: 0.01,
          open: true,
        ),
      ],
    ]),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      lens(c.aspect * 0.42, _axis, 0.28, false, c.aspect),
      for (int i = 0; i < 2; i++)
        () {
          final double y = const <double>[0.32, 0.48][i];
          return mergeArt(<LineArtSpec>[
            _rayArt(c.aspect, <(double, double)>[
              (0.02, y),
              (0.42, y),
              (0.62, y + (y - _axis) * 2.2),
            ], 0.2 + i * 0.1),
            LineArtSpec(<LinePath>[
              LinePath(
                points: <Pt>[(c.aspect * 0.42, y), (c.aspect * 0.26, _axis)],
                width: 0.0009,
                alpha: 0.35,
                delay: 0.5,
                dash: (0.005, 0.006),
              ),
            ], const <LineNode>[]),
          ]);
        }(),
      focusMark(c.aspect * 0.26, _axis, delay: 0.6),
      _oSparks(c),
    ]),
    region: const TextRegion(0.72, 0.56, 0.4, 0.72),
    typography: _v,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _optics(
    kind: 'optics-mirror',
    label: '反射',
    mood: _q,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        _ray(c.aspect, (0.12, 0.08), (0.5, 0.6), width: 0.02, intensity: 1),
        _ray(
          c.aspect,
          (0.5, 0.6),
          (0.88, 0.08),
          width: 0.02,
          intensity: 0.8,
          open: true,
        ),
      ],
      const GlareSpec(
        x: 0.5,
        y: 0.6,
        radius: 0.05,
        intensity: 0.8,
        streak: 0.7,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      mirror(c.aspect * 0.5, 0.6, 0.6, 0),
      _rayArt(c.aspect, <(double, double)>[
        (0.12, 0.08),
        (0.5, 0.6),
        (0.88, 0.08),
      ]),
      _oSparks(c),
    ]),
    region: const TextRegion(0.5, 0.34, 0.5, 0.36),
    heroSize: 0.07,
    typography: _x,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _optics(
    kind: 'optics-refract',
    label: '折射',
    mood: _n,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        _ray(c.aspect, (0.18, 0.05), (0.46, 0.5), width: 0.02, intensity: 1),
        _ray(
          c.aspect,
          (0.46, 0.5),
          (0.58, 1.05),
          width: 0.02,
          intensity: 0.8,
          open: true,
        ),
        _ray(
          c.aspect,
          (0.46, 0.5),
          (0.74, 0.05),
          width: 0.01,
          intensity: 0.3,
          open: true,
        ),
      ],
      const GlareSpec(
        x: 0.46,
        y: 0.5,
        radius: 0.05,
        intensity: 0.8,
        streak: 0.8,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      interfaceLine(c.aspect, 0.5),
      _rayArt(c.aspect, <(double, double)>[
        (0.18, 0.05),
        (0.46, 0.5),
        (0.58, 0.98),
      ]),
      LineArtSpec(<LinePath>[
        LinePath(
          points: <Pt>[(c.aspect * 0.46, 0.18), (c.aspect * 0.46, 0.82)],
          width: 0.0009,
          alpha: 0.35,
          delay: 0.4,
          dash: (0.006, 0.006),
        ),
      ], const <LineNode>[]),
      _oSparks(c),
    ]),
    region: const TextRegion(0.72, 0.3, 0.44, 0.3),
    heroSize: 0.07,
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _optics(
    kind: 'optics-bench',
    label: '光具座',
    mood: _n,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        _ray(
          c.aspect,
          (-0.02, _axis),
          (0.3, _axis),
          width: 0.05,
          spread: 0.01,
          intensity: 0.8,
        ),
        _ray(
          c.aspect,
          (0.3, _axis),
          (0.5, _axis),
          width: 0.05,
          intensity: 0.9,
        ).copyWith(spread: -0.06),
        _ray(
          c.aspect,
          (0.5, _axis),
          (0.7, _axis),
          width: 0.02,
          intensity: 0.9,
        ).copyWith(spread: 0.06),
        _ray(
          c.aspect,
          (0.7, _axis),
          (1.02, _axis),
          width: 0.05,
          intensity: 0.7,
          open: true,
        ),
      ],
      const GlareSpec(
        x: 0.5,
        y: _axis,
        radius: 0.04,
        intensity: 0.7,
        streak: 0.6,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      for (int i = 0; i < 3; i++)
        lens(
          c.aspect * const <double>[0.3, 0.5, 0.7][i],
          _axis,
          0.16 + (i % 2) * 0.04,
          i != 1,
          c.aspect,
          ArtStyle(delay: i * 0.1),
        ),
      ruler(c.aspect * 0.06, c.aspect * 0.94, 0.58, 40, delay: 0.3),
      _oSparks(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _optics(
    kind: 'optics-periscope',
    label: '潜望',
    mood: _n,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        _ray(c.aspect, (1.02, 0.14), (0.3, 0.14), width: 0.02),
        _ray(c.aspect, (0.3, 0.14), (0.3, 0.84), width: 0.02),
        _ray(
          c.aspect,
          (0.3, 0.84),
          (1.02, 0.84),
          width: 0.02,
          intensity: 0.8,
          open: true,
        ),
      ],
      const GlareSpec(
        x: 0.3,
        y: 0.14,
        radius: 0.04,
        intensity: 0.7,
        streak: 0.4,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      mirror(c.aspect * 0.3, 0.14, 0.14, math.pi / 4),
      mirror(c.aspect * 0.3, 0.84, 0.14, math.pi / 4, delay: 0.1),
      _rayArt(c.aspect, <(double, double)>[
        (0.98, 0.14),
        (0.3, 0.14),
        (0.3, 0.84),
        (0.98, 0.84),
      ]),
      _oSparks(c),
    ]),
    region: const TextRegion(0.62, 0.49, 0.4, 0.5),
    typography: _v,
    decay: const DecaySpec(0.8, 1.2),
  ),
  _optics(
    kind: 'optics-fiber',
    label: '光纤',
    mood: _l,
    light: (RigContext c) => _opticsRig(
      const <BeamSpec>[
        BeamSpec(
          x: 0.84,
          y: 0.2,
          angle: -0.5,
          spread: 0.3,
          width: 0.02,
          length: 0.9,
          softness: 0.6,
          intensity: 1.2,
          streaks: 0.5,
          streakFreq: 9,
          streakSpeed: 0.1,
          core: 0.6,
          pulse: Oscillation(0.2, 2.3, 0),
        ),
        BeamSpec(
          x: 0.84,
          y: 0.2,
          angle: -0.5,
          spread: 0.08,
          width: 0.02,
          length: 1.2,
          softness: 0.5,
          intensity: 0.9,
          streaks: 0.2,
          streakFreq: 3,
          streakSpeed: 0,
          core: 0.8,
        ),
      ],
      const GlareSpec(
        x: 0.84,
        y: 0.2,
        radius: 0.07,
        intensity: 1.2,
        streak: 0.8,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      fiber(
        (c.aspect * 0.04, 0.86),
        (c.aspect * 0.4, 0.95),
        (c.aspect * 0.5, 0.1),
        (c.aspect * 0.84, 0.2),
        0.012,
      ),
      _oSparks(c),
    ]),
    region: const TextRegion(0.46, 0.52, 0.6, 0.5),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.3, 2, 0, 3.2, Rgb(0.8, 0.9, 1)),
    decay: const DecaySpec(1.3, 0.7),
    starfall: const StarfallSpec(
      stars: 380,
      opening: 3,
      rain: 60,
      rainSpeed: 0.3,
      rainSpread: 0.8,
      brightness: 1,
    ),
  ),
  _optics(
    kind: 'optics-pinhole',
    label: '暗箱',
    mood: _q,
    light: (RigContext c) {
      final double distance = 0.47 * c.aspect;
      return _opticsRig(
        <BeamSpec>[
          BeamSpec(
            x: -0.02,
            y: _axis,
            angle: 0,
            spread: -math.atan(0.15 / distance),
            width: 0.3,
            length: 3,
            softness: 0.4,
            intensity: 0.8,
            streaks: 0.3,
            streakFreq: 6,
            streakSpeed: 0.05,
            core: 0.3,
            reach: distance + 0.3,
          ),
        ],
        const GlareSpec(
          x: 0.45,
          y: _axis,
          radius: 0.03,
          intensity: 1,
          streak: 0.3,
        ),
      );
    },
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      pinholeBox(c.aspect * 0.45 + 0.15, _axis, 0.3, 0.3),
      _oSparks(c),
    ]),
    region: const TextRegion(0.2, 0.52, 0.3, 0.7),
    heroSize: 0.07,
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _optics(
    kind: 'optics-telescope',
    label: '望远',
    mood: _l,
    light: (RigContext c) => _opticsRig(
      <BeamSpec>[
        for (final double y in <double>[0.3, 0.5]) ...<BeamSpec>[
          _ray(c.aspect, (-0.02, y), (0.28, y), width: 0.02),
          _ray(c.aspect, (0.28, y), (0.62, _axis)),
          _ray(
            c.aspect,
            (0.72, _axis + (y - _axis) * 0.3),
            (1.02, _axis + (y - _axis) * 0.3),
            width: 0.02,
            intensity: 1.1,
            open: true,
          ),
        ],
      ],
      const GlareSpec(
        x: 0.62,
        y: _axis,
        radius: 0.05,
        intensity: 1,
        streak: 0.8,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      lens(c.aspect * 0.28, _axis, 0.36, true, c.aspect),
      lens(
        c.aspect * 0.72,
        _axis,
        0.12,
        true,
        c.aspect,
        const ArtStyle(delay: 0.1),
      ),
      for (int i = 0; i < 2; i++)
        () {
          final double y = const <double>[0.3, 0.5][i];
          return _rayArt(c.aspect, <(double, double)>[
            (0.02, y),
            (0.28, y),
            (0.62, _axis),
            (0.72, _axis - (y - _axis) * 0.3),
            (0.98, _axis - (y - _axis) * 0.3),
          ], 0.2 + i * 0.1);
        }(),
      focusMark(c.aspect * 0.62, _axis, delay: 0.5),
      _oSparks(c),
    ]),
    typography: _h,
    burst: const BurstSpec(BurstMode.sung, 0.25, 2, 1, 3.2, Rgb(1, 0.8, 0.55)),
    decay: const DecaySpec(1.2, 0.8),
  ),
  _optics(
    kind: 'optics-raytrace',
    label: '追迹',
    mood: _l,
    light: (RigContext c) {
      final List<(double, double)> pts = <(double, double)>[
        for (int i = 0; i < 7; i++)
          (0.05 + i / 6 * 0.9, 0.1 + c.random() * 0.55),
      ];
      return _opticsRig(
        <BeamSpec>[
          for (int i = 0; i < 6; i++)
            _ray(c.aspect, pts[i], pts[i + 1], intensity: 0.8, width: 0.012),
        ],
        GlareSpec(
          x: pts[0].$1,
          y: pts[0].$2,
          radius: 0.05,
          intensity: 0.9,
          streak: 0.6,
        ),
      );
    },
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      for (int k = 0; k < 4; k++)
        _rayArt(c.aspect, <(double, double)>[
          for (int i = 0; i < 6; i++)
            (0.05 + i / 5 * 0.9, 0.08 + c.random() * 0.6),
        ], 0.1 + k * 0.1),
      scatteredSparks(
        aspect: c.aspect,
        count: 16,
        random: c.random,
        delay: 0.3,
      ),
    ]),
    typography: _x,
    decay: const DecaySpec(1.3, 0.7),
  ),
];
