/// The Tracking page's tab switch, kind filter and title search.
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show FushiSegmentedStrip;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:material_ui/material_ui.dart';

class TrackingFilterBar extends StatefulWidget {
  const TrackingFilterBar({
    required this.tab,
    required this.attentionCount,
    required this.linkedCount,
    required this.ignoredCount,
    required this.onTabChanged,
    required this.kinds,
    required this.selectedKinds,
    required this.onKindsChanged,
    required this.query,
    required this.onQueryChanged,
    super.key,
  });

  final TrackingPageTab tab;
  final int attentionCount;
  final int linkedCount;
  final int ignoredCount;
  final ValueChanged<TrackingPageTab> onTabChanged;

  /// Kinds that occur in the current tab; the filter offers only these.
  final List<TrackingRowKind> kinds;

  /// None = every kind.
  final Set<TrackingRowKind> selectedKinds;
  final ValueChanged<Set<TrackingRowKind>> onKindsChanged;
  final String query;
  final ValueChanged<String> onQueryChanged;

  @override
  State<TrackingFilterBar> createState() => _TrackingFilterBarState();
}

class _TrackingFilterBarState extends State<TrackingFilterBar> {
  late final TextEditingController _search = TextEditingController(
    text: widget.query,
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey<String>('tracking-page-filter'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: <Widget>[
          // Fits: one row. Too narrow (four tabs on a phone, large text):
          // scrolls sideways with faded edges and the chosen tab kept in view
          // (T1 F14: the fourth tab was off screen with no hint).
          FushiSegmentedStrip<TrackingPageTab>(
            key: const ValueKey<String>('tracking-page-tabs'),
            segments: <ButtonSegment<TrackingPageTab>>[
              ButtonSegment<TrackingPageTab>(
                value: TrackingPageTab.attention,
                label: Text(
                  '${t.media_tracking_page_tab_attention} '
                  '(${widget.attentionCount})',
                  key: const ValueKey<String>('tracking-page-tab-attention'),
                ),
              ),
              ButtonSegment<TrackingPageTab>(
                value: TrackingPageTab.linked,
                label: Text(
                  '${t.media_tracking_page_tab_linked} (${widget.linkedCount})',
                  key: const ValueKey<String>('tracking-page-tab-linked'),
                ),
              ),
              ButtonSegment<TrackingPageTab>(
                value: TrackingPageTab.ignored,
                label: Text(
                  '${t.media_tracking_page_tab_ignored} '
                  '(${widget.ignoredCount})',
                  key: const ValueKey<String>('tracking-page-tab-ignored'),
                ),
              ),
              ButtonSegment<TrackingPageTab>(
                value: TrackingPageTab.activity,
                label: Text(
                  t.media_tracking_page_tab_activity,
                  key: const ValueKey<String>('tracking-page-tab-activity'),
                ),
              ),
            ],
            selected: widget.tab,
            onChanged: widget.onTabChanged,
          ),
          FushiSearchBar(
            fieldKey: const ValueKey<String>('tracking-page-search'),
            controller: _search,
            hintText: t.media_tracking_page_search_hint,
            onQueryChanged: widget.onQueryChanged,
          ),
          // One kind alone is no filter.
          if (widget.kinds.length > 1)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiHorizontalEdgeFade(
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    child: FushiSegmentedButton<TrackingRowKind>(
                      key: const ValueKey<String>('tracking-page-kinds'),
                      multiSelectionEnabled: true,
                      emptySelectionAllowed: true,
                      segments: <ButtonSegment<TrackingRowKind>>[
                        for (final TrackingRowKind kind in widget.kinds)
                          ButtonSegment<TrackingRowKind>(
                            value: kind,
                            label: Text(
                              trackingRowKindLabel(kind),
                              key: ValueKey<String>(
                                'tracking-page-kind-${kind.name}',
                              ),
                            ),
                          ),
                      ],
                      selected: widget.selectedKinds,
                      onSelectionChanged: widget.onKindsChanged,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
