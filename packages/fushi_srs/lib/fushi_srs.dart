/// Fushi SRS 纯 Dart 内核（设计见 docs/specs/2026-10-14-fushi-srs-design.md）。
library;

export 'src/algorithm.dart';
export 'src/anki_import_rules.dart';
export 'src/card_ops.dart';
export 'src/causal_context.dart';
export 'src/day.dart';
export 'src/deck.dart';
export 'src/entities.dart';
export 'src/event_store.dart';
export 'src/field_edit.dart';
export 'src/ffi/ffi_fsrs_engine.dart';
export 'src/ffi/fushi_fsrs_library.dart';
export 'src/fsrs_engine.dart';
export 'src/register_kernel.dart';
export 'src/history_kernel.dart'
    show
        SrsHistoryKernelUnavailableError,
        SrsHistoryState,
        SrsStoredHistory,
        SrsHistoryInput,
        srsDecodeHistoryStates,
        srsHistoryStatesFromJson,
        srsImportEquivalentAny;
export 'src/hlc.dart';
export 'src/ids.dart';
export 'src/new_card_budget.dart';
export 'src/note_type_ops.dart';
export 'src/ordering.dart';
export 'src/restore_plan.dart';
export 'src/review_log.dart';
export 'src/scheduler.dart';
export 'src/search/anki_search.dart';
export 'src/source_ref.dart';
export 'src/store/srs_columns.dart';
export 'src/store/srs_core.dart';
export 'src/store/srs_rows.dart';
export 'src/style_dedup.dart';
export 'src/term_status.dart';
export 'src/valid_logs.dart';
