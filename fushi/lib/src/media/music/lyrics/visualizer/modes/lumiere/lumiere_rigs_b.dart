/// 光位目录（下半）：衍射、叶脉、星象、追光、萤尘五族，每族 10 个（folia `lumiere/rigs/*.ts`，数值原样搬）。
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

ArtBuilder _sparks(int count) =>
    (RigContext c) => scatteredSparks(
      aspect: c.aspect,
      count: count,
      random: c.random,
      delay: 0.3,
    );

// ---------------------------------------------------------------------------
// 衍射
// ---------------------------------------------------------------------------

final LumiereFamily _wave = LumiereFamily(
  'wave',
  starfall: kStarfall.copyWith(rain: 40),
);
final ArtBuilder _wSparks = _sparks(12);

final List<LumiereProfile> waveProfiles = <LumiereProfile>[
  _wave(
    kind: 'wave-slits',
    label: '双缝',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(spread: 0.05, width: 0.04, length: 0.6, intensity: 0.9),
      ],
      fog: kFog.copyWith(density: 0.9),
      wave: const WaveSpec(
        mode: WaveMode.slits,
        cx: 0.5,
        cy: 0.72,
        radius: 0.3,
        frequency: 5,
        speed: 0.4,
        strength: 0.55,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      slitBarrier(
        cx: c.aspect * 0.5,
        y: 0.3,
        width: c.aspect * 0.5,
        gap: 0.012,
        separation: 0.08,
      ),
      viewfinderFrame(
        aspect: c.aspect,
        left: 0.2,
        top: 0.52,
        right: 0.8,
        bottom: 0.92,
        delay: 0.2,
        alpha: 0.28,
      ),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.72, 0.5),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _wave(
    kind: 'wave-newton',
    label: '牛顿环',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(spread: 0.06, width: 0.04, length: 0.6, intensity: 0.6),
      ],
      fog: kFog.copyWith(density: 0.7),
      glare: kGlare.copyWith(intensity: 0.5),
      wave: const WaveSpec(
        mode: WaveMode.rings,
        cx: 0.5,
        cy: 0.5,
        radius: 0.4,
        frequency: 5,
        speed: 0.3,
        strength: 0.5,
        shield: 0.75,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      ringsArt(c.aspect * 0.5, 0.5, 0.4, 6),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.4, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _wave(
    kind: 'wave-airy',
    label: '艾里斑',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.5,
          y: -0.05,
          spread: 0.02,
          width: 0.01,
          length: 0.6,
          intensity: 0.5,
          reach: 0.4,
        ),
      ],
      fog: kFog.copyWith(density: 0.6),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.4,
        radius: 0.04,
        intensity: 1,
        streak: 0.4,
      ),
      wave: const WaveSpec(
        mode: WaveMode.airy,
        cx: 0.5,
        cy: 0.4,
        radius: 0.3,
        frequency: 3,
        speed: 0,
        strength: 0.7,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      ringsArt(c.aspect * 0.5, 0.4, 0.3, 4, const ArtStyle(alpha: 0.3)),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.72, 0.72, 0.36),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _wave(
    kind: 'wave-grating',
    label: '光栅',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.01,
          width: 0.03,
          length: 2,
          intensity: 0.9,
          reach: 0.32,
          noSway: true,
        ),
        for (final int k in <int>[-2, -1, 0, 1, 2])
          kShaft.copyWith(
            y: 0.3,
            angle: math.pi / 2 + k * 0.32,
            spread: 0.02,
            width: 0.02,
            length: 1.2,
            intensity: 0.8 - k.abs() * 0.15,
            streaks: 0.2,
            core: 0.6,
            spectrum: k == 0 ? 0 : 0.8,
            noSway: true,
          ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(y: 0.3, radius: 0.05, intensity: 0.9, streak: 0.6),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      grating(c.aspect * 0.5, 0.3, c.aspect * 0.4, 16),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.7, 0.72, 0.38),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _wave(
    kind: 'wave-sources',
    label: '波叠',
    mood: _l,
    light: rig(
      <BeamSpec>[kShaft.copyWith(spread: 0.15, intensity: 0.4)],
      fog: kFog.copyWith(density: 0.8),
      glare: kGlare.copyWith(intensity: 0.5),
      wave: const WaveSpec(
        mode: WaveMode.sources,
        cx: 0.5,
        cy: 0.5,
        radius: 0.46,
        frequency: 4,
        speed: 1.2,
        strength: 0.6,
        separation: 0.14,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      twoSources(c.aspect * 0.5, 0.5, 0.14, 0.3),
      _wSparks(c),
    ]),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.3, 2, 0, 3.2, Rgb(0.85, 0.9, 1)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _wave(
    kind: 'wave-moire',
    label: '莫尔',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.2,
          width: 0.3,
          length: 1.3,
          softness: 0.6,
          intensity: 0.6,
          streaks: 0,
          core: 0.2,
          gobo: const GoboSpec(GoboPattern.blinds, 22, 0.5, 0.02),
          noSway: true,
        ),
        kShaft.copyWith(
          angle: math.pi / 2 + 0.06,
          spread: 0.2,
          width: 0.3,
          length: 1.3,
          softness: 0.6,
          intensity: 0.6,
          streaks: 0,
          core: 0.2,
          gobo: const GoboSpec(GoboPattern.blinds, 23, 0.5, -0.02),
          sway: const Oscillation(0.03, 14, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: kGlare.copyWith(intensity: 0.5),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      moire(c.aspect * 0.5, 0.32, 0.4, 24, 0.08),
      _wSparks(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _wave(
    kind: 'wave-film',
    label: '薄膜',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.4,
          width: 0.3,
          length: 1.2,
          softness: 0.95,
          intensity: 0.45,
          streaks: 0.6,
          streakFreq: 3,
          streakSpeed: 0.2,
          core: 0.2,
          spectrum: 1,
          sway: const Oscillation(0.15, 13, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.7),
      glare: null,
      wave: const WaveSpec(
        mode: WaveMode.rings,
        cx: 0.5,
        cy: 0.4,
        radius: 0.3,
        frequency: 1.6,
        speed: 0.6,
        strength: 0.25,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      LineArtSpec(<LinePath>[
        circle(
          c.aspect * 0.5,
          0.4,
          0.3,
          const ArtStyle(width: 0.0016, alpha: 0.45),
        ),
        circle(
          c.aspect * 0.5 - 0.08,
          0.3,
          0.06,
          const ArtStyle(width: 0.001, alpha: 0.3, delay: 0.2),
        ),
      ], const <LineNode>[]),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.4, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _wave(
    kind: 'wave-polar',
    label: '偏振',
    mood: _n,
    light: (RigContext c) {
      final double second = c.aspect * 0.5 + 0.12;
      return LightRig(
        beams: <BeamSpec>[
          kShaft.copyWith(
            x: -0.02,
            y: 0.36,
            angle: 0,
            spread: 0.02,
            width: 0.14,
            length: 3,
            intensity: 0.8,
            streaks: 0.2,
            core: 0.4,
            reach: second + 0.02 * c.aspect,
            noSway: true,
          ),
          kShaft.copyWith(
            x: second / c.aspect,
            y: 0.36,
            angle: 0,
            spread: 0.02,
            width: 0.14,
            length: 3,
            intensity: 0.7,
            streaks: 0.2,
            core: 0.4,
            noSway: true,
            pulse: const Oscillation(0.9, 6, 0),
          ),
        ],
        fog: kFog.copyWith(density: 0.8),
      );
    },
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      polarizers(c.aspect * 0.5, 0.36, 0.1, 0.24, math.pi / 3),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.7, 0.72, 0.36),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _wave(
    kind: 'wave-standing',
    label: '驻波',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 3; i++)
          kShaft.copyWith(
            x: -0.02,
            y: const <double>[0.26, 0.34, 0.42][i],
            angle: 0,
            spread: 0.004,
            width: 0.01,
            length: 3,
            intensity: 0.7,
            streaks: 0.6,
            streakFreq: 4,
            core: 0.8,
            noSway: true,
            pulse: Oscillation(0.6, 1.2, i / 3),
          ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: null,
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      standingWave(c.aspect * 0.08, c.aspect * 0.92, 0.34, 0.07, 6),
      _wSparks(c),
    ]),
    typography: _x,
    decay: const DecaySpec(1.3, 0.7),
  ),
  _wave(
    kind: 'wave-holo',
    label: '全息',
    mood: _l,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.3,
          width: 0.3,
          length: 1.3,
          softness: 0.8,
          intensity: 0.8,
          streaks: 0.3,
          core: 0.3,
          spectrum: 0.8,
          gobo: const GoboSpec(GoboPattern.lattice, 24, 0.7, 0.15),
          sway: const Oscillation(0.1, 10, 0),
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: kGlare.copyWith(intensity: 0.6),
      wave: const WaveSpec(
        mode: WaveMode.rings,
        cx: 0.5,
        cy: 0.5,
        radius: 0.5,
        frequency: 8,
        speed: 1,
        strength: 0.15,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      gridPanel(
        c.aspect * 0.3,
        0.15,
        c.aspect * 0.4,
        0.7,
        6,
        8,
        diagonal: true,
        style: const ArtStyle(alpha: 0.3),
      ),
      _wSparks(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.4, 0.62),
    typography: _v,
    decay: const DecaySpec(1.3, 0.7),
  ),
];

// ---------------------------------------------------------------------------
// 叶脉
// ---------------------------------------------------------------------------

/// 「萌芽」是第一个光位（参考图底部）。
final LumiereProfile botanySprout = LumiereProfile(
  kind: 'botany-sprout',
  label: '萌芽',
  family: 'botany',
  mood: _q,
  light: (RigContext _) => const LightRig(
    beams: <BeamSpec>[
      BeamSpec(
        x: 0.5,
        y: -0.05,
        angle: math.pi / 2,
        spread: 0.075,
        width: 0.07,
        length: 1.2,
        softness: 0.7,
        intensity: 0.95,
        streaks: 0.5,
        streakFreq: 6,
        streakSpeed: 0.06,
        core: 0.7,
        sway: Oscillation(0.008, 15, 0.2),
      ),
      BeamSpec(
        x: 0.5,
        y: -0.05,
        angle: math.pi / 2,
        spread: 0.26,
        length: 0.75,
        softness: 0.95,
        intensity: 0.42,
        streaks: 0.85,
        streakFreq: 30,
        streakSpeed: 0.04,
        core: 0.3,
      ),
    ],
    fog: FogSpec(
      density: 0.9,
      tyndallBase: 0.14,
      scale: 2,
      driftX: -0.006,
      driftY: -0.03,
      warp: 1.1,
      ambient: 0.025,
    ),
    glare: GlareSpec(
      x: 0.5,
      y: -0.01,
      radius: 0.1,
      intensity: 0.9,
      streak: 0.35,
    ),
  ),
  motes: const MotesSpec(
    count: 200,
    sizeMin: 0.004,
    sizeMax: 0.011,
    driftX: -0.003,
    driftY: -0.012,
    swirl: 0.018,
    swirlPeriod: 11,
    twinkle: 0.55,
    ambient: 0.012,
    gain: 1.2,
  ),
  front: const MotesSpec(
    count: 6,
    sizeMin: 0.05,
    sizeMax: 0.12,
    driftX: -0.004,
    driftY: -0.002,
    swirl: 0.01,
    swirlPeriod: 16,
    twinkle: 0.2,
    ambient: 0.015,
    gain: 0.25,
  ),
  lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
    sprout(cx: c.aspect * 0.5, baseY: 0.78, size: 0.22, alpha: 1),
    protractorHalo(
      cx: c.aspect * 0.5,
      cy: 0.02,
      radius: 0.22,
      alpha: 0.35,
      delay: 0.2,
    ),
    viewfinderFrame(
      aspect: c.aspect,
      left: 0.07,
      top: 0.22,
      right: 0.93,
      bottom: 0.8,
      delay: 0.25,
      alpha: 0.22,
    ),
    scatteredSparks(
      aspect: c.aspect,
      count: 12,
      random: c.random,
      delay: 0.35,
      region: (0.2, 0.3, 0.8, 0.9),
    ),
  ]),
  region: const TextRegion(0.5, 0.44, 0.72, 0.6),
  heroSize: 0.08,
  echoSize: 0.28,
  typography: _v,
  decay: const DecaySpec(0.75, 1.2),
  starfall: const StarfallSpec(
    stars: 300,
    opening: 3.6,
    rain: 50,
    rainSpeed: 0.16,
    rainSpread: 0.25,
    brightness: 0.85,
  ),
  camera: const CameraSpec(0.03, 0, 0.004),
);

final LumiereFamily _botany = LumiereFamily(
  'botany',
  motes: kMotes.copyWith(count: 220, driftY: -0.012),
  artGain: 1.7,
  starfall: kStarfall.copyWith(rain: 40),
);
final ArtBuilder _bSparks = _sparks(12);

final List<LumiereProfile> botanyProfiles = <LumiereProfile>[
  botanySprout,
  _botany(
    kind: 'botany-veins',
    label: '叶脉',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.15,
          y: -0.05,
          angle: 1.1,
          spread: 0.12,
          width: 0.12,
          length: 1.4,
          intensity: 0.9,
          streaks: 0.5,
          streakFreq: 6,
        ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: kGlare.copyWith(x: 0.15, y: -0.02, radius: 0.14, intensity: 0.8),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      bigLeaf(c.aspect * 0.52, 0.42, 0.62, -0.45),
      _bSparks(c),
    ]),
    region: const TextRegion(0.5, 0.72, 0.72, 0.36),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _botany(
    kind: 'botany-canopy',
    label: '林冠',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 3; i++)
          kShaft.copyWith(
            x: const <double>[0.25, 0.48, 0.7][i],
            y: -0.05,
            angle: 1.45 + i * 0.1,
            spread: 0.08,
            width: 0.08,
            length: 1.3,
            softness: 0.6,
            intensity: 0.85,
            streaks: 0.5,
            streakFreq: 6,
            gobo: const GoboSpec(GoboPattern.leaves, 9, 0.5, 0.14),
            sway: Oscillation(0.03, 6.0 + i, i * 0.3),
          ),
      ],
      fog: kFog.copyWith(density: 1.1, driftX: 0.008),
      glare: null,
    ),
    lineArt: (RigContext c) =>
        mergeArt(<LineArtSpec>[canopy(c.aspect, c.random), _sparks(16)(c)]),
    motes: kMotes.copyWith(
      count: 300,
      driftX: 0.008,
      driftY: 0.006,
      swirl: 0.03,
    ),
    typography: _x,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall.copyWith(rain: 90, rainSpread: 1.2),
  ),
  _botany(
    kind: 'botany-fern',
    label: '蕨卷',
    mood: _n,
    light: rig(<BeamSpec>[
      kShaft.copyWith(x: 0.3, spread: 0.08, intensity: 0.85),
      kFan.copyWith(x: 0.3, intensity: 0.2),
    ]),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      fernCurl(c.aspect * 0.28, 0.42, 0.16),
      _bSparks(c),
    ]),
    region: const TextRegion(0.62, 0.5, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(0.8, 1.2),
  ),
  _botany(
    kind: 'botany-seed',
    label: '种子',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.04,
          width: 0.02,
          length: 1.2,
          intensity: 0.8,
          core: 0.9,
        ),
      ],
      fog: kFog.copyWith(density: 0.7, ambient: 0.02),
      glare: kGlare.copyWith(intensity: 0.6),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      seedRoots(c.aspect * 0.5, 0.7, c.random),
      _sparks(10)(c),
    ]),
    region: const TextRegion(0.5, 0.38, 0.72, 0.4),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _botany(
    kind: 'botany-bloom',
    label: '绽放',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int k = 0; k < 6; k++)
          kShaft.copyWith(
            x: 0.5,
            y: 0.42,
            angle: k / 6 * kTau + 0.26,
            spread: 0.12,
            width: 0.01,
            length: 0.6,
            softness: 0.7,
            intensity: 0.55,
            streaks: 0.5,
            streakFreq: 7,
            core: 0.4,
            reach: 0.45,
            sway: Oscillation(0.05, 10, k / 6),
          ),
      ],
      fog: kFog.copyWith(density: 0.9),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.42,
        radius: 0.1,
        intensity: 1.2,
        streak: 0.4,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      bloomArt(c.aspect * 0.5, 0.42, 0.2, 8),
      _bSparks(c),
    ]),
    typography: _x,
    burst: const BurstSpec(BurstMode.sweep, 0.5, 3, 1, 3, Rgb(1, 0.8, 0.7)),
    decay: const DecaySpec(1.2, 0.8),
  ),
  _botany(
    kind: 'botany-vine',
    label: '藤旋',
    mood: _n,
    light: rig(<BeamSpec>[
      kShaft.copyWith(x: 0.72, spread: 0.07, intensity: 0.9),
      kFan.copyWith(x: 0.72, intensity: 0.2),
    ], glare: kGlare.copyWith(x: 0.72)),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      vine(c.aspect * 0.72, 1.02, 0.08, 0.05, 4),
      _bSparks(c),
    ]),
    region: const TextRegion(0.36, 0.5, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(1, 1),
  ),
  _botany(
    kind: 'botany-chloro',
    label: '叶绿',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.2,
          width: 0.3,
          softness: 0.9,
          intensity: 0.6,
          core: 0.3,
        ),
      ],
      fog: kFog.copyWith(density: 0.7),
      glare: null,
      caustic: const CausticSpec(
        scale: 6,
        speed: 0.12,
        inBeam: 0.3,
        floor: CausticFloor(0.5, 0.45, 0.2, 0.36, 0.35),
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      cells(c.aspect * 0.5, 0.45, 0.36, c.random, 22),
      _sparks(8)(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.5, 0.5),
    typography: _x,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _botany(
    kind: 'botany-formula',
    label: '光合式',
    mood: _n,
    light: rig(<BeamSpec>[kShaft, kFan]),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      molecule(c.aspect * 0.24, 0.3, 0.06),
      molecule(c.aspect * 0.78, 0.74, 0.05, delay: 0.2),
      protractorHalo(cx: c.aspect * 0.5, cy: 0.03, radius: 0.28, alpha: 0.5),
      _bSparks(c),
    ]),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _botany(
    kind: 'botany-pollen',
    label: '花粉',
    mood: _l,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.2,
          y: -0.05,
          angle: 1.15,
          spread: 0.14,
          width: 0.16,
          length: 1.5,
          intensity: 1,
          streaks: 0.5,
        ),
        kFan.copyWith(x: 0.2, angle: 1.15, intensity: 0.3),
      ],
      fog: kFog.copyWith(density: 1, driftX: 0.012, driftY: -0.01),
      glare: kGlare.copyWith(x: 0.2, y: 0),
    ),
    lineArt: _bSparks,
    motes: const MotesSpec(
      count: 360,
      sizeMin: 0.006,
      sizeMax: 0.022,
      driftX: 0.012,
      driftY: -0.006,
      swirl: 0.04,
      swirlPeriod: 10,
      twinkle: 0.4,
      ambient: 0.02,
      gain: 1.6,
    ),
    typography: _h,
    decay: const DecaySpec(1.2, 0.8),
  ),
];

// ---------------------------------------------------------------------------
// 星象
// ---------------------------------------------------------------------------

final LumiereFamily _astral = LumiereFamily(
  'astral',
  starfall: kStarfall.copyWith(stars: 620, rain: 20, brightness: 1.1),
  motes: kMotes.copyWith(count: 160),
  artGain: 2,
);
final ArtBuilder _aSparks = _sparks(20);

/// 从圆盘 (cx, cy, r) 的边缘向外放射的一圈光束（日冕、日食）。
List<BeamSpec> _radial(
  double cx,
  double cy,
  double r,
  double aspect,
  int count, {
  double? length,
  double? intensity,
}) => <BeamSpec>[
  for (int k = 0; k < count; k++)
    () {
      final double angle = k / count * kTau + 0.3;
      return kShaft.copyWith(
        x: cx + math.cos(angle) * r / aspect,
        y: cy + math.sin(angle) * r,
        angle: angle,
        spread: 0.14,
        width: 0.04,
        length: length ?? 0.35,
        softness: 0.8,
        intensity: intensity ?? 0.7,
        streaks: 0.7,
        streakFreq: 12,
        core: 0.3,
        sway: Oscillation(0.04, 9.0 + k, k / count),
      );
    }(),
];

final List<LumiereProfile> astralProfiles = <LumiereProfile>[
  _astral(
    kind: 'astral-eclipse',
    label: '日食',
    mood: _l,
    light: (RigContext c) => LightRig(
      beams: _radial(0.5, 0.34, 0.13, c.aspect, 6),
      fog: const FogSpec(
        density: 0.8,
        tyndallBase: 0.2,
        scale: 2.4,
        driftX: 0.004,
        driftY: -0.01,
        warp: 0.9,
        ambient: 0.02,
      ),
      glare: GlareSpec(
        x: 0.5 + 0.13 * math.cos(-0.8) / c.aspect,
        y: 0.34 + 0.13 * math.sin(-0.8),
        radius: 0.05,
        intensity: 1.3,
        streak: 0.9,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      corona(c.aspect * 0.5, 0.34, 0.13, c.random),
      _aSparks(c),
    ]),
    region: const TextRegion(0.5, 0.7, 0.72, 0.4),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.35, 1, 0, 3.6, Rgb(1, 0.6, 0.45)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _astral(
    kind: 'astral-orbit',
    label: '轨道',
    mood: _q,
    light: rig(
      <BeamSpec>[kShaft.copyWith(spread: 0.05, intensity: 0.45, reach: 0.4)],
      fog: kFog.copyWith(density: 0.6, ambient: 0.015),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.42,
        radius: 0.05,
        intensity: 1,
        streak: 0.5,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      orbits(
        c.aspect * 0.5,
        0.42,
        const <double>[0.12, 0.2, 0.3, 0.42],
        -0.18,
        0.34,
        c.random,
      ),
      _aSparks(c),
    ]),
    region: const TextRegion(0.5, 0.74, 0.72, 0.32),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _astral(
    kind: 'astral-trail',
    label: '星轨',
    mood: _q,
    light: rig(
      <BeamSpec>[kShaft.copyWith(x: 0.72, spread: 0.04, intensity: 0.35)],
      fog: kFog.copyWith(density: 0.5, ambient: 0.01),
      glare: null,
    ),
    lineArt: (RigContext c) =>
        starTrails(c.aspect * 0.72, 0.12, c.random, 60, 0.9),
    region: const TextRegion(0.36, 0.54, 0.44, 0.6),
    typography: _v,
    decay: const DecaySpec(0.5, 1.8),
  ),
  _astral(
    kind: 'astral-sextant',
    label: '六分仪',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.85,
          y: -0.05,
          angle: 2.2,
          spread: 0.05,
          width: 0.03,
          length: 1.4,
          intensity: 0.9,
        ),
      ],
      fog: kFog.copyWith(density: 0.8),
      glare: kGlare.copyWith(x: 0.85, y: -0.02),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      sextant(c.aspect * 0.4, 0.14, 0.32),
      _aSparks(c),
    ]),
    region: const TextRegion(0.52, 0.66, 0.72, 0.4),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _astral(
    kind: 'astral-constellation',
    label: '星座',
    mood: _n,
    light: rig(
      <BeamSpec>[kShaft.copyWith(spread: 0.06, intensity: 0.4)],
      fog: kFog.copyWith(density: 0.6, ambient: 0.015),
      glare: kGlare.copyWith(intensity: 0.4),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      constellation(c.aspect, c.random, 8, (0.1, 0.1, 0.9, 0.42)),
      constellation(c.aspect, c.random, 5, (0.6, 0.62, 0.95, 0.9), delay: 0.3),
    ]),
    region: const TextRegion(0.42, 0.66, 0.6, 0.4),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _astral(
    kind: 'astral-corona',
    label: '日冕',
    mood: _l,
    light: (RigContext c) => LightRig(
      beams: _radial(0.5, 0.12, 0.1, c.aspect, 6, length: 0.6, intensity: 0.9),
      fog: const FogSpec(
        density: 1,
        tyndallBase: 0.15,
        scale: 2.4,
        driftX: 0.004,
        driftY: -0.02,
        warp: 0.9,
        ambient: 0.03,
      ),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.12,
        radius: 0.16,
        intensity: 1.3,
        streak: 0.7,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      corona(c.aspect * 0.5, 0.12, 0.1, c.random),
      _aSparks(c),
    ]),
    region: const TextRegion(0.5, 0.62, 0.72, 0.46),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.3, 2, 0, 3.4, Rgb(1, 0.65, 0.4)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _astral(
    kind: 'astral-moon',
    label: '月光',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.82,
          y: 0.12,
          angle: 2.1,
          spread: 0.12,
          width: 0.08,
          length: 1.4,
          softness: 0.8,
          intensity: 0.75,
          tint: const Rgb(0.72, 0.82, 1),
        ),
      ],
      fog: kFog.copyWith(
        density: 1.2,
        driftX: -0.01,
        driftY: 0,
        ambient: 0.035,
        warp: 1.3,
      ),
      glare: const GlareSpec(
        x: 0.82,
        y: 0.12,
        radius: 0.1,
        intensity: 0.8,
        streak: 0.2,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      crescent(c.aspect * 0.82, 0.12, 0.07),
      _aSparks(c),
    ]),
    region: const TextRegion(0.38, 0.54, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _astral(
    kind: 'astral-nebula',
    label: '星云',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.4,
          y: 0.45,
          angle: -0.6,
          spread: 0.6,
          width: 0.1,
          length: 0.8,
          softness: 1,
          intensity: 0.5,
          streaks: 0.6,
          streakFreq: 3,
          core: 0.2,
          spectrum: 0.7,
          sway: const Oscillation(0.2, 20, 0),
        ),
        kShaft.copyWith(
          x: 0.6,
          y: 0.45,
          angle: 2.4,
          spread: 0.6,
          width: 0.1,
          length: 0.8,
          softness: 1,
          intensity: 0.4,
          streaks: 0.6,
          streakFreq: 3,
          core: 0.2,
          spectrum: 0.7,
          sway: const Oscillation(0.2, 23, 0.5),
        ),
      ],
      fog: kFog.copyWith(
        density: 1.4,
        ambient: 0.06,
        warp: 1.6,
        scale: 1.6,
        driftX: 0.006,
        driftY: 0.002,
      ),
      glare: const GlareSpec(
        x: 0.5,
        y: 0.45,
        radius: 0.08,
        intensity: 0.7,
        streak: 0.2,
      ),
    ),
    lineArt: _aSparks,
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _astral(
    kind: 'astral-armillary',
    label: '浑天',
    mood: _n,
    light: rig(<BeamSpec>[kShaft, kFan.copyWith(intensity: 0.2)]),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      armillary(c.aspect * 0.5, 0.42, 0.26),
      _aSparks(c),
    ]),
    region: const TextRegion(0.5, 0.5, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(1, 1),
  ),
  _astral(
    kind: 'astral-meteor',
    label: '流星',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 3; i++)
          kShaft.copyWith(
            x: 0.95 - i * 0.2,
            y: -0.02 + i * 0.05,
            angle: 2.5,
            spread: 0.01,
            width: 0.006,
            length: 0.6,
            intensity: 0.9,
            streaks: 0.2,
            core: 0.8,
            reach: 0.5 + i * 0.1,
            pulse: Oscillation(0.7, 2.2 + i * 0.7, i * 0.3),
            noSway: true,
          ),
      ],
      fog: kFog.copyWith(density: 0.7, ambient: 0.015),
      glare: null,
    ),
    lineArt: (RigContext c) =>
        mergeArt(<LineArtSpec>[meteors(c.aspect, c.random, 6), _aSparks(c)]),
    typography: _x,
    decay: const DecaySpec(1.3, 0.7),
    starfall: kStarfall.copyWith(
      stars: 620,
      rain: 60,
      rainSpeed: 0.6,
      rainSpread: 1.8,
      brightness: 1.2,
    ),
  ),
];

// ---------------------------------------------------------------------------
// 追光
// ---------------------------------------------------------------------------

final LumiereFamily _stage = LumiereFamily(
  'stage',
  motes: kMotes.copyWith(count: 200),
);

const FogSpec _haze = FogSpec(
  density: 1.25,
  tyndallBase: 0.08,
  scale: 2,
  driftX: 0.01,
  driftY: -0.015,
  warp: 1.1,
  ambient: 0.035,
);

/// 从 a 指向 b（画面比例）的一盏灯。
BeamSpec _lamp(
  double aspect,
  (double, double) a,
  (double, double) b, {
  Oscillation? sway,
  double? spread,
  double? width,
  double? intensity,
  double? core,
  Oscillation? pulse,
}) => kShaft.copyWith(
  x: a.$1,
  y: a.$2,
  angle: math.atan2(b.$2 - a.$2, (b.$1 - a.$1) * aspect),
  spread: spread ?? 0.08,
  width: width ?? 0.03,
  length: 1.3,
  softness: 0.55,
  intensity: intensity ?? 1,
  streaks: 0.4,
  streakFreq: 6,
  core: core ?? 0.6,
  noSway: sway == null,
  sway: sway,
  pulse: pulse,
);

LightRig _stageRig(
  List<BeamSpec> beams, [
  GlareSpec? glare,
  FogSpec fog = _haze,
]) => LightRig(beams: beams, fog: fog, glare: glare);

/// 每盏灯的灯头线稿 + 闪点。
ArtBuilder _lampsArt(RigBuilder build) => (RigContext c) {
  final List<BeamSpec> beams = build(c).beams;
  return mergeArt(<LineArtSpec>[
    for (int i = 0; i < beams.length; i++)
      lampHead(
        beams[i].x * c.aspect,
        beams[i].y,
        beams[i].angle,
        0.035,
        delay: i * 0.05,
      ),
    scatteredSparks(aspect: c.aspect, count: 10, random: c.random, delay: 0.3),
  ]);
};

const (double, double) _center = (0.5, 0.56);

LumiereProfile _lampProfile({
  required String kind,
  required String label,
  required LumiereMood mood,
  required RigBuilder build,
  required WindowTypography typography,
  required DecaySpec decay,
  TextRegion? region,
  BurstSpec? burst,
}) => _stage(
  kind: kind,
  label: label,
  mood: mood,
  light: build,
  lineArt: _lampsArt(build),
  region: region,
  typography: typography,
  decay: decay,
  burst: burst,
);

final List<LumiereProfile> stageProfiles = <LumiereProfile>[
  _lampProfile(
    kind: 'stage-spot',
    label: '独光',
    mood: _n,
    build: (RigContext c) => _stageRig(
      <BeamSpec>[
        _lamp(
          c.aspect,
          (0.14, 0.02),
          _center,
          sway: const Oscillation(0.02, 12, 0),
        ),
      ],
      const GlareSpec(
        x: 0.14,
        y: 0.02,
        radius: 0.08,
        intensity: 0.9,
        streak: 0.5,
      ),
    ),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _lampProfile(
    kind: 'stage-cross',
    label: '交叉',
    mood: _l,
    build: (RigContext c) => _stageRig(
      <BeamSpec>[
        _lamp(
          c.aspect,
          (0.06, 0.02),
          _center,
          sway: const Oscillation(0.03, 9, 0),
        ),
        _lamp(
          c.aspect,
          (0.94, 0.02),
          _center,
          sway: const Oscillation(0.03, 9, 0.5),
        ),
      ],
      const GlareSpec(
        x: 0.5,
        y: 0.56,
        radius: 0.06,
        intensity: 0.6,
        streak: 0.6,
      ),
    ),
    typography: _x,
    burst: const BurstSpec(BurstMode.sung, 0.3, 2, 1, 3.4, Rgb(1, 0.75, 0.5)),
    decay: const DecaySpec(1.3, 0.7),
  ),
  _lampProfile(
    kind: 'stage-search',
    label: '探照',
    mood: _l,
    build: (RigContext _) => _stageRig(<BeamSpec>[
      for (int i = 0; i < 4; i++)
        kShaft.copyWith(
          x: const <double>[0.15, 0.38, 0.62, 0.85][i],
          y: 1.02,
          angle: -math.pi / 2,
          spread: 0.035,
          width: 0.03,
          length: 1.4,
          softness: 0.5,
          intensity: 0.8,
          streaks: 0.3,
          streakFreq: 5,
          core: 0.6,
          sway: Oscillation(0.45, 7 + i * 1.3, i * 0.27),
        ),
    ]),
    region: const TextRegion(0.5, 0.44, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1.3, 0.7),
  ),
  _lampProfile(
    kind: 'stage-footlight',
    label: '脚光',
    mood: _q,
    build: (RigContext _) => _stageRig(
      <BeamSpec>[
        for (final double x in <double>[0.25, 0.5, 0.75])
          kShaft.copyWith(
            x: x,
            y: 1.03,
            angle: -math.pi / 2,
            spread: 0.22,
            width: 0.08,
            length: 0.7,
            softness: 0.9,
            intensity: 0.6,
            streaks: 0.4,
            streakFreq: 10,
            core: 0.3,
            tint: const Rgb(1, 0.8, 0.6),
            noSway: true,
          ),
      ],
      null,
      _haze.copyWith(driftY: -0.03),
    ),
    region: const TextRegion(0.5, 0.46, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _stage(
    kind: 'stage-backlight',
    label: '逆光',
    mood: _n,
    light: (RigContext _) => _stageRig(
      <BeamSpec>[
        for (int k = 0; k < 6; k++)
          kShaft.copyWith(
            x: 0.5,
            y: 0.5,
            angle: k / 6 * kTau + 0.5,
            spread: 0.12,
            width: 0.02,
            length: 0.8,
            softness: 0.7,
            intensity: 0.6,
            streaks: 0.6,
            streakFreq: 10,
            core: 0.4,
            sway: Oscillation(0.05, 11, k / 6),
          ),
      ],
      const GlareSpec(
        x: 0.5,
        y: 0.5,
        radius: 0.22,
        intensity: 1.2,
        streak: 0.8,
      ),
    ),
    lineArt: _sparks(18),
    region: const TextRegion(0.5, 0.5, 0.72, 0.5),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _lampProfile(
    kind: 'stage-pinspot',
    label: '针光',
    mood: _q,
    build: (RigContext c) => _stageRig(
      <BeamSpec>[
        _lamp(
          c.aspect,
          (0.5, 0.02),
          _center,
          spread: 0.03,
          width: 0.01,
          intensity: 0.9,
          core: 0.9,
        ),
      ],
      null,
      _haze.copyWith(ambient: 0.015),
    ),
    typography: _h,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _lampProfile(
    kind: 'stage-strobe',
    label: '频闪',
    mood: _l,
    build: (RigContext c) => _stageRig(
      <BeamSpec>[
        for (int i = 0; i < 4; i++)
          _lamp(
            c.aspect,
            (const <double>[0.1, 0.36, 0.64, 0.9][i], 0.02),
            (0.5, 0.6),
            spread: 0.08,
            intensity: 0.55,
            pulse: Oscillation(0.95, 0.5, i * 0.25),
          ),
      ],
      const GlareSpec(
        x: 0.5,
        y: 0.02,
        radius: 0.2,
        intensity: 0.6,
        streak: 0.4,
      ),
    ),
    typography: _x,
    burst: const BurstSpec(BurstMode.sweep, 0.5, 2, 0, 3, Rgb(1, 0.9, 0.8)),
    decay: const DecaySpec(1.4, 0.6),
  ),
  _stage(
    kind: 'stage-curtain',
    label: '幕缝',
    mood: _q,
    light: (RigContext _) => _stageRig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.01,
          width: 0.04,
          length: 1.6,
          softness: 0.5,
          intensity: 0.9,
          streaks: 0.3,
          core: 0.7,
          noSway: true,
        ),
      ],
      const GlareSpec(
        x: 0.5,
        y: -0.02,
        radius: 0.08,
        intensity: 0.8,
        streak: 0.5,
      ),
      _haze.copyWith(ambient: 0.02),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      curtains(c.aspect, 0.06),
      scatteredSparks(
        aspect: c.aspect,
        count: 8,
        random: c.random,
        delay: 0.3,
        region: (0.3, 0.2, 0.7, 0.9),
      ),
    ]),
    region: const TextRegion(0.5, 0.5, 0.3, 0.66),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _lampProfile(
    kind: 'stage-laser',
    label: '激光',
    mood: _l,
    build: (RigContext _) => _stageRig(
      <BeamSpec>[
        for (int k = 0; k < 6; k++)
          kShaft.copyWith(
            x: 0.5,
            y: 1.02,
            angle: -math.pi / 2 + (k - 2.5) * 0.22,
            spread: 0.002,
            width: 0.004,
            length: 2,
            softness: 0.3,
            intensity: 1.2,
            streaks: 0,
            core: 0.9,
            sway: Oscillation(0.25, 4.5, k * 0.08),
          ),
      ],
      const GlareSpec(x: 0.5, y: 1, radius: 0.06, intensity: 1, streak: 0.6),
      _haze.copyWith(density: 1.4),
    ),
    region: const TextRegion(0.5, 0.4, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1.3, 0.7),
  ),
  _stage(
    kind: 'stage-projector',
    label: '放映',
    mood: _n,
    light: (RigContext _) => _stageRig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.12,
          y: 0.4,
          angle: 0.05,
          spread: 0.2,
          width: 0.02,
          length: 1.8,
          softness: 0.4,
          intensity: 1,
          streaks: 0.5,
          streakFreq: 9,
          core: 0.4,
          noSway: true,
          pulse: const Oscillation(0.05, 0.12, 0),
        ),
      ],
      const GlareSpec(x: 0.12, y: 0.4, radius: 0.05, intensity: 1, streak: 0.4),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      projector(c.aspect * 0.12, 0.4, 0.1),
      _sparks(10)(c),
    ]),
    motes: kMotes.copyWith(count: 380, driftX: 0.004, swirl: 0.03, gain: 1.8),
    region: const TextRegion(0.62, 0.5, 0.44, 0.58),
    typography: _v,
    decay: const DecaySpec(1, 1),
  ),
];

// ---------------------------------------------------------------------------
// 萤尘
// ---------------------------------------------------------------------------

final LumiereFamily _motes = LumiereFamily(
  'motes',
  starfall: kStarfall.copyWith(rain: 30),
  lineArt: _sparks(10),
);

final List<LumiereProfile> motesProfiles = <LumiereProfile>[
  _motes(
    kind: 'motes-dust',
    label: '浮尘',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.15,
          y: -0.05,
          angle: 1.05,
          spread: 0.1,
          width: 0.1,
          length: 1.5,
          intensity: 0.8,
          streaks: 0.4,
        ),
      ],
      fog: kFog.copyWith(density: 0.8, ambient: 0.015),
      glare: null,
    ),
    motes: kMotes.copyWith(
      count: 420,
      sizeMin: 0.003,
      sizeMax: 0.012,
      driftX: 0.002,
      driftY: -0.004,
      swirl: 0.035,
      swirlPeriod: 14,
      gain: 1.6,
    ),
    typography: _h,
    decay: const DecaySpec(0.7, 1.4),
  ),
  _motes(
    kind: 'motes-firefly',
    label: '萤火',
    mood: _q,
    light: rig(
      <BeamSpec>[kShaft.copyWith(spread: 0.05, intensity: 0.15)],
      fog: kFog.copyWith(density: 0.6, ambient: 0.02),
      glare: null,
    ),
    motes: kMotes.copyWith(
      count: 90,
      sizeMin: 0.008,
      sizeMax: 0.022,
      driftX: 0.003,
      driftY: -0.003,
      swirl: 0.06,
      swirlPeriod: 11,
      twinkle: 0.9,
      ambient: 0.55,
      gain: 0.8,
    ),
    front: kFront.copyWith(count: 14, ambient: 0.12, twinkle: 0.7),
    region: const TextRegion(0.5, 0.5, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _motes(
    kind: 'motes-smoke',
    label: '烟缕',
    mood: _n,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: -0.05,
          y: 0.55,
          angle: -0.08,
          spread: 0.18,
          width: 0.3,
          length: 1.6,
          softness: 0.7,
          intensity: 0.42,
          streaks: 0.2,
          core: 0.3,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(
        density: 1.5,
        tyndallBase: 0.05,
        scale: 1.8,
        warp: 1.8,
        driftX: 0.004,
        driftY: -0.06,
        ambient: 0.05,
      ),
      glare: null,
    ),
    motes: kMotes.copyWith(count: 140),
    typography: _x,
    decay: const DecaySpec(1, 1),
  ),
  _motes(
    kind: 'motes-embers',
    label: '飞烬',
    mood: _l,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.5,
          y: 1.05,
          angle: -math.pi / 2,
          spread: 0.35,
          width: 0.3,
          length: 0.6,
          softness: 0.9,
          intensity: 0.8,
          streaks: 0.6,
          streakFreq: 8,
          core: 0.3,
          tint: const Rgb(1, 0.55, 0.3),
          pulse: const Oscillation(0.2, 1.3, 0),
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(density: 1.1, driftY: -0.05),
      glare: null,
    ),
    motes: kMotes.copyWith(
      count: 380,
      sizeMin: 0.003,
      sizeMax: 0.01,
      driftX: 0.004,
      driftY: -0.07,
      swirl: 0.03,
      swirlPeriod: 5,
      twinkle: 0.8,
      ambient: 0.1,
      gain: 1.8,
    ),
    region: const TextRegion(0.5, 0.44, 0.72, 0.46),
    typography: _h,
    decay: const DecaySpec(1.4, 0.6),
  ),
  _motes(
    kind: 'motes-snow',
    label: '光雪',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          spread: 0.2,
          width: 0.2,
          softness: 0.9,
          intensity: 0.5,
          core: 0.3,
        ),
      ],
      fog: kFog.copyWith(density: 0.8, driftY: 0.01),
      glare: null,
    ),
    motes: kMotes.copyWith(
      count: 460,
      sizeMin: 0.003,
      sizeMax: 0.012,
      driftX: 0.003,
      driftY: 0.035,
      swirl: 0.02,
      swirlPeriod: 8,
      twinkle: 0.3,
      ambient: 0.15,
      gain: 1,
    ),
    region: const TextRegion(0.5, 0.5, 0.5, 0.62),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
    starfall: kStarfall.copyWith(
      rain: 60,
      rainSpeed: 0.12,
      rainSpread: 1.8,
      brightness: 0.7,
    ),
  ),
  _motes(
    kind: 'motes-bokeh',
    label: '散景',
    mood: _n,
    light: rig(
      <BeamSpec>[kShaft.copyWith(intensity: 0.6)],
      fog: kFog.copyWith(density: 0.8),
      glare: null,
    ),
    motes: kMotes.copyWith(count: 120),
    front: kFront.copyWith(
      count: 34,
      sizeMin: 0.06,
      sizeMax: 0.2,
      ambient: 0.1,
      gain: 0.5,
      twinkle: 0.3,
      driftX: 0.008,
    ),
    typography: _h,
    decay: const DecaySpec(1, 1),
  ),
  _motes(
    kind: 'motes-mist',
    label: '晨雾',
    mood: _q,
    light: rig(
      <BeamSpec>[
        kShaft.copyWith(
          x: 0.7,
          y: 0.62,
          angle: -2.8,
          spread: 0.5,
          width: 0.3,
          length: 1.2,
          softness: 1,
          intensity: 0.55,
          streaks: 0.3,
          core: 0.2,
          noSway: true,
        ),
      ],
      fog: kFog.copyWith(
        density: 1.5,
        tyndallBase: 0.1,
        scale: 1.2,
        warp: 0.6,
        driftX: 0.02,
        driftY: 0,
        ambient: 0.05,
      ),
      glare: const GlareSpec(
        x: 0.7,
        y: 0.62,
        radius: 0.16,
        intensity: 0.5,
        streak: 0.08,
      ),
    ),
    lineArt: (RigContext c) => mergeArt(<LineArtSpec>[
      horizon(c.aspect, 0.64),
      scatteredSparks(
        aspect: c.aspect,
        count: 8,
        random: c.random,
        delay: 0.3,
        region: (0.05, 0.05, 0.95, 0.55),
      ),
    ]),
    motes: kMotes.copyWith(count: 120, driftX: 0.01),
    region: const TextRegion(0.36, 0.42, 0.44, 0.5),
    typography: _v,
    decay: const DecaySpec(0.6, 1.6),
  ),
  _motes(
    kind: 'motes-swarm',
    label: '光群',
    mood: _l,
    light: rig(<BeamSpec>[
      kShaft.copyWith(intensity: 0.8),
      kShaft.copyWith(
        spread: 0.3,
        length: 0.6,
        softness: 0.9,
        intensity: 0.25,
        streaks: 0.8,
        streakFreq: 24,
      ),
    ]),
    motes: kMotes.copyWith(
      count: 460,
      sizeMin: 0.003,
      sizeMax: 0.012,
      driftX: 0,
      driftY: 0,
      swirl: 0.14,
      swirlPeriod: 6,
      twinkle: 0.6,
      ambient: 0.08,
      gain: 1.6,
    ),
    typography: _x,
    decay: const DecaySpec(1.3, 0.7),
  ),
  _motes(
    kind: 'motes-dissolve',
    label: '化尘',
    mood: _n,
    light: rig(<BeamSpec>[kShaft.copyWith(intensity: 0.7)]),
    motes: kMotes.copyWith(count: 380, driftY: -0.02, swirl: 0.04, gain: 1.5),
    typography: _x,
    decay: const DecaySpec(2.2, 0.3),
  ),
  _motes(
    kind: 'motes-aurora',
    label: '极光',
    mood: _l,
    light: rig(
      <BeamSpec>[
        for (int i = 0; i < 4; i++)
          kShaft.copyWith(
            x: const <double>[0.2, 0.4, 0.6, 0.8][i],
            y: -0.1,
            angle: math.pi / 2 + 0.1,
            spread: 0.06,
            width: 0.16,
            length: 0.7,
            softness: 0.8,
            intensity: 0.7,
            streaks: 0.9,
            streakFreq: 30,
            streakSpeed: 0.3,
            core: 0.2,
            spectrum: 0.5,
            tint: const Rgb(0.6, 1, 0.8),
            sway: Oscillation(0.12, 8 + i * 1.7, i * 0.2),
          ),
      ],
      fog: kFog.copyWith(density: 0.9, ambient: 0.03),
      glare: null,
    ),
    region: const TextRegion(0.5, 0.62, 0.72, 0.4),
    typography: _h,
    decay: const DecaySpec(1.2, 0.8),
    starfall: kStarfall.copyWith(stars: 560, rain: 20),
  ),
];
