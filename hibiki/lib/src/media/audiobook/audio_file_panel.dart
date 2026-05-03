import 'package:flutter/material.dart';
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
    required this.onChanged,
    super.key,
  });

  final List<AudioFileEntry> entries;
  final List<SectionOption> sections;
  final VoidCallback onChanged;

  @override
  State<AudioFilePanel> createState() => _AudioFilePanelState();
}

class _AudioFilePanelState extends State<AudioFilePanel> {
  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final AudioFileEntry entry = widget.entries.removeAt(oldIndex);
    widget.entries.insert(newIndex, entry);
    widget.onChanged();
  }

  void _removeEntry(int index) {
    setState(() => widget.entries.removeAt(index));
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
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: const Icon(Icons.more_vert, size: 18, color: Colors.grey),
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(t.dialog_delete),
                ),
              ],
              onSelected: (String action) {
                if (action == 'delete') _removeEntry(index);
              },
            ),
          ],
        ),
      ),
    );
  }
}
