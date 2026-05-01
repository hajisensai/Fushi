import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/media/audiobook/audio_file_entry.dart';
import 'package:hibiki/utils.dart';

class SectionOption {
  const SectionOption({required this.index, required this.label});
  final int index;
  final String label;
}

class AudioFilePanel extends StatefulWidget {
  const AudioFilePanel({
    required this.entries,
    required this.sections,
    required this.unmatchedSubtitles,
    required this.onChanged,
    super.key,
  });

  final List<AudioFileEntry> entries;
  final List<SectionOption> sections;
  final List<String> unmatchedSubtitles;
  final VoidCallback onChanged;

  @override
  State<AudioFilePanel> createState() => _AudioFilePanelState();
}

class _AudioFilePanelState extends State<AudioFilePanel> {
  static const List<String> _subtitleExts = ['srt', 'lrc', 'vtt', 'ass', 'ssa'];

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final AudioFileEntry entry = widget.entries.removeAt(oldIndex);
    widget.entries.insert(newIndex, entry);
    widget.onChanged();
  }

  Future<void> _pickSubtitleFor(int index) async {
    final List<String> pool = widget.unmatchedSubtitles;

    final String? chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.srt_pick_subtitle_file),
        children: [
          for (final String sub in pool)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, sub),
              child: Text(p.basename(sub), style: const TextStyle(fontSize: 13)),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final FilePickerResult? result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: _subtitleExts,
              );
              final String? path = result?.files.single.path;
              if (ctx.mounted) Navigator.pop(ctx, path);
            },
            child: Row(
              children: [
                const Icon(Icons.add, size: 18),
                const SizedBox(width: 8),
                Text(t.audio_panel_pick_new_subtitle, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          if (widget.entries[index].subtitlePath != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__remove__'),
              child: Row(
                children: [
                  const Icon(Icons.clear, size: 18, color: Colors.red),
                  const SizedBox(width: 8),
                  Text(t.audio_panel_remove_subtitle,
                      style: const TextStyle(fontSize: 13, color: Colors.red)),
                ],
              ),
            ),
        ],
      ),
    );

    if (chosen == null || !mounted) return;
    setState(() {
      if (chosen == '__remove__') {
        final String? old = widget.entries[index].subtitlePath;
        widget.entries[index].subtitlePath = null;
        if (old != null) widget.unmatchedSubtitles.add(old);
      } else {
        final String? old = widget.entries[index].subtitlePath;
        if (old != null) widget.unmatchedSubtitles.add(old);
        widget.entries[index].subtitlePath = chosen;
        widget.unmatchedSubtitles.remove(chosen);
      }
    });
    widget.onChanged();
  }

  void _onChapterChanged(int entryIndex, int? sectionIndex) {
    widget.entries[entryIndex].mappedSection = sectionIndex;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            t.audio_panel_title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            itemCount: widget.entries.length,
            onReorder: _onReorder,
            itemBuilder: (context, index) {
              final AudioFileEntry e = widget.entries[index];
              return _buildRow(e, index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRow(AudioFileEntry e, int index) {
    final bool hasSections = widget.sections.isNotEmpty;
    return Material(
      key: ValueKey(e.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                e.label,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (hasSections)
              Expanded(
                flex: 2,
                child: DropdownButton<int?>(
                  value: e.mappedSection,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(fontSize: 11),
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(t.audio_panel_auto,
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                    for (final SectionOption s in widget.sections)
                      DropdownMenuItem<int?>(
                        value: s.index,
                        child: Text(
                          s.label.isNotEmpty ? s.label : 'Section ${s.index}',
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (int? v) => _onChapterChanged(index, v),
                ),
              ),
            Expanded(
              flex: 2,
              child: InkWell(
                onTap: () => _pickSubtitleFor(index),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.subtitlePath != null) ...[
                      const Icon(Icons.subtitles, size: 14, color: Colors.green),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          p.basename(e.subtitlePath!),
                          style: const TextStyle(fontSize: 10, color: Colors.green),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ] else ...[
                      const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                      const SizedBox(width: 2),
                      Text(
                        t.audio_panel_unpaired,
                        style: const TextStyle(fontSize: 10, color: Colors.orange),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
