// Thin entry for the flutter guard (reader_horizontal_pitch_invariant_test.dart).
//
// This file used to be an AUTO-COMBINED copy of cdp_client.mjs +
// horizontal_pitch_harness.mjs "so flutter test could run it without relative
// imports". ESM resolves relative imports against the importing file, not the
// working directory (vn_lookup_audio_coordinates_harness.mjs here has always
// imported cdp_client.mjs this way), so the copy only bought drift: BUG-2803
// had to be fixed twice, and SonarCloud flagged the duplicate as 95.9% new-code
// duplication. The harness runs main() at module top level, so importing it
// runs it; exit codes are unchanged.
import '../../../tool/reader_pitch_headless/horizontal_pitch_harness.mjs';
