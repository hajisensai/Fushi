import 'dart:io';

import 'package:flutter/material.dart';

/// HDR Phase 0 探针树（docs/plans/2026-08-30-video-hdr-passthrough.md §3）。
///
/// 只在 `--dart-define=FUSHI_HDR_SPIKE=true` 的探针构建里由 `main()` 顶部短路
/// 启动，正式构建永不进入。布局故意模仿视频页：左侧不透明侧栏、中央「视频洞」
/// （什么都不画；色键变体 4/5 画洋红）、底部半透明渐变控制条、中央半透明底字幕。
/// runner 侧探针窗在主窗正后方铺纯绿——截屏看洞里是不是绿、控件是否仍叠在其上。
class HdrSpikeApp extends StatelessWidget {
  const HdrSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final String variant = Platform.environment['FUSHI_HDR_SPIKE'] ?? '0';
    final bool colorKey = variant == '4' || variant == '5';
    final Color hole = colorKey ? const Color(0xFFFF00FF) : Colors.transparent;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          children: <Widget>[
            Container(
              width: 200,
              color: const Color(0xFF303030),
              alignment: Alignment.center,
              child: Text(
                'SIDEBAR v$variant',
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: hole),
                  const Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Color(0xAA000000)),
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          '字幕 subtitle overlay',
                          style: TextStyle(color: Colors.white, fontSize: 28),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 120,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[Color(0x00000000), Color(0xCC000000)],
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: <Widget>[
                              const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  height: 4,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
