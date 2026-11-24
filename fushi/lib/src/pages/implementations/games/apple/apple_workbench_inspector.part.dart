part of '../../texthooker_page.dart';

// Cupertino 工作台：「本句」Inspector（macOS 右栏 / iOS「本句」页共用同一张
// [_LineTracksCard]，Apple 外观在它自己的玻璃分支里）。

extension _AppleWorkbenchInspector on _TexthookerPageState {
  Widget _buildAppleInspector(BuildContext context, _AppleWorkbench w) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final TexthookerLineEntry? line = w.selectedLine;
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('game-apple-inspector'),
      borderRadius: metrics.groupBorderRadius,
      child: w.readiness == GalWorkbenchReadiness.waitingForThread
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: _ThreadSelectionRequiredCard(),
            )
          : _LineTracksCard(
              session: _session,
              line: line,
              onClose: () => _toggleAppleInspector(open: true),
              actions: line == null ? null : _buildAppleLineActionBar(line),
            ),
    );
  }

  /// 「本句」动作条：与行内动作同一组回调（试听 / 改轨 / 补录 / 复制 / 收藏）。
  Widget _buildAppleLineActionBar(TexthookerLineEntry line) {
    final _LineRowModel row = _lineRowModel(line);
    return Builder(
      builder: (BuildContext context) {
        final FushiAppleColors apple = appleColorsOf(context);
        return Wrap(
          key: const ValueKey<String>('game-apple-line-actions'),
          spacing: 2,
          children: <Widget>[
            if (line.hasAudio)
              FushiIconButton(
                icon: row.previewingAudio
                    ? FushiIcons.stop
                    : FushiIcons.playCircle,
                tooltip: row.previewingAudio
                    ? t.game_track_preview_stop
                    : t.game_line_preview_tooltip,
                enabledColor: row.previewingAudio ? apple.accent : null,
                onTap: () => unawaited(_toggleLinePreview(line)),
              ),
            if (row.canPickTrack)
              FushiIconButton(
                icon: FushiIcons.audio,
                tooltip: t.game_line_track_tooltip,
                onTap: () => unawaited(_pickLineTrack(line)),
              ),
            if (row.canRecapture)
              FushiIconButton(
                icon: row.recapturing ? FushiIcons.stop : FushiIcons.mic,
                tooltip: row.recapturing
                    ? t.game_line_recapture_stop
                    : t.game_line_recapture,
                enabledColor: row.recapturing ? apple.destructive : null,
                onTap: () => unawaited(_toggleLineRecapture(line)),
              ),
            FushiIconButton(
              icon: FushiIcons.copyAll,
              tooltip: t.game_line_copy_tooltip,
              onTap: () => _appModel.copyToClipboard(row.displayText),
            ),
            FushiIconButton(
              icon: line.favorited
                  ? FushiIcons.filled(FushiIcons.star)
                  : FushiIcons.star,
              tooltip: line.favorited
                  ? t.game_line_unfavorite_tooltip
                  : t.game_line_favorite_tooltip,
              enabledColor: line.favorited ? apple.warning : null,
              onTap: () => _toggleLineFavorite(line),
            ),
          ],
        );
      },
    );
  }
}
