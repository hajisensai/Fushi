import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_scene.dart';

/// folia `catalog.ts` 的 50 个镜头配方逐字段指纹（由 folia 源码 `HANABI_PROFILES` 直接导出，kebab 名转驼峰）。
const List<String> _foliaCatalog = <String>[
  'uchiageKiku|uchiage|neutral|kawaii|above|true|center,band,rise,bounce,ascend,0.1,0.45,0,0.045,false,true|0.5,0.5,0.74,0.34|kiku,96,0.3,1.9,0.1.2,0.65,0.2|-|0.72,0.04,0.01,0.35|streaks,screen,back,0.5,1,spark,-0.3;sparkle,glyphs,front,0.5,1,glow,0;ring,behind,back,0.6,1.1,spark,0.05',
  'uchiageBotan|uchiage|loud|festival|above|true|stagger,pill,rise,jump,ascend,0.1,0.45,0,0.045,false,true|0.5,0.5,0.7,0.46|botan,96,0.26,1.4,0.1.2.3,0.1,0.1|botan,14,0.05,0.8,0.1.2,0.1,0.1|0.8,0.04,0.01,0.5|chevrons,lineEnd,back,0.7,1,block,0;confetti,screen,front,0.55,1,spark,0.1;dotsLine,glyphs,back,0.6,1,paper,0',
  'uchiagePalm|uchiage|neutral|ocean|sides|true|left,slant,elastic,swell,ascend,0.1,0.45,-0.05,0.045,false,true|0.42,0.56,0.6,0.34|palm,36,0.32,2.3,0.1,0.8,0.1|-|0.72,0.04,0.01,0.35|streaks,lineStart,back,0.45,1,spark,0;underline,glyphs,back,0.6,1.1,block,0;cross,around,front,0.4,0.8,paper,0',
  'uchiageCrossette|uchiage|neutral|night|above|true|arc,none,wave,flash,ascend,0.095,0.45,0,0.045,true,false|0.5,0.54,0.74,0.4|crossette,40,0.26,1.9,0.2.3,0.4,0.2|-|0.72,0.04,0.01,0.35|dashCircle,behind,back,0.6,1.2,glow,-0.1;sparkle,glyphs,front,0.7,1,spark,0;streaks,screen,back,0.35,1,paper,-0.4',
  'uchiageDouble|uchiage|neutral|gold|behind|true|center,double,drop,bounce,scatter,0.1,0.45,0,0.045,false,true|0.5,0.5,0.74,0.34|willowRing,100,0.34,2.8,0.1.2,0.7,0.3|-|0.65,0.04,0.01,0.35|rays,behind,back,0.5,1.2,glow,0.05;glints,glyphs,front,0.6,1,paper,0;chevrons,lineStart,back,0.5,1,accent,0',
  'kikuCenter|kiku|loud|night|behind|true|center,none,zoom,glow,shrink,0.13,0.35,0,0.035,true,false|0.5,0.5,0.74,0.34|kiku,120,0.36,1.9,0.1.2.3,0.65,0.2|-|0.55,0.07,0,0.5|spokes,behind,back,0.8,1.3,paper,0.05;ring,behind,back,0.7,1.4,spark,0.1;glints,glyphs,front,0.5,1,glow,0',
  'kikuRing|kiku|loud|neon|behind|true|center,outline,burst,flash,dissolve,0.13,0.35,0,0.035,true,false|0.5,0.5,0.74,0.34|ring,72,0.26,1.4,0.1.2,0.3,0.1|-|0.55,0.07,0,0.65|ring,around,back,0.9,1.2,accent,0;dashCircle,behind,back,0.6,1.5,glow,-0.15;sparkle,glyphs,front,0.6,1,spark,0',
  'kikuSpokes|kiku|neutral|festival|behind|true|center,circle,pop,bounce,scatter,0.11,0.35,0,0.035,false,true|0.5,0.5,0.74,0.34|kiku,96,0.3,1.9,1.2.0,0.65,0.2|-|0.55,0.07,0,0.5|spokes,around,back,0.9,1.1,block,0;shards,around,front,0.45,1,spark,0.1;ring,behind,back,0.5,1,paper,0.15',
  'kikuHalo|kiku|neutral|gold|above|true|arc,tile,spiral,swell,ascend,0.1,0.35,0,0.035,false,false|0.5,0.54,0.74,0.4|kamuro,110,0.32,3.6,0.1,0.95,0.55|-|0.55,0.05,0.012,0.5|dashCircle,behind,back,0.6,1.3,accent,0;orbit,around,front,0.6,1,glow,0;glints,glyphs,front,0.4,1,paper,0',
  'kikuMarker|kiku|neutral|ocean|sky|true|right,marker,wipe,underline,slide,0.1,0.35,0,0.05,false,false|0.58,0.46,0.6,0.34|kiku,96,0.3,1.9,0.2,0.65,0.2|-|0.55,0.03,0,0.25|ring,lineStart,back,0.5,1,spark,0;spokes,corners,back,0.5,0.8,paper,0;dotsLine,glyphs,front,0.6,1,accent,0',
  'botanBand|botan|loud|festival|behind|false|center,band,stamp,jump,shrink,0.12,0.6,0,0.05,false,true|0.5,0.5,0.74,0.34|botan,110,0.26,1.4,0.1.2.3,0.1,0.1|-|0.5,0.05,0,0.8|halftone,behind,back,0.7,1.3,block,0;confetti,screen,front,0.6,1,spark,0.05;squares,around,back,0.5,1,accent,0',
  'botanTile|botan|neutral|pastel|behind|false|stagger,tile,pop,color,scatter,0.11,0.6,0,0.05,false,true|0.5,0.5,0.7,0.46|botan,84,0.26,1.4,1.2.3,0.1,0.1|botan,10,0.05,0.8,0.1.2.3,0.1,0.1|0.5,0.05,0,0.4|squares,corners,back,0.6,1,block,0;confetti,screen,front,0.4,1,spark,0;cross,around,front,0.5,0.8,accent,0',
  'botanDouble|botan|loud|sakura|sides|false|left,double,stamp,bounce,blink,0.11,0.6,-0.04,0.05,false,true|0.42,0.56,0.6,0.34|heart,60,0.2,1.6,0.2,0.2,0.2|-|0.5,0.05,0,0.6|halftone,behind,back,0.6,1,accent,0;stamp,lineEnd,front,0.6,1.1,accent,0.3;sparkle,glyphs,front,0.5,1,paper,0',
  'botanSplit|botan|loud|neon|above|false|diagonal,split,flip,jump,slide,0.11,0.6,-0.12,0.05,false,true|0.5,0.5,0.74,0.5|botan,84,0.26,1.4,0.1,0.1,0.1|-|0.5,0.05,0.02,0.6|shards,around,front,0.55,1,spark,0;chevrons,lineEnd,back,0.7,1,block,0;zigzag,around,back,0.6,1,accent,0',
  'botanCircle|botan|neutral|pastel|sky|false|scatter,circle,pop,bounce,shrink,0.09,0.8,0,0.05,false,true|0.5,0.5,0.78,0.56|star,55,0.2,1.6,0.1.3,0.2,0.3|-|0.5,0.05,0,0.35|cross,screen,back,0.5,1,paper,0;confetti,around,front,0.5,1,block,0;orbit,around,back,0.5,1,accent,0',
  'yanagiShidare|yanagi|quiet|night|above|true|vertical,none,drop,glow,fall,0.085,0.2,0,0.09,false,false|0.5,0.5,0.34,0.72|yanagi,64,0.3,3.2,0.1,0.9,0.3|-|0.35,0.025,0.006,0|petals,screen,front,0.3,1,glow,0.4;dotsLine,glyphs,back,0.5,0.8,spark,0;glints,glyphs,front,0.35,1,paper,0',
  'yanagiKamuro|yanagi|quiet|gold|above|true|verticalSplit,outline,wipe,glow,fall,0.085,0.2,0,0.09,false,false|0.5,0.5,0.46,0.72|kamuro,110,0.36,4,0.1.2,0.95,0.55|-|0.35,0.025,0.006,0|brackets,around,back,0.6,1.05,accent,0.1;glints,glyphs,front,0.4,1,glow,0;wave,behind,back,0.35,1,spark,0',
  'yanagiAme|yanagi|quiet|ocean|above|true|vertical,marker,wave,underline,fall,0.085,0.2,0,0.09,false,false|0.62,0.5,0.3,0.72|willowRing,80,0.34,2.8,0.2,0.7,0.3|-|0.35,0.025,0.006,0|wave,screen,back,0.4,1,accent,0;streaks,screen,back,0.3,0.8,paper,0;dotsLine,lineEnd,front,0.5,1,spark,0',
  'yanagiKaze|yanagi|quiet|sakura|sky|true|right,none,drop,swell,fall,0.08,0.2,0,0.07,false,false|0.58,0.46,0.6,0.34|yanagi,64,0.3,3.2,0.1.3,0.9,0.3|-|0.35,0.025,0.006,0|petals,screen,front,0.5,1,block,0;sparkle,glyphs,front,0.35,1,glow,0;wave,lineStart,back,0.4,1,accent,0',
  'yanagiPalm|yanagi|quiet|kawaii|sides|true|verticalSplit,pill,rise,color,dissolve,0.085,0.2,0,0.09,false,false|0.5,0.5,0.46,0.72|palm,36,0.32,2.8,0.2,0.8,0.1|-|0.35,0.025,0.006,0|brackets,around,back,0.6,1,paper,0.1;petals,screen,front,0.25,1,spark,0;dashCircle,behind,back,0.6,1.3,glow,0',
  'senrinScatter|senrin|loud|festival|behind|false|scatter,pill,pop,jump,scatter,0.09,0.7,0,0.03,false,true|0.5,0.5,0.78,0.56|senrin,72,0.22,1.7,0.1.2.3,0.3,0.45|senrin,16,0.06,0.8,0.1.2.3,0.3,0.45|0.45,0.04,0.012,0.4|confetti,screen,front,0.6,1,spark,0;cross,around,back,0.6,1,accent,0;sparkle,glyphs,front,0.5,1,paper,0',
  'senrinStagger|senrin|neutral|neon|behind|false|stagger,tile,burst,bounce,shrink,0.09,0.7,0,0.03,false,true|0.5,0.5,0.7,0.46|senrin,72,0.22,1.7,1.2.3,0.3,0.45|senrin,16,0.06,0.8,0.1.2.3,0.3,0.45|0.45,0.04,0.012,0.4|squares,around,back,0.5,1,block,0;shards,around,front,0.45,1,spark,0;sparkle,glyphs,front,0.4,1,glow,0',
  'senrinStrobe|senrin|neutral|pastel|sky|false|scatter,circle,spin,flash,blink,0.09,0.7,0,0.03,false,true|0.5,0.5,0.78,0.56|strobe,72,0.28,2.3,0.1.2.3,0.15,1|strobe,14,0.05,0.8,0.1.2.3,0.15,1|0.45,0.04,0.012,0.4|cross,screen,back,0.5,1,paper,0;orbit,around,front,0.5,1,spark,0;dotsLine,glyphs,back,0.5,1,accent,0',
  'senrinHachi|senrin|loud|festival|behind|false|diagonal,stair,spin,shake,scatter,0.09,0.7,-0.1,0.03,false,true|0.5,0.5,0.74,0.5|hachi,50,0.24,1.6,0.1.2,0.6,0.5|hachi,12,0.05,0.8,0.1.2,0.6,0.5|0.45,0.04,0.02,0.55|zigzag,around,back,0.7,1,block,0;confetti,screen,front,0.5,1,spark,0;chevrons,lineEnd,front,0.5,1,paper,0',
  'senrinHeart|senrin|neutral|sakura|above|false|arc,pill,pop,bounce,shrink,0.09,0.7,0,0.03,false,true|0.5,0.54,0.74,0.4|heart,60,0.2,1.6,0.1,0.2,0.2|heart,12,0.05,0.8,0.2,0.2,0.2|0.45,0.04,0.012,0.4|petals,screen,front,0.45,1,block,0;confetti,around,front,0.35,1,spark,0;sparkle,glyphs,front,0.4,1,paper,0',
  'hoshikuzuStar|hoshikuzu|quiet|night|above|false|center,none,spiral,glow,dissolve,0.085,0.3,0,0.07,false,false|0.5,0.5,0.74,0.34|star,55,0.2,1.6,0.2,0.2,0.3|star,10,0.04,1,0.1.2,0.2,0.3|0.4,0.03,0.008,0|sparkle,glyphs,front,0.7,1,glow,0;glints,glyphs,front,0.5,1,paper,0;orbit,around,back,0.4,1.2,spark,0',
  'hoshikuzuOrbit|hoshikuzu|quiet|ocean|sky|false|arc,outline,zoom,glow,dissolve,0.085,0.3,0,0.07,false,false|0.5,0.54,0.74,0.4|strobe,56,0.28,2.3,0.1.2,0.15,1|star,10,0.04,1,0.1.2,0.2,0.3|0.4,0.03,0.008,0|orbit,around,front,0.7,1,glow,0;dashCircle,behind,back,0.6,1.4,accent,0;sparkle,around,front,0.4,1,paper,0',
  'hoshikuzuDust|hoshikuzu|quiet|pastel|behind|false|vertical,circle,wave,glow,dissolve,0.085,0.3,0,0.07,false,false|0.5,0.5,0.34,0.72|ring,48,0.2,1.4,0.1,0.3,0.1|star,10,0.04,1,0.1.2,0.2,0.3|0.4,0.03,0.008,0|dotsLine,glyphs,back,0.6,1,spark,0;sparkle,screen,front,0.45,1,glow,0;petals,screen,front,0.2,0.7,paper,0',
  'hoshikuzuLine|hoshikuzu|quiet|neon|sky|false|left,pill,zoom,none,dissolve,0.085,0.3,0,0.07,false,false|0.42,0.56,0.6,0.34|crossette,40,0.26,1.9,0.1,0.4,0.2|star,10,0.04,1,0.1.2,0.2,0.3|0.4,0.03,0.008,0|dotsLine,lineEnd,back,0.7,1,accent,0;glints,glyphs,front,0.5,1,glow,0;cross,corners,back,0.4,1,paper,0',
  'hoshikuzuVeil|hoshikuzu|quiet|sakura|sky|false|stagger,none,spiral,color,ascend,0.085,0.3,0,0.07,false,false|0.5,0.5,0.7,0.46|kamuro,90,0.36,3.6,0.1.3,0.95,0.55|star,10,0.04,1,0.1.2,0.2,0.3|0.4,0.03,0.008,0|sparkle,glyphs,front,0.6,1,glow,0;wave,behind,back,0.4,1,accent,0;orbit,around,back,0.35,1,spark,0',
  'obiBand|obi|neutral|festival|sides|false|left,band,wipe,underline,slide,0.09,0.4,0,0.04,false,false|0.42,0.56,0.6,0.34|ring,60,0.26,1.4,0.1,0.3,0.1|-|0.5,0.02,0,0.2|zigzag,lineEnd,back,0.6,1,block,0;chevrons,lineStart,back,0.5,1,accent,0;underline,glyphs,front,0.6,1,paper,0',
  'obiTicket|obi|neutral|pastel|above|false|center,ticket,flip,color,slide,0.09,0.4,0,0.04,false,false|0.5,0.5,0.74,0.34|botan,64,0.26,1.4,0.2,0.1,0.1|-|0.5,0.02,0,0.2|brackets,around,back,0.6,1,accent,0;dotsLine,lineEnd,back,0.5,1,paper,0;stamp,lineStart,front,0.6,0.9,accent,0.35',
  'obiSlant|obi|loud|neon|sides|false|diagonal,slant,wipe,underline,slide,0.09,0.4,-0.14,0.04,false,true|0.5,0.5,0.74,0.5|palm,36,0.32,2.3,0.1.2,0.8,0.1|-|0.5,0.02,0,0.45|chevrons,lineEnd,front,0.7,1,spark,0;streaks,screen,back,0.5,1,paper,0;zigzag,around,back,0.5,1,block,0',
  'obiMarker|obi|neutral|ocean|sky|false|stagger,marker,type,underline,blink,0.09,0.4,0,0.04,false,false|0.5,0.5,0.7,0.46|star,55,0.2,1.6,0.1,0.2,0.3|-|0.5,0.02,0,0.2|underline,glyphs,back,0.6,1.2,accent,0;squares,corners,back,0.5,1,block,0;brackets,around,front,0.6,1.1,paper,0',
  'obiStair|obi|neutral|gold|sides|false|right,stair,stretch,jump,slide,0.09,0.4,0,0.04,false,true|0.58,0.46,0.6,0.34|crossette,40,0.26,1.9,0.1.3,0.4,0.2|-|0.5,0.02,0,0.2|squares,around,back,0.55,1,accent,0;halftone,behind,back,0.5,1,block,0;chevrons,lineStart,front,0.5,1,paper,0',
  'senkoGlitch|senko|loud|neon|behind|false|center,split,glitch,shake,blink,0.1,0.5,0,0.025,false,true|0.5,0.5,0.74,0.34|strobe,72,0.28,2.3,0.1.2.3,0.15,1|-|0.6,0.06,0.015,0.7|streaks,screen,back,0.7,1,spark,0;shards,around,front,0.5,1,block,0;squares,around,back,0.5,1,paper,0',
  'senkoScramble|senko|neutral|mono|sides|false|left,outline,scramble,flash,blink,0.1,0.5,0,0.025,true,false|0.42,0.56,0.6,0.34|hachi,50,0.24,1.6,0.1,0.6,0.5|-|0.6,0.06,0.015,0.4|brackets,around,back,0.6,1,paper,0;cross,corners,front,0.5,1,accent,0;streaks,lineEnd,back,0.5,1,glow,0',
  'senkoStrobe|senko|loud|kawaii|sky|false|scatter,tile,glitch,flash,scatter,0.1,0.5,0,0.025,false,true|0.5,0.5,0.78,0.56|mine,84,0.5,1.8,0.1.2,0.7,0.3|strobe,10,0.05,0.8,0.1,0.15,1|0.6,0.06,0.015,0.7|streaks,screen,back,0.8,1,paper,0;zigzag,around,front,0.5,1,accent,0;glints,glyphs,front,0.5,1,glow,0',
  'senkoStretch|senko|loud|neon|behind|false|center,slant,stretch,shake,shrink,0.1,0.5,-0.06,0.025,false,true|0.5,0.5,0.74,0.34|crossette,40,0.26,1.9,0.2.3,0.4,0.2|-|0.6,0.06,0.015,0.7|spokes,around,back,0.8,1,paper,0;streaks,screen,front,0.5,1,spark,0;shards,around,back,0.4,1,block,0',
  'senkoType|senko|neutral|mono|above|false|right,ticket,scramble,none,blink,0.1,0.5,0,0.025,false,true|0.58,0.46,0.6,0.34|ring,48,0.26,1.4,0.1,0.3,0.1|-|0.6,0.06,0,0.3|dotsLine,lineStart,back,0.6,1,paper,0;brackets,around,front,0.6,1.08,accent,0;cross,screen,back,0.35,1,glow,0',
  'senkohanabiHachi|senkohanabi|quiet|gold|behind|false|vertical,none,type,glow,fall,0.08,0.2,0,0.08,false,false|0.62,0.5,0.3,0.72|hachi,36,0.14,1.6,0.1,0.6,0.5|hachi,12,0.035,0.6,0.1,0.4,0.8|0.3,0.02,0.004,0|glints,glyphs,front,0.6,1,spark,0;sparkle,glyphs,front,0.35,0.7,glow,0;dotsLine,glyphs,back,0.4,0.7,accent,0',
  'senkohanabiTama|senkohanabi|quiet|night|above|false|center,none,split,glow,dissolve,0.085,0.2,0,0.08,false,false|0.5,0.5,0.74,0.34|botan,40,0.12,1.2,0.1,0.1,0.1|hachi,12,0.035,0.6,0.1,0.4,0.8|0.3,0.02,0.004,0|glints,glyphs,front,0.5,1,spark,0;sparkle,around,front,0.3,0.7,glow,0',
  'senkohanabiMatsuba|senkohanabi|quiet|gold|sides|false|left,circle,elastic,swell,dissolve,0.08,0.2,0,0.08,false,false|0.42,0.56,0.6,0.34|crossette,28,0.15,1.9,0.1,0.4,0.2|hachi,12,0.035,0.6,0.1,0.4,0.8|0.3,0.02,0.004,0|sparkle,glyphs,front,0.45,1,spark,0;cross,around,back,0.35,0.7,glow,0',
  'senkohanabiChiri|senkohanabi|quiet|sakura|above|false|arc,marker,flip,underline,fall,0.08,0.2,0,0.08,false,false|0.5,0.54,0.74,0.4|yanagi,40,0.18,3.2,0.1,0.9,0.3|hachi,12,0.035,0.6,0.1,0.4,0.8|0.3,0.02,0.004,0|petals,screen,front,0.35,1,block,0;glints,glyphs,front,0.4,1,paper,0',
  'senkohanabiTsubomi|senkohanabi|quiet|kawaii|behind|false|verticalSplit,none,split,glow,fall,0.08,0.2,0,0.08,false,false|0.5,0.5,0.46,0.72|strobe,30,0.14,2.3,0.1,0.15,1|hachi,12,0.035,0.6,0.1,0.4,0.8|0.3,0.02,0.004,0|dotsLine,glyphs,back,0.5,1,spark,0;glints,glyphs,front,0.5,1,glow,0;dashCircle,behind,back,0.4,0.9,paper,0',
  'shakudamaKamuro|shakudama|loud|gold|behind|true|center,none,stamp,none,shrink,0.19,0.25,0,0.06,true,true|0.5,0.5,0.8,0.52|kamuro,160,0.48,4.2,0.1.2,0.95,0.55|-|0.85,0.09,0,0.9|rays,behind,back,0.8,1.5,glow,0;ring,behind,back,0.6,1.6,accent,0.1;spokes,around,front,0.5,1.3,paper,0',
  'shakudamaNishiki|shakudama|loud|festival|behind|true|center,double,zoom,swell,scatter,0.17,0.25,0,0.06,true,true|0.5,0.5,0.8,0.52|willowRing,150,0.46,2.8,0.1.2.3,0.7,0.3|-|0.85,0.09,0,0.9|rays,behind,back,0.6,1.4,block,0;stamp,lineEnd,front,0.6,1.2,accent,0.4;ring,around,back,0.7,1.3,spark,0',
  'shakudamaAsahi|shakudama|loud|festival|behind|true|center,circle,burst,flash,shrink,0.19,0.25,0,0.06,true,true|0.5,0.5,0.8,0.52|kamuro,140,0.44,3.6,1.0,0.95,0.55|-|0.85,0.09,0,0.9|rays,behind,back,0.9,1.6,block,0;spokes,behind,back,0.6,1.4,paper,0;confetti,screen,front,0.5,1,spark,0.2',
  'shakudamaHeart|shakudama|loud|sakura|behind|true|center,tile,stretch,jump,scatter,0.17,0.25,0,0.06,true,true|0.5,0.5,0.8,0.52|heart,110,0.36,1.6,0.1.3,0.2,0.2|-|0.85,0.09,0,0.9|stamp,lineStart,front,0.6,1.3,accent,0.3;rays,behind,back,0.5,1.3,glow,0;confetti,screen,front,0.55,1,block,0',
  'shakudamaMine|shakudama|loud|neon|sky|true|left,split,stamp,shake,scatter,0.16,0.25,-0.05,0.06,true,true|0.44,0.52,0.68,0.5|mine,120,0.5,1.8,0.1.2.3,0.7,0.3|-|0.85,0.09,0,0.9|streaks,screen,back,0.8,1,spark,0;shards,around,front,0.6,1,block,0;rays,behind,back,0.5,1.3,accent,0',
];

String _n(Object? v) {
  if (v is double) {
    return v == v.roundToDouble() && v.abs() < 1e15
        ? v.toInt().toString()
        : v.toString();
  }
  if (v is Enum) return v.name;
  return '$v';
}

String _camel(String s) =>
    s.replaceAllMapped(RegExp(r'-([a-z])'), (Match m) => m[1]!.toUpperCase());

String _burst(BurstSpec? b) => b == null
    ? '-'
    : <Object>[
        b.kind,
        b.count,
        b.radius,
        b.duration,
        b.colors.join('.'),
        b.trail,
        b.twinkle,
      ].map(_n).join(',');

String _fingerprint(HanabiProfile p) => <Object>[
  _camel(p.kind),
  p.family,
  p.mood,
  p.palette,
  p.burstAt,
  p.launch,
  <Object>[
    p.text.layout,
    p.text.block,
    p.text.enter,
    p.text.sing,
    p.text.exit,
    p.text.heroSize,
    p.text.emphasis,
    p.text.tilt,
    p.text.stagger,
    p.text.outline,
    p.text.hardShadow,
  ].map(_n).join(','),
  <Object>[p.region.cx, p.region.cy, p.region.w, p.region.h].map(_n).join(','),
  _burst(p.burst),
  _burst(p.sungBurst),
  <Object>[
    p.camera.rise,
    p.camera.push,
    p.camera.roll,
    p.camera.punch,
  ].map(_n).join(','),
  p.ornaments
      .map(
        (OrnamentSpec o) => <Object>[
          o.kind,
          o.placement,
          o.layer,
          o.density,
          o.scale,
          o.color,
          o.delay,
        ].map(_n).join(','),
      )
      .join(';'),
].map(_n).join('|');

HanabiLine _line(String text, double start, double perChar) {
  final List<String> chars = text.split('');
  return HanabiLine(
    chars: chars,
    charStart: <double>[
      for (int i = 0; i < chars.length; i++) start + i * perChar,
    ],
    charEnd: <double>[
      for (int i = 0; i < chars.length; i++) start + (i + 1) * perChar,
    ],
    startTime: start,
    endTime: start + chars.length * perChar,
  );
}

const HanabiTheme _theme = HanabiTheme(
  primary: 0x6750a4,
  accent: 0xff8a65,
  secondary: 0x4db6ac,
  background: 0x101018,
);

HanabiFrame _frame(
  double time,
  HanabiSettings settings, {
  bool motion = true,
}) => HanabiFrame(
  time: time,
  motion: motion,
  theme: _theme,
  settings: settings,
  fontScale: 1,
  baseStyle: const TextStyle(fontSize: 16),
  pulseScale: 1.02,
  pulseRotation: 0.01,
);

void _paintAt(
  HanabiScene scene,
  double time,
  HanabiSettings settings, {
  bool motion = true,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  scene.paint(
    ui.Canvas(recorder),
    const Size(800, 450),
    _frame(time, settings, motion: motion),
  );
  recorder.endRecording().dispose();
}

/// 只数顶层画布上的调用（场景层录进内层 picture，不经过这里）；其余调用照样吞掉。
class _CountingCanvas implements ui.Canvas {
  int pictures = 0;
  int images = 0;
  int filteredLayers = 0;
  final List<double> imageAlphas = <double>[];

  @override
  void drawPicture(ui.Picture picture) => pictures++;

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) {
    images++;
    imageAlphas.add(paint.color.a);
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    if (paint.imageFilter != null) filteredLayers++;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('BUG-5403 GPU 开销', () {
    HanabiScene scene0() {
      final HanabiScene scene = HanabiScene(
        program: compileHanabiProgram(
          <HanabiLine>[
            _line('夜空に咲いた花火', 2, 0.25)..isChorus = true,
            _line('君の声が聞こえる', 5, 0.25),
          ],
          'hanabi:gpu',
          duration: 30,
        ),
        title: '花火',
        artist: 'Artist',
        album: 'Album',
      );
      addTearDown(scene.dispose);
      return scene;
    }

    testWidgets('全屏辉光只把场景层画一遍：三层辉光都从同一张栅格化纹理来，不再每层重放整个场景', (
      WidgetTester tester,
    ) async {
      final HanabiScene scene = scene0();
      const HanabiSettings settings = HanabiSettings(overlayFrame: false);
      final _CountingCanvas canvas = _CountingCanvas();
      scene.paint(canvas, const Size(800, 450), _frame(3, settings));
      // 修前：drawPicture 1 + 每层辉光 saveLayer(模糊) 里各 drawPicture 一次 = 4 遍场景。
      expect(canvas.pictures, 1);
      expect(canvas.filteredLayers, 0);
      expect(canvas.images, 3);
      for (final double a in canvas.imageAlphas) {
        expect(a, greaterThan(0));
      }

      final _CountingCanvas off = _CountingCanvas();
      scene.paint(
        off,
        const Size(800, 450),
        _frame(
          3,
          const HanabiSettings(overlayFrame: false, bloom: 0, chorusBloom: 0),
        ),
      );
      expect(off.pictures, 1);
      expect(off.images, 0);
    });

    test('场景层栅格化按设备像素出图', () {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 10, 10),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = rasterizeHanabiSceneLayer(
        picture,
        const Size(100.5, 40),
        1.5,
      );
      expect(image.width, 151);
      expect(image.height, 60);
      image.dispose();
      picture.dispose();
    });

    test('片尾卡设过的烟花辉光不漏回场景层：回拖到歌词段落时场景火花不挂辉光', () {
      final HanabiScene scene = scene0();
      const HanabiSettings settings = HanabiSettings(glow: 1.5);
      _paintAt(scene, 25, settings);
      _paintAt(scene, 3, settings);
      expect(scene.sparkHalo, 0);
    });
  });

  group('花火 scene 域', () {
    test('50 个镜头配方与 folia catalog.ts 逐字段一致', () {
      expect(hanabiProfiles.length, _foliaCatalog.length);
      for (int i = 0; i < hanabiProfiles.length; i++) {
        expect(
          _fingerprint(hanabiProfiles[i]),
          _foliaCatalog[i],
          reason: hanabiProfiles[i].kind,
        );
      }
    });

    test('全屏辉光强度：整体 0.45 + 副歌 0.9 × 权重（folia HANABI_SCREEN_BLOOM）', () {
      expect(
        resolveHanabiScreenBloomStrength(0.8, 1.3, 0),
        closeTo(0.36, 1e-9),
      );
      expect(
        resolveHanabiScreenBloomStrength(0.8, 1.3, 1),
        closeTo(1.53, 1e-9),
      );
      expect(resolveHanabiScreenBloomStrength(-1, -1, 1), 0);
    });

    testWidgets('整首走一遍：间奏镜头的装饰件、片尾卡拼贴、全屏辉光、仅文字与减弱动态都不抛错', (
      WidgetTester tester,
    ) async {
      // 前奏 6 秒成间奏段；第二、三行之间留出长空隙出行间间奏镜头；最后放片尾卡。
      final HanabiProgram program = compileHanabiProgram(
        <HanabiLine>[
          _line('夜空に咲いた花火', 6, 0.25)..isChorus = true,
          _line('君の声が聞こえる', 9, 0.25)..isChorus = true,
          _line('hello summer night', 18, 0.15),
          _line('夜空に咲いた花火', 22, 0.25),
        ],
        'hanabi:test',
        duration: 40,
      );
      expect(
        program.paragraphs
            .expand((HanabiParagraph p) => p.shots)
            .any((HanabiShot s) => s.isBridge),
        isTrue,
      );
      final HanabiScene scene = HanabiScene(
        program: program,
        title: '花火',
        artist: 'Artist',
        album: 'Album',
      );
      addTearDown(scene.dispose);
      final List<HanabiSettings> settings = <HanabiSettings>[
        const HanabiSettings(),
        const HanabiSettings(
          textOnly: true,
          quality: HanabiQuality.low,
          bloom: 2,
          chorusBloom: 2,
        ),
        const HanabiSettings(
          collage: 2,
          ornamentAmount: 2,
          sparkAmount: 2,
          quality: HanabiQuality.balanced,
          spin: 2,
        ),
      ];
      for (final HanabiSettings s in settings) {
        for (double t = 0; t <= 40; t += 0.37) {
          _paintAt(scene, t, s);
        }
      }
      for (double t = 0; t <= 40; t += 1.3) {
        _paintAt(scene, t, const HanabiSettings(), motion: false);
      }
      expect(scene.builtParagraphs, greaterThan(0));
    });
  });
}
