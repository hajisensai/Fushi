import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';

class VideoPlayBar extends StatelessWidget {
  const VideoPlayBar({required this.controller, super.key});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: controller.skipToPrevCue,
            ),
            IconButton(
              icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: controller.togglePlayPause,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: controller.skipToNextCue,
            ),
          ],
        );
      },
    );
  }
}
