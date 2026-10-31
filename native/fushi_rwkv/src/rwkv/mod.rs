// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
// Adapted for Fushi from https://github.com/Pedrubik2000/kuma3-anki-core@c639bcec696f2317f9bb9a736d433b9d6c0d9c56 rslib/src/rwkv/mod.rs (trimmed to the inference core and the curve head; every change is marked `Fushi:`).

use std::borrow::Cow;
use std::collections::HashMap;
use std::io;
use std::sync::Arc;

use rayon::prelude::*;

mod bulk;
mod precision;
// Fushi: the small RWKV model and fixed-size state slots (not upstream).
mod slots;
pub mod small;
pub use precision::StatePrecision;
#[cfg(target_os = "macos")]
mod matmul;
#[cfg(target_arch = "aarch64")]
mod query_kernels;

const D_MODEL: usize = 128;
const CARD_FEATURES: usize = 92;
const HEADS: usize = 4;
const HEAD_SIZE: usize = D_MODEL / HEADS;
const HEAD_DIM: usize = 4 * D_MODEL;
const NUM_CURVES: usize = 128;

const MODULE_LAYERS: [usize; 5] = [3, 4, 2, 3, 4];
const CHANNEL_MIXER_DIMS: [usize; 5] = [192, 256, 192, 256, 256];
/// Rows per block in the bulk replay's blocked projection kernels. Bounds the
/// stack scratch used per block; larger blocks amortize weight-matrix streaming
/// over more rows.
const LINEAR_BLOCK_ROWS: usize = 32;

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
const MAX_CHANNEL_MIXER_DIM: usize = 256;
#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
const MAX_LORA_RANK: usize = 16;
#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
const RETRIEVABILITY_GEMM_BATCH_SIZE: usize = 128;
const ID_PLACEHOLDER: i64 = 314_159_265_358_979_323;
/// Fushi: the note key of a row without a note id is this plus its card id.
pub(crate) const ID_PLACEHOLDER_NOTE_BASE: i64 = ID_PLACEHOLDER;
const ID_SPLIT: u64 = 4;
const TORCH_ID_RNG_STATE_LEN: usize = 624;
const TORCH_ID_RNG_INITIAL_INDEX: usize = 4;
const TORCH_ID_RNG_INITIAL_STATE: [u32; TORCH_ID_RNG_STATE_LEN] = [
    1682285388, 1851481669, 966820414, 1804407443, 3932621889, 3075156175, 1736360318, 934395819,
    4040256764, 1428315994, 3735821200, 3330369387, 3669296551, 4124277305, 1875917743, 3028165727,
    2848364260, 455193708, 1084726271, 4219366876, 4052358395, 3170678824, 468221764, 161941628,
    2640816207, 267628614, 4070986878, 1225344559, 697494497, 1246641310, 1864086393, 2343787891,
    956379933, 132227689, 1804503562, 801719826, 2866035087, 3697914572, 3618475839, 3714856595,
    3045796150, 2653947806, 695225985, 3299305861, 2299901543, 282374836, 2677848525, 308337505,
    1649403860, 3241582120, 1641323885, 211358346, 1648589179, 3479631618, 11568893, 2867282711,
    4042451176, 611732436, 3506334995, 3562753239, 1234760878, 2196749548, 3668376444, 2428528228,
    631426791, 4017895429, 3026146201, 4191008964, 1932380089, 3380014424, 3547882387, 3952077360,
    386896944, 3997977197, 1529608344, 4132999748, 2534739147, 4182207012, 1114211877, 2611407325,
    442230326, 2804113464, 4095607840, 2203942301, 3208806807, 4217725735, 851085756, 3111179814,
    2893561443, 1737762208, 3364884061, 3768266261, 1951940754, 1219713113, 661792618, 2429297141,
    2854706310, 2555881125, 1720186105, 2231784162, 1816231541, 2459472524, 2303395945, 2802874606,
    164142194, 3722278385, 965390944, 1789460144, 2277056390, 2785283897, 557026319, 1822107998,
    2156805627, 1809760430, 751565145, 1320417968, 760565420, 3675458714, 266229863, 3071308558,
    2588875244, 520697952, 404211066, 3757472951, 1592302302, 1301622844, 283875151, 2264576214,
    1513690933, 3186056547, 503942925, 3452110716, 4068977508, 1386120901, 35467672, 3736425491,
    3479928582, 4057588406, 1156892529, 2666030005, 1947426597, 1513426209, 2298519457, 951648,
    2662765076, 1819076585, 991609795, 3445620136, 4263402744, 683674655, 125305024, 400363870,
    4175058246, 345274265, 1393354662, 4168368724, 1992205233, 333760424, 430638818, 2038831240,
    2393249574, 2277698148, 3834699795, 854369076, 1949138442, 879235983, 2687356990, 74489205,
    675756224, 1108887942, 3850167999, 3202550759, 346927610, 1219004248, 1933710611, 4232192948,
    127380890, 3413854308, 4259402585, 1947897797, 2281478841, 1250526173, 3584776535, 3962965149,
    2436415337, 3700599595, 2305091483, 441956968, 98602741, 1004357398, 2171103081, 3555585131,
    25494344, 474746862, 2168816300, 1445677778, 2762834911, 167135277, 1609410667, 342499195,
    2658948465, 96705736, 307223780, 2817802860, 1095652744, 1458155099, 2129035584, 3380124286,
    4277476542, 3149780470, 201762377, 3878283276, 2943856629, 1484419446, 536631262, 3610340050,
    2021510328, 405479479, 126321448, 112807861, 206360937, 2329863092, 2176182667, 761094335,
    3055987424, 3047673301, 1636351146, 730123282, 1603106892, 3241403281, 64478013, 2355203790,
    3571782552, 1977824032, 3103684787, 1440206087, 3529256035, 4029036380, 1727403531, 2250763223,
    2609572110, 301200603, 2499812360, 1079194345, 1873534699, 592458645, 3367330921, 2157823439,
    2377315769, 2124247689, 3501423240, 44290279, 2658883840, 3187367635, 2223108434, 621774141,
    2862251779, 58506969, 1447924885, 3417741267, 3295650570, 2061828420, 656716143, 722185440,
    2516683235, 2575345773, 2104327887, 3735805058, 1317382073, 297471524, 1841093725, 3008896502,
    106767431, 125566800, 2298510351, 1201930425, 907367885, 3447227635, 647146338, 926864998,
    673001384, 2537138065, 1291689589, 1065989187, 640479966, 2169443668, 1796563022, 3530758358,
    566177121, 1707919249, 1474913925, 3765619977, 3740101935, 3130400739, 2400651968, 1474401929,
    526695285, 943720479, 874038331, 330689749, 3219805999, 3116943707, 2803955215, 2165155639,
    4244261781, 2888630181, 252759016, 3783988093, 1530768853, 2944465398, 303528941, 3002511155,
    2323759006, 3019190001, 2122243812, 1121230145, 1730608278, 741152631, 1508537030, 3728973132,
    3150372859, 1696219691, 580153578, 2686308765, 1065154441, 582354200, 1629450702, 3804950383,
    1377430830, 3231855250, 716684766, 2347913152, 3723768936, 3995049093, 1640930380, 2518706901,
    3418463630, 541497465, 3219798303, 1706475941, 306647767, 1641899345, 1570832171, 1052204431,
    3913625992, 215023677, 1412164449, 110620318, 1060606607, 702131657, 1847887127, 209232170,
    3730056702, 1139625814, 1887242045, 3850643319, 3750397920, 2071715462, 3479548451, 1555884857,
    4190680751, 1832210452, 2962479459, 3822065681, 4014873921, 2886096746, 2233784512, 2238930674,
    3655246617, 927454496, 148905975, 1631004036, 96233864, 1481847180, 2120974892, 2577516900,
    1638964877, 1481137923, 1414769434, 3161093534, 112755530, 1764064957, 4190363343, 3887127551,
    1834924570, 83845051, 1194548396, 4079088278, 2045362678, 1769415013, 4005488543, 3853058044,
    3236458945, 2957047901, 1695491053, 3109347023, 1966942432, 1450132000, 2200494752, 608196473,
    3106709220, 4028691397, 1194244113, 3728413990, 3069222360, 3780538931, 2072954337, 3718173202,
    4049735703, 309723989, 3035905309, 1497948243, 1014496292, 3798948403, 2803094444, 342979147,
    1189029508, 1965636522, 3735884288, 851551988, 763723908, 4250649925, 1551115212, 2057541610,
    3495494782, 637069736, 2304408148, 815858117, 2236554473, 1483594123, 1278501755, 2394803515,
    1955783100, 1792990840, 2122870956, 530734808, 3030700278, 723763396, 2270626039, 2629780941,
    2984465025, 3688570684, 2776316291, 900046415, 2828563145, 1683929076, 3635512397, 2298110775,
    218175329, 1069560764, 2297081356, 2401672963, 1007365472, 421703457, 3609147592, 3680957553,
    2021586893, 3380432468, 3986237638, 1178822340, 3062404559, 1622982873, 3690602096, 2439524694,
    3587851041, 2408352887, 2166555969, 3451949389, 1782985112, 1721002099, 2722187334, 3644256530,
    3166709237, 666319864, 3937101570, 2322768459, 2640925986, 3091708170, 176155768, 2070897063,
    31962327, 1980355715, 1579825601, 2980116859, 1296346288, 3253021476, 1566345931, 1333641409,
    1466299323, 3535059214, 3755906045, 2436710697, 2624047850, 2773027064, 2735441585, 2397006833,
    2403155593, 2322419556, 3211067371, 2902277310, 855808633, 2088710794, 2365540733, 3598761409,
    96395577, 2793454657, 293134636, 997092999, 1516229869, 3830922510, 1456537668, 2543557055,
    2250567838, 47738566, 3310116596, 429974987, 2597497913, 3570401473, 3554123533, 3733732981,
    65117535, 89824483, 467063829, 2980094347, 459068879, 288615762, 505566088, 161491799,
    1950807394, 4134005883, 832113435, 383539149, 3289684623, 984364633, 3767074980, 349818067,
    3687375566, 2799114350, 945518296, 1410152104, 3876984338, 2571021970, 3352118476, 4178487553,
    1203153759, 611118555, 3259506420, 2891465405, 3445709652, 3949641380, 2875186838, 2779811328,
    2510853343, 4275646002, 2491038814, 2422179298, 1650323772, 3000898162, 3627492445, 1678944205,
    4261066493, 2595842431, 3948513109, 2750405154, 2564814475, 2584030305, 2613484438, 3805313548,
    3123055455, 1702940891, 1364814166, 3578222670, 1736412364, 2853289958, 182827375, 3335617072,
    3347856282, 771668471, 2881257662, 1618901303, 2911271774, 2283475553, 1640165049, 3561675959,
    384011161, 1071788681, 2189107920, 2737255457, 1011242690, 1067383324, 2768630076, 35989731,
    3477113433, 3502877655, 3126304174, 2125983443, 1065189709, 3085270280, 2313355736, 2406873069,
    1095216321, 1458394816, 1881192803, 2616673852, 425572748, 1377770342, 4183972521, 154875079,
    1436212463, 1213363850, 2416318273, 3309606622, 3757797616, 936646994, 3996477797, 836380753,
    1177367651, 2904456246, 600155443, 2732456183, 2305820104, 1912638872, 271951098, 119535942,
];
const DAY_OFFSET_ENCODE_PERIODS: [f32; 7] = [3.0, 7.0, 30.0, 100.0, 365.0, 3650.0, 36500.0];
const SECONDS_PER_DAY: i64 = 86_400;

const ELAPSED_DAYS_MEAN: f32 = 1.51;
const ELAPSED_DAYS_STD: f32 = 1.62;
const ELAPSED_DAYS_CUMULATIVE_MEAN: f32 = 2.14;
const ELAPSED_DAYS_CUMULATIVE_STD: f32 = 2.25;
const ELAPSED_SECONDS_MEAN: f32 = 9.96;
const ELAPSED_SECONDS_STD: f32 = 5.21;
const ELAPSED_SECONDS_CUMULATIVE_MEAN: f32 = 10.86;
const ELAPSED_SECONDS_CUMULATIVE_STD: f32 = 5.8;
const DURATION_MEAN: f32 = 8.9;
const DURATION_STD: f32 = 1.07;
const DIFF_NEW_CARDS_MEAN: f32 = 2.945;
const DIFF_NEW_CARDS_STD: f32 = 2.011;
const DIFF_REVIEWS_MEAN: f32 = 4.64;
const DIFF_REVIEWS_STD: f32 = 2.59;
const CUM_NEW_CARDS_TODAY_MEAN: f32 = 2.55;
const CUM_NEW_CARDS_TODAY_STD: f32 = 1.41;
const CUM_REVIEWS_TODAY_MEAN: f32 = 4.59;
const CUM_REVIEWS_TODAY_STD: f32 = 1.30;

#[derive(Debug, Clone)]
pub struct ReviewInput {
    pub card_id: i64,
    pub note_id: Option<i64>,
    pub deck_id: Option<i64>,
    pub preset_id: Option<i64>,
    pub is_query: bool,
    pub ease: Option<u8>,
    pub duration_millis: Option<i64>,
    /// Legacy field name: answered inputs contain the training dataset state.
    pub card_type: Option<i64>,
    pub day_offset: Option<i64>,
    pub current_elapsed_days: Option<i64>,
    pub current_elapsed_seconds: Option<i64>,
    // Fushi: upstream's `target_retentions` / `enforce_grade_order` fields fed
    // only the RWKV-Curve interval solver, which is not carried over.
}

/// Fushi: the parsed network, shareable between runtimes (upstream loaded it
/// inside `RwkvInference::load_with_precision`).
#[derive(Clone)]
pub struct RwkvModel {
    model: Arc<SrsModel>,
}

impl RwkvModel {
    /// Parses an `ARWKVWEIGHTS1` weight file already in memory.
    pub fn from_bytes(bytes: &[u8]) -> io::Result<Self> {
        Ok(Self {
            model: Arc::new(SrsModel::from_weight_bytes(bytes)?),
        })
    }
}

pub struct RwkvInference {
    model: Arc<SrsModel>,
    features: FeatureState,
    warm_up_states: ReviewStateMaps,
    // Fushi: no `curves` (per-card RWKV-Curve heads, ~1 KB each), resident-
    // state stash, SQLite state-cache store, target retention or max interval.
}

#[derive(Clone, Copy)]
struct ReviewPredictionQueryRef<'a> {
    features: &'a [f32],
    state: SrsStateRef<'a>,
}

impl ReviewPredictionQueryRef<'_> {
    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn layer_state(&self, module_id: usize, layer_id: usize) -> Option<&LayerState> {
        self.state
            .module(module_id)
            .and_then(|state| state.layers.get(layer_id))
    }
}

impl RwkvInference {
    /// Fushi: upstream `load_with_precision(path, target_retention,
    /// max_interval_days, precision)` minus the file read and the two interval
    /// settings. A non-f32 precision gets its own copy of the network, since
    /// upstream keeps the state precision on the card and note modules.
    pub fn new(model: &RwkvModel, precision: StatePrecision) -> Self {
        let mut model = if precision == StatePrecision::F32 {
            Arc::clone(&model.model)
        } else {
            Arc::new(SrsModel::clone(&model.model))
        };
        if precision != StatePrecision::F32 {
            Self::set_precision(Arc::get_mut(&mut model).expect("fresh copy"), precision);
        }
        Self {
            model,
            features: FeatureState::default(),
            warm_up_states: ReviewStateMaps::default(),
        }
    }

    /// The precision card states are kept in (note states: see
    /// [Self::set_precision]).
    pub fn precision(&self) -> StatePrecision {
        self.model.modules[0].precision
    }

    fn set_precision(model: &mut SrsModel, precision: StatePrecision) {
        model.modules[0].precision = precision;
        // A note's state takes every answer to all its cards, and int4's
        // rounding drift there grew without bound (a 3.5M-review history went
        // past f32's range two minutes into its replay, then NaN). Card states
        // stay int4; notes keep int8.
        model.modules[2].precision = match precision {
            StatePrecision::Int4 => StatePrecision::Int8,
            other => other,
        };
    }

    pub fn predict_retrievability_many_from_warm_up(
        &mut self,
        inputs: Vec<ReviewInput>,
    ) -> io::Result<Vec<f32>> {
        for input in &inputs {
            if !input.is_query {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "RWKV batched retrievability prediction only supports query inputs",
                ));
            }
        }

        let features = inputs
            .iter()
            .map(|input| self.features.features_for(input))
            .collect::<Vec<_>>();
        // Compact card and note states are decoded a chunk at a time, not all of
        // a big collection's at once.
        let mut retrievabilities = Vec::with_capacity(inputs.len());
        for (inputs, features) in inputs
            .chunks(STATE_VIEW_CHUNK)
            .zip(features.chunks(STATE_VIEW_CHUNK))
        {
            let views = inputs
                .par_iter()
                .map(|input| self.warm_up_states.state_view(input))
                .collect::<Vec<_>>();
            let items = features
                .iter()
                .zip(&views)
                .map(|(features, view)| ReviewPredictionQueryRef {
                    features,
                    state: view.as_ref(),
                })
                .collect::<Vec<_>>();
            retrievabilities.extend(self.model.review_retrievability_query_refs(&items));
        }
        Ok(retrievabilities)
    }

    pub fn warm_up_reviews(
        &mut self,
        reviews: Vec<ReviewInput>,
        record_predictions: bool,
    ) -> io::Result<Vec<(usize, f32)>> {
        bulk::warm_up_reviews_bulk(self, reviews, record_predictions)
    }

    /// The per-review reference implementation of `warm_up_reviews`. The bulk
    /// path must match it bit-for-bit; parity tests compare the two.
    ///
    /// Fushi: public so the parity tests can run it; upstream keeps it private.
    pub fn warm_up_reviews_sequential(
        &mut self,
        reviews: Vec<ReviewInput>,
        record_predictions: bool,
    ) -> io::Result<Vec<(usize, f32)>> {
        let mut predictions = vec![];
        for (index, input) in reviews.into_iter().enumerate() {
            if input.ease.is_none() {
                continue;
            }

            // Query features must be assigned before answer features so
            // first-seen ID encodings keep the benchmark-compatible order.
            let query_features = record_predictions.then(|| {
                let mut query_input = input.clone();
                query_input.is_query = true;
                query_input.ease = None;
                query_input.duration_millis = None;
                self.features.features_for(&query_input)
            });

            let features = self.features.features_for(&input);
            let model = &*self.model;
            // The query and answer inputs share card/note/deck/preset ids, so
            // both passes read the same pre-review state and can run in
            // parallel; only the answer pass advances state below.
            let view = self.warm_up_states.state_view(&input);
            let state = view.as_ref();
            let (query_retrievability, heads) = match &query_features {
                Some(query_features) => {
                    let (retrievability, heads) = rayon::join(
                        || {
                            model.review_retrievability_query_refs(&[ReviewPredictionQueryRef {
                                features: query_features,
                                state,
                            }])[0]
                        },
                        || model.review(&features, state),
                    );
                    (Some(retrievability), heads)
                }
                None => (None, model.review(&features, state)),
            };
            if let Some(retrievability) = query_retrievability {
                predictions.push((index, retrievability));
            }

            self.features.store_review(&input);
            self.warm_up_states.store(&input, heads.next_state);
        }

        Ok(predictions)
    }

    /// Fushi: upstream `append_warm_up_snapshot_binary(path)` writing into any
    /// writer instead of appending to a file. Lossless (every state as
    /// [write_serialized_module_state] gives it), unlike kuma3's offline state file,
    /// which rounds deck, preset and global states to halves.
    fn write_warm_up_snapshot_binary(&self, out: &mut impl io::Write) -> io::Result<()> {
        let mut out = out;
        write_snapshot_state_map(&mut out, &self.warm_up_states.card)?;
        write_snapshot_state_map(&mut out, &self.warm_up_states.note)?;
        write_snapshot_state_map(&mut out, &self.warm_up_states.deck)?;
        write_snapshot_state_map(&mut out, &self.warm_up_states.preset)?;
        match &self.warm_up_states.global {
            Some(state) => {
                out.write_all(&[1])?;
                write_snapshot_module_state(&mut out, state)?;
            }
            None => out.write_all(&[0])?,
        }
        out.write_all(&[1])?;
        write_snapshot_u32(&mut out, self.runtime_cache_state_len())?;
        self.write_runtime_cache_state(&mut out)
    }

    pub fn reset_warm_up_state(&mut self) {
        self.warm_up_states = ReviewStateMaps::default();
    }

    /// Fushi: forgets everything replayed, recurrent states and the feature
    /// bookkeeping (ID encodings, per-card cumulative elapsed, today counters)
    /// alike, as a freshly created runtime.
    pub fn reset(&mut self) {
        self.reset_warm_up_state();
        self.features = FeatureState::default();
    }

    pub fn cache_state(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.runtime_cache_state_len());
        self.write_runtime_cache_state(&mut out)
            .expect("writing to a Vec should not fail");
        out
    }

    // Fushi: the runtime cache state keeps upstream's `ARWKVPROCSTATE2`
    // layout with an always-empty curve table (Fushi keeps no curves).
    fn runtime_cache_state_len(&self) -> usize {
        b"ARWKVPROCSTATE2".len() + self.features.cache_state_len() + 4
    }

    fn write_runtime_cache_state(&self, out: &mut impl io::Write) -> io::Result<()> {
        out.write_all(b"ARWKVPROCSTATE2")?;
        self.features.write_cache_state_to(out)?;
        write_state_cache_u32(out, 0)
    }

    /// Fushi: curves in an upstream cache state are skipped.
    pub fn restore_cache_state(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.features = read_runtime_feature_state(bytes)?;
        Ok(())
    }

    // ---- Fushi additions below this line (not in upstream) ----------------

    /// Everything [Self::warm_up_reviews] has built up, as bytes:
    /// `FRWKVSNAP1\0`, a precision byte (0 = f32, 8 = int8, 4 = int4), then
    /// upstream's `append_warm_up_snapshot_binary` layout (card, note, deck and
    /// preset maps as u32 count + per id ascending i64 id + u32 length + state;
    /// global as flag + length + state; then flag + length + the
    /// `ARWKVPROCSTATE2` feature cache). Lossless: replaying more reviews after
    /// [Self::restore_snapshot] gives bit-identical results to never stopping.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.write_snapshot(&mut out)
            .expect("writing to a Vec should not fail");
        out
    }

    /// Writes the same lossless format as `snapshot` without a whole-file buffer.
    pub fn write_snapshot(&self, out: &mut impl io::Write) -> io::Result<()> {
        out.write_all(SNAPSHOT_MAGIC)?;
        out.write_all(&[precision_code(self.precision())])?;
        self.write_warm_up_snapshot_binary(out)
    }

    // Previous encoder retained only as a compatibility oracle in tests.
    #[cfg(test)]
    pub(crate) fn legacy_snapshot(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(SNAPSHOT_MAGIC);
        out.push(precision_code(self.precision()));
        for map in [&self.warm_up_states.card as &dyn StateMap, &self.warm_up_states.note,
            &self.warm_up_states.deck, &self.warm_up_states.preset] {
            write_snapshot_state_map(&mut out, map).unwrap();
        }
        if let Some(state) = &self.warm_up_states.global {
            let mut bytes = Vec::new();
            write_serialized_module_state(&mut bytes, state).unwrap();
            out.push(1);
            write_u32(&mut out, bytes.len() as u32);
            out.extend_from_slice(&bytes);
        } else {
            out.push(0);
        }
        let features = self.cache_state();
        out.push(1);
        write_u32(&mut out, features.len() as u32);
        out.extend_from_slice(&features);
        out
    }

    /// Replaces this runtime's state with a [Self::snapshot]. The snapshot
    /// must come from a runtime with the same precision; nothing changes when
    /// it is refused.
    pub fn restore_snapshot(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.read_snapshot(&mut io::Cursor::new(bytes), bytes.len() as u64)
    }

    /// Reads a bounded snapshot; the old state remains intact on any error.
    pub fn read_snapshot(&mut self, input: &mut impl io::Read, len: u64) -> io::Result<()> {
        let invalid =
            |message: &str| io::Error::new(io::ErrorKind::InvalidData, message.to_owned());
        let mut cursor = SnapshotReader::new(input, len);
        cursor.expect_magic(SNAPSHOT_MAGIC)?;
        if cursor.u8()? != precision_code(self.precision()) {
            return Err(invalid(
                "RWKV snapshot was taken with another state precision",
            ));
        }
        let mut states = ReviewStateMaps::default();
        for module_id in [0, 2] {
            let count = cursor.count(12)?;
            let map = if module_id == 0 {
                &mut states.card
            } else {
                &mut states.note
            };
            for _ in 0..count {
                let id = cursor.i64()?;
                let state = self.read_snapshot_state(&mut cursor, module_id)?;
                if map.contains(id) {
                    return Err(invalid("duplicate RWKV snapshot state"));
                }
                map.put(id, state);
            }
        }
        for module_id in [1, 3] {
            let count = cursor.count(12)?;
            for _ in 0..count {
                let id = cursor.i64()?;
                let state = self.read_snapshot_state(&mut cursor, module_id)?;
                let map = if module_id == 1 {
                    &mut states.deck
                } else {
                    &mut states.preset
                };
                if map.insert(id, state).is_some() {
                    return Err(invalid("duplicate RWKV snapshot state"));
                }
            }
        }
        states.global = match cursor.u8()? {
            0 => None,
            1 => Some(self.read_snapshot_state(&mut cursor, 4)?),
            _ => return Err(invalid("invalid RWKV snapshot flag")),
        };
        if cursor.u8()? != 1 {
            return Err(invalid("RWKV snapshot has no feature state"));
        }
        let len = cursor.u32()? as usize;
        let features = read_runtime_feature_state(cursor.bytes(len)?)?;
        cursor.expect_end()?;
        self.warm_up_states = states;
        self.features = features;
        Ok(())
    }

    /// One `u32 length + state` record, checked against the shape the model
    /// gives `module_id`'s states (the check upstream's offline state reader,
    /// `read_file_module_state`, made) and against this runtime's precision.
    fn read_snapshot_state(
        &self,
        cursor: &mut SnapshotReader<'_, impl io::Read>,
        module_id: usize,
    ) -> io::Result<ModuleState> {
        let damaged = || io::Error::new(io::ErrorKind::InvalidData, "damaged RWKV state");
        let len = cursor.u32()? as usize;
        let state = deserialize_module_state(Some(cursor.bytes(len)?))?.ok_or_else(damaged)?;
        let module = &self.model.modules[module_id];
        if state.packed.is_some() != (module.precision != StatePrecision::F32) {
            return Err(damaged());
        }
        let layers = module.layers.len();
        let decoded = state.decoded();
        let shape_ok = decoded.layers.len() == layers
            && decoded.layers.iter().all(|layer| {
                layer.time.as_ref().is_some_and(|time| {
                    time.x_shift.len() == D_MODEL
                        && time.matrix.len() == HEADS * HEAD_SIZE * HEAD_SIZE
                }) && layer
                    .channel_shift
                    .as_ref()
                    .is_some_and(|c| c.len() == D_MODEL)
            });
        if !shape_ok {
            return Err(damaged());
        }
        drop(decoded);
        Ok(state)
    }

    /// Fushi: diagnostics for the long-history tests: the largest absolute
    /// time-mixer matrix value over every card (`module_id` 0) or note (2)
    /// state.
    #[doc(hidden)]
    pub fn stream_peak(&self, module_id: usize) -> f32 {
        let map = match module_id {
            0 => &self.warm_up_states.card,
            2 => &self.warm_up_states.note,
            _ => return f32::NAN,
        };
        map.ids()
            .into_iter()
            .filter_map(|id| map.state(&id))
            .map(|state| {
                state
                    .decoded()
                    .layers
                    .iter()
                    .filter_map(|layer| layer.time.as_ref())
                    .flat_map(|time| time.matrix.iter())
                    .fold(0.0f32, |m, v| m.max(v.abs()))
            })
            .fold(0.0, f32::max)
    }

    /// The raw `day_offset` of the last replayed answer (None before any).
    pub fn last_day_offset(&self) -> Option<i64> {
        Some(self.features.first_day_offset? + self.features.previous_day_offset?)
    }

    /// Fushi: R of `answer`'s card at each query in `queries` (built for the
    /// moment after the answer: [forecast_query]) had `answer` been given
    /// with each rating in `ratings`. Nothing is kept: the answer runs on the
    /// current states without storing them (the sequential path's
    /// `SrsModel::review`) and the feature bookkeeping is put back. Result:
    /// `ratings.len() * queries.len()` values, rating-major.
    pub fn forecast(
        &mut self,
        answer: &ReviewInput,
        ratings: &[u8],
        queries: &[ReviewInput],
    ) -> io::Result<Vec<f32>> {
        let mut out = Vec::with_capacity(ratings.len() * queries.len());
        for &rating in ratings {
            let mut answer = answer.clone();
            answer.is_query = false;
            answer.ease = Some(rating);
            let features = self.features.features_for(&answer);
            let view = self.warm_up_states.state_view(&answer);
            let next = self.model.review(&features, view.as_ref()).next_state;
            drop(view);
            let query_features: Vec<Vec<f32>> = self.features.with_hypothetical_review(&answer, |state| {
                queries.iter().map(|query| state.features_for(query)).collect()
            });
            let state = SrsStateRef {
                card: Some(&next.card),
                deck: answer.deck_id.map(|_| &next.deck),
                note: answer.note_id.map(|_| &next.note),
                preset: answer.preset_id.map(|_| &next.preset),
                global: Some(&next.global),
            };
            let items: Vec<ReviewPredictionQueryRef<'_>> = query_features
                .iter()
                .map(|features| ReviewPredictionQueryRef { features, state })
                .collect();
            out.extend(self.model.review_retrievability_query_refs(&items));
        }
        Ok(out)
    }

    /// Fushi: the RWKV-Curve heads of `answer` answered Again / Hard / Good /
    /// Easy (upstream `answer_heads` + `simulated_answer_input`): one what-if
    /// update row per rating from the current states, nothing kept. Each is the
    /// 128-curve mixture weights; evaluate with [predict_curve].
    pub fn answer_curves(&mut self, answer: &ReviewInput) -> io::Result<[Vec<f32>; 4]> {
        let mut out: [Vec<f32>; 4] = Default::default();
        for (index, slot) in out.iter_mut().enumerate() {
            let mut answer = answer.clone();
            answer.is_query = false;
            answer.ease = Some(index as u8 + 1);
            let features = self.features.features_for(&answer);
            let view = self.warm_up_states.state_view(&answer);
            *slot = self.model.review(&features, view.as_ref()).curve.weights;
        }
        Ok(out)
    }

    /// Sizes of what has been built up so far.
    pub fn stats(&self) -> RwkvStats {
        let states = &self.warm_up_states;
        let card_state_bytes = states.card.serialized_len();
        let note_state_bytes = states.note.serialized_len();
        let shared_state_bytes = states
            .deck
            .values()
            .chain(states.preset.values())
            .chain(states.global.iter())
            .map(serialized_module_state_len)
            .sum();
        RwkvStats {
            reviews: self.features.review_index,
            cards: states.card.count(),
            notes: states.note.count(),
            decks: states.deck.len(),
            presets: states.preset.len(),
            card_state_bytes,
            note_state_bytes,
            shared_state_bytes,
            feature_state_bytes: self.runtime_cache_state_len(),
        }
    }
}

/// Fushi: see [RwkvInference::stats]. Byte counts are the serialized sizes,
/// which track resident memory closely (states are flat f32/i8 vectors).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RwkvStats {
    /// Answered reviews replayed (rating-less rows are not counted).
    pub reviews: i64,
    pub cards: usize,
    pub notes: usize,
    pub decks: usize,
    pub presets: usize,
    pub card_state_bytes: usize,
    pub note_state_bytes: usize,
    /// Deck + preset + global states.
    pub shared_state_bytes: usize,
    /// ID encodings and per-card bookkeeping of the feature builder.
    pub feature_state_bytes: usize,
}

const SNAPSHOT_MAGIC: &[u8] = b"FRWKVSNAP1\0";

fn precision_code(precision: StatePrecision) -> u8 {
    match precision {
        StatePrecision::F32 => 0,
        StatePrecision::Int8 => 8,
        StatePrecision::Int4 => 4,
    }
}

fn read_runtime_feature_state(bytes: &[u8]) -> io::Result<FeatureState> {
    let mut cursor = Cursor::new(bytes);
    cursor.expect_magic(b"ARWKVPROCSTATE2")?;
    let features = FeatureState::read_cache_state(&mut cursor)?;
    let curve_count = cursor.u32()? as usize;
    for _ in 0..curve_count {
        cursor.i64()?;
        cursor.skip_f32_vec()?;
        cursor.skip_f32_vec()?;
    }
    cursor.expect_end()?;
    Ok(features)
}

/// Fushi: the feature bookkeeping one journaled review changed
/// ([FeatureState::checkpoint] / [FeatureState::rewind]).
#[derive(Clone)]
pub(crate) struct FeatureUndo {
    card: i64,
    scalars: (Option<i64>, Option<i64>, i64, i64, i64, i64),
    seen: bool,
    per_card: [Option<i64>; 5],
    new_ids: Vec<(IdKind, i64)>,
    rng_before: Option<TorchIdRng>,
    rng_after: Option<TorchIdRng>,
}

#[derive(Clone)]
struct FeatureState {
    first_day_offset: Option<i64>,
    previous_day_offset: Option<i64>,
    card_set: HashMap<i64, ()>,
    last_new_cards: HashMap<i64, i64>,
    last_i: HashMap<i64, i64>,
    today: i64,
    today_reviews: i64,
    today_new_cards: i64,
    card_first_day_offset: HashMap<i64, i64>,
    card_elapsed_days_cumulative: HashMap<i64, i64>,
    card_elapsed_seconds_cumulative: HashMap<i64, i64>,
    id_encodings: HashMap<(IdKind, i64), Vec<f32>>,
    id_rng: TorchIdRng,
    review_index: i64,
}

impl Default for FeatureState {
    fn default() -> Self {
        Self {
            first_day_offset: None,
            previous_day_offset: None,
            card_set: HashMap::new(),
            last_new_cards: HashMap::new(),
            last_i: HashMap::new(),
            today: -1,
            today_reviews: 0,
            today_new_cards: 0,
            card_first_day_offset: HashMap::new(),
            card_elapsed_days_cumulative: HashMap::new(),
            card_elapsed_seconds_cumulative: HashMap::new(),
            id_encodings: HashMap::new(),
            id_rng: TorchIdRng::default(),
            review_index: 0,
        }
    }
}

impl FeatureState {
    fn features_for(&mut self, input: &ReviewInput) -> Vec<f32> {
        let elapsed_seconds = elapsed_seconds(input);
        let elapsed_days = elapsed_days(input, elapsed_seconds);
        let elapsed_days_cumulative = self
            .card_elapsed_days_cumulative
            .get(&input.card_id)
            .copied()
            .unwrap_or(0)
            + elapsed_days;
        let elapsed_seconds_cumulative = self
            .card_elapsed_seconds_cumulative
            .get(&input.card_id)
            .copied()
            .unwrap_or(0)
            + elapsed_seconds;

        let raw_day_offset = input.day_offset.unwrap_or(0);
        let day_offset = self
            .first_day_offset
            .map_or(0, |first_day_offset| raw_day_offset - first_day_offset);
        let day_offset_first = self
            .card_first_day_offset
            .get(&input.card_id)
            .copied()
            .unwrap_or(day_offset);
        let previous_day_offset = self.previous_day_offset.unwrap_or(0);
        let diff_new_cards = self
            .last_new_cards
            .get(&input.card_id)
            .map_or(0, |last_new_cards| {
                self.card_set.len() as i64 - last_new_cards
            });
        let diff_reviews = self
            .last_i
            .get(&input.card_id)
            .map_or(0, |last_i| (self.review_index - last_i - 1).max(0));

        let mut today_new_cards = self.today_new_cards;
        let mut today_reviews = self.today_reviews;
        if day_offset != self.today {
            today_new_cards = 0;
            today_reviews = -1;
        }
        today_reviews += 1;
        if !self.card_set.contains_key(&input.card_id) {
            today_new_cards += 1;
        }

        let mut features = Vec::with_capacity(CARD_FEATURES);
        features.extend([
            scale_elapsed_days(elapsed_days),
            scale_elapsed_days_cumulative(elapsed_days_cumulative),
            scale_elapsed_seconds(elapsed_seconds),
            cyclic_sin(elapsed_seconds, SECONDS_PER_DAY),
            cyclic_cos(elapsed_seconds, SECONDS_PER_DAY),
            scale_elapsed_seconds_cumulative(elapsed_seconds_cumulative),
            cyclic_sin(elapsed_seconds_cumulative, SECONDS_PER_DAY),
            cyclic_cos(elapsed_seconds_cumulative, SECONDS_PER_DAY),
            scaled_duration(input),
        ]);

        let rating = input.ease.unwrap_or(0);
        for ease in 1..=4 {
            features.push(if !input.is_query && rating == ease {
                1.0
            } else {
                0.0
            });
        }

        let note_id = input.note_id.unwrap_or(ID_PLACEHOLDER + input.card_id);
        let deck_id = input.deck_id.unwrap_or(ID_PLACEHOLDER);
        let preset_id = input.preset_id.unwrap_or(ID_PLACEHOLDER);
        features.extend([
            if input.note_id.is_none() { 1.0 } else { 0.0 },
            if input.deck_id.is_none() { 1.0 } else { 0.0 },
            if input.preset_id.is_none() { 1.0 } else { 0.0 },
            scale_day_offset_diff(day_offset - previous_day_offset),
            ((day_offset.rem_euclid(7) as f32) - 3.0) / 3.0,
            scale_diff_new_cards(diff_new_cards),
            scale_diff_reviews(diff_reviews),
            scale_cum_new_cards_today(today_new_cards),
            scale_cum_reviews_today(today_reviews),
            if input.is_query {
                0.0
            } else {
                scale_state(input.card_type.unwrap_or(0))
            },
            if input.is_query { 1.0 } else { 0.0 },
        ]);

        self.append_id_encoding(&mut features, IdKind::Card, input.card_id);
        self.append_id_encoding(&mut features, IdKind::Note, note_id);
        self.append_id_encoding(&mut features, IdKind::Deck, deck_id);
        self.append_id_encoding(&mut features, IdKind::Preset, preset_id);
        append_day_offset_encoding(&mut features, day_offset, day_offset_first);
        debug_assert_eq!(features.len(), CARD_FEATURES);
        features
    }

    fn store_review(&mut self, input: &ReviewInput) {
        let elapsed_seconds = elapsed_seconds(input);
        let elapsed_days = elapsed_days(input, elapsed_seconds);
        *self
            .card_elapsed_days_cumulative
            .entry(input.card_id)
            .or_default() += elapsed_days;
        *self
            .card_elapsed_seconds_cumulative
            .entry(input.card_id)
            .or_default() += elapsed_seconds;

        let raw_day_offset = input.day_offset.unwrap_or(0);
        let day_offset = self
            .first_day_offset
            .map_or(0, |first_day_offset| raw_day_offset - first_day_offset);
        if self.first_day_offset.is_none() {
            self.first_day_offset = Some(raw_day_offset);
        }

        if day_offset != self.today {
            self.today = day_offset;
            self.today_new_cards = 0;
            self.today_reviews = -1;
        }
        self.today_reviews += 1;
        if !self.card_set.contains_key(&input.card_id) {
            self.today_new_cards += 1;
            self.card_set.insert(input.card_id, ());
            self.card_first_day_offset.insert(input.card_id, day_offset);
        }

        self.previous_day_offset = Some(day_offset);
        self.last_i.insert(input.card_id, self.review_index);
        self.last_new_cards
            .insert(input.card_id, self.card_set.len() as i64);
        self.review_index += 1;
    }

    /// Fushi: runs `f` on this state as if `input` had been replayed
    /// ([Self::store_review]), then puts back everything that call changed
    /// (ID codes `f` assigns stay, as after any query).
    fn with_hypothetical_review<R>(&mut self, input: &ReviewInput, f: impl FnOnce(&mut Self) -> R) -> R {
        let card = input.card_id;
        let scalars = (
            self.first_day_offset,
            self.previous_day_offset,
            self.today,
            self.today_reviews,
            self.today_new_cards,
            self.review_index,
        );
        let seen = self.card_set.contains_key(&card);
        let per_card = [
            self.last_new_cards.get(&card).copied(),
            self.last_i.get(&card).copied(),
            self.card_first_day_offset.get(&card).copied(),
            self.card_elapsed_days_cumulative.get(&card).copied(),
            self.card_elapsed_seconds_cumulative.get(&card).copied(),
        ];
        self.store_review(input);
        let result = f(self);
        (
            self.first_day_offset,
            self.previous_day_offset,
            self.today,
            self.today_reviews,
            self.today_new_cards,
            self.review_index,
        ) = scalars;
        if !seen {
            self.card_set.remove(&card);
        }
        let maps = [
            &mut self.last_new_cards,
            &mut self.last_i,
            &mut self.card_first_day_offset,
            &mut self.card_elapsed_days_cumulative,
            &mut self.card_elapsed_seconds_cumulative,
        ];
        for (map, value) in maps.into_iter().zip(per_card) {
            match value {
                Some(value) => {
                    map.insert(card, value);
                }
                None => {
                    map.remove(&card);
                }
            }
        }
        result
    }

    /// Fushi: what [Self::features_for] + [Self::store_review] of `input` is
    /// about to change, so [Self::rewind] can put it back (the undo journal).
    fn checkpoint(&self, input: &ReviewInput) -> FeatureUndo {
        let card = input.card_id;
        let ids = [
            (IdKind::Card, card),
            (IdKind::Note, input.note_id.unwrap_or(ID_PLACEHOLDER + card)),
            (IdKind::Deck, input.deck_id.unwrap_or(ID_PLACEHOLDER)),
            (IdKind::Preset, input.preset_id.unwrap_or(ID_PLACEHOLDER)),
        ];
        let new_ids: Vec<(IdKind, i64)> = ids
            .into_iter()
            .filter(|key| !self.id_encodings.contains_key(key))
            .collect();
        FeatureUndo {
            card,
            scalars: (
                self.first_day_offset,
                self.previous_day_offset,
                self.today,
                self.today_reviews,
                self.today_new_cards,
                self.review_index,
            ),
            seen: self.card_set.contains_key(&card),
            per_card: [
                self.last_new_cards.get(&card).copied(),
                self.last_i.get(&card).copied(),
                self.card_first_day_offset.get(&card).copied(),
                self.card_elapsed_days_cumulative.get(&card).copied(),
                self.card_elapsed_seconds_cumulative.get(&card).copied(),
            ],
            rng_before: (!new_ids.is_empty()).then(|| self.id_rng.clone()),
            rng_after: None,
            new_ids,
        }
    }

    /// Fushi: called right after the journaled review was stored; records
    /// where the ID code stream stood then.
    fn seal(&self, undo: &mut FeatureUndo) {
        if undo.rng_before.is_some() {
            undo.rng_after = Some(self.id_rng.clone());
        }
    }

    /// Fushi: puts back what [Self::checkpoint] recorded. The ID codes the
    /// review drew are taken back only when nothing drew codes after it
    /// (a later query of a first-seen entity keeps its codes and the stream
    /// position, so no two entities ever share a code).
    fn rewind(&mut self, undo: FeatureUndo) {
        let card = undo.card;
        (
            self.first_day_offset,
            self.previous_day_offset,
            self.today,
            self.today_reviews,
            self.today_new_cards,
            self.review_index,
        ) = undo.scalars;
        if !undo.seen {
            self.card_set.remove(&card);
        }
        let maps = [
            &mut self.last_new_cards,
            &mut self.last_i,
            &mut self.card_first_day_offset,
            &mut self.card_elapsed_days_cumulative,
            &mut self.card_elapsed_seconds_cumulative,
        ];
        for (map, value) in maps.into_iter().zip(undo.per_card) {
            match value {
                Some(value) => {
                    map.insert(card, value);
                }
                None => {
                    map.remove(&card);
                }
            }
        }
        if let (Some(before), Some(after)) = (undo.rng_before, undo.rng_after) {
            if self.id_rng.same_position(&after) {
                for key in &undo.new_ids {
                    self.id_encodings.remove(key);
                }
                self.id_rng = before;
            }
        }
    }

    fn append_id_encoding(&mut self, features: &mut Vec<f32>, kind: IdKind, value: i64) {
        let encoding = self.id_encodings.entry((kind, value)).or_insert_with(|| {
            let dim = id_encoding_dim(kind);
            self.id_rng.encoding(dim)
        });
        features.extend(encoding.iter().copied());
    }

    fn cache_state_len(&self) -> usize {
        state_cache_optional_i64_len(self.first_day_offset)
            + state_cache_optional_i64_len(self.previous_day_offset)
            + state_cache_i64_set_len(self.card_set.len())
            + state_cache_i64_map_len(self.last_new_cards.len())
            + state_cache_i64_map_len(self.last_i.len())
            + 3 * 8
            + state_cache_i64_map_len(self.card_first_day_offset.len())
            + state_cache_i64_map_len(self.card_elapsed_days_cumulative.len())
            + state_cache_i64_map_len(self.card_elapsed_seconds_cumulative.len())
            + 8
            + state_cache_id_encodings_len(&self.id_encodings)
            + self.id_rng.cache_state_len()
    }

    fn write_cache_state_to(&self, out: &mut impl io::Write) -> io::Result<()> {
        write_state_cache_optional_i64(out, self.first_day_offset)?;
        write_state_cache_optional_i64(out, self.previous_day_offset)?;
        write_state_cache_i64_set(out, self.card_set.keys().copied())?;
        write_state_cache_i64_map(out, &self.last_new_cards)?;
        write_state_cache_i64_map(out, &self.last_i)?;
        out.write_all(&self.today.to_le_bytes())?;
        out.write_all(&self.today_reviews.to_le_bytes())?;
        out.write_all(&self.today_new_cards.to_le_bytes())?;
        write_state_cache_i64_map(out, &self.card_first_day_offset)?;
        write_state_cache_i64_map(out, &self.card_elapsed_days_cumulative)?;
        write_state_cache_i64_map(out, &self.card_elapsed_seconds_cumulative)?;
        out.write_all(&self.review_index.to_le_bytes())?;
        write_state_cache_id_encodings(out, &self.id_encodings)?;
        self.id_rng.write_cache_state_to(out)
    }

    fn read_cache_state(cursor: &mut Cursor<'_>) -> io::Result<Self> {
        Ok(Self {
            first_day_offset: cursor.option_i64()?,
            previous_day_offset: cursor.option_i64()?,
            card_set: read_i64_set(cursor)?,
            last_new_cards: read_i64_map(cursor)?,
            last_i: read_i64_map(cursor)?,
            today: cursor.i64()?,
            today_reviews: cursor.i64()?,
            today_new_cards: cursor.i64()?,
            card_first_day_offset: read_i64_map(cursor)?,
            card_elapsed_days_cumulative: read_i64_map(cursor)?,
            card_elapsed_seconds_cumulative: read_i64_map(cursor)?,
            review_index: cursor.i64()?,
            id_encodings: read_id_encodings(cursor)?,
            id_rng: TorchIdRng::read_cache_state(cursor)?,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum IdKind {
    Card,
    Note,
    Deck,
    Preset,
}

fn id_encoding_dim(kind: IdKind) -> usize {
    match kind {
        IdKind::Card | IdKind::Note => 12,
        IdKind::Deck | IdKind::Preset => 8,
    }
}

fn read_id_encodings(cursor: &mut Cursor<'_>) -> io::Result<HashMap<(IdKind, i64), Vec<f32>>> {
    let count = cursor.count(13)?; // kind + id + vector length
    let mut values = HashMap::with_capacity(count);
    for _ in 0..count {
        let kind = IdKind::from_cache_code(cursor.u8()?)?;
        let value = cursor.i64()?;
        let encoding = cursor.f32_vec()?;
        if encoding.len() != id_encoding_dim(kind) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "damaged RWKV id encoding",
            ));
        }
        values.insert((kind, value), encoding);
    }
    Ok(values)
}

impl IdKind {
    fn cache_code(self) -> u8 {
        match self {
            IdKind::Card => 0,
            IdKind::Note => 1,
            IdKind::Deck => 2,
            IdKind::Preset => 3,
        }
    }

    fn from_cache_code(code: u8) -> io::Result<Self> {
        match code {
            0 => Ok(IdKind::Card),
            1 => Ok(IdKind::Note),
            2 => Ok(IdKind::Deck),
            3 => Ok(IdKind::Preset),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid RWKV id kind",
            )),
        }
    }
}

#[derive(Clone)]
struct TorchIdRng {
    state: [u32; TORCH_ID_RNG_STATE_LEN],
    index: usize,
}

impl Default for TorchIdRng {
    fn default() -> Self {
        Self {
            state: TORCH_ID_RNG_INITIAL_STATE,
            index: TORCH_ID_RNG_INITIAL_INDEX,
        }
    }
}

impl TorchIdRng {
    /// Fushi: the stream is where `other` left it (no codes drawn since).
    fn same_position(&self, other: &Self) -> bool {
        self.index == other.index && self.state == other.state
    }

    fn encoding(&mut self, dim: usize) -> Vec<f32> {
        (0..dim)
            .map(|_| (self.next_u32() as u64 % ID_SPLIT) as f32 - ((ID_SPLIT - 1) as f32 / 2.0))
            .collect()
    }

    fn next_u32(&mut self) -> u32 {
        if self.index >= TORCH_ID_RNG_STATE_LEN {
            self.twist();
        }
        let mut value = self.state[self.index];
        self.index += 1;
        value ^= value >> 11;
        value ^= (value << 7) & 0x9d2c_5680;
        value ^= (value << 15) & 0xefc6_0000;
        value ^ (value >> 18)
    }

    fn twist(&mut self) {
        const UPPER_MASK: u32 = 0x8000_0000;
        const LOWER_MASK: u32 = 0x7fff_ffff;
        const MATRIX_A: u32 = 0x9908_b0df;

        for index in 0..TORCH_ID_RNG_STATE_LEN {
            let next = (index + 1) % TORCH_ID_RNG_STATE_LEN;
            let twist = (self.state[index] & UPPER_MASK) | (self.state[next] & LOWER_MASK);
            let mut value = self.state[(index + 397) % TORCH_ID_RNG_STATE_LEN] ^ (twist >> 1);
            if twist & 1 != 0 {
                value ^= MATRIX_A;
            }
            self.state[index] = value;
        }
        self.index = 0;
    }

    fn cache_state_len(&self) -> usize {
        4 + 4 * self.state.len()
    }

    fn write_cache_state_to(&self, out: &mut impl io::Write) -> io::Result<()> {
        write_state_cache_u32(out, self.index)?;
        for value in self.state {
            out.write_all(&value.to_le_bytes())?;
        }
        Ok(())
    }

    fn read_cache_state(cursor: &mut Cursor<'_>) -> io::Result<Self> {
        let index = cursor.u32()? as usize;
        if index > TORCH_ID_RNG_STATE_LEN {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid RWKV id RNG index",
            ));
        }
        let mut state = [0; TORCH_ID_RNG_STATE_LEN];
        for value in &mut state {
            *value = cursor.u32()?;
        }
        Ok(Self { state, index })
    }
}

fn append_day_offset_encoding(features: &mut Vec<f32>, day_offset: i64, first_day_offset: i64) {
    for period in DAY_OFFSET_ENCODE_PERIODS {
        let phase = 2.0 * std::f32::consts::PI / period;
        let day = day_offset.rem_euclid(period as i64) as f32;
        let first_day = first_day_offset.rem_euclid(period as i64) as f32;
        features.push((phase * day).sin());
        features.push((phase * day).cos());
        features.push((phase * first_day).sin());
        features.push((phase * first_day).cos());
    }
}

/// R of a 128-curve mixture (`ReviewCurve::weights`) `elapsed_seconds` after
/// the answer. Verbatim upstream (`predict_curve`, which ignores the ahead
/// logits); non-increasing in `elapsed_seconds`.
pub fn predict_curve(weights: &[f32], elapsed_seconds: f32) -> f32 {
    let elapsed_seconds = elapsed_seconds.max(1.0);
    let mut raw_probability = 0.0;
    for (index, weight) in weights.iter().enumerate() {
        let s_space_raw = linspace_exp(index, NUM_CURVES, 18.5);
        let s_space = 0.1 + (s_space_raw - 1.0) * (22.0_f32 - 18.5).exp();
        raw_probability += weight * 0.9_f32.powf(elapsed_seconds / s_space);
    }
    1e-5 + (1.0 - 2e-5) * raw_probability
}

fn linspace_exp(index: usize, count: usize, point_spread: f32) -> f32 {
    let value = if count <= 1 {
        0.0
    } else {
        point_spread * index as f32 / (count - 1) as f32
    };
    value.exp()
}

/// Fushi: the query for `answer`'s card `days` scheduling days and `seconds`
/// seconds after it (the same ids, elapsed since that answer).
pub fn forecast_query(answer: &ReviewInput, days: i64, seconds: i64) -> ReviewInput {
    ReviewInput {
        is_query: true,
        ease: None,
        duration_millis: None,
        card_type: Some(2),
        day_offset: answer.day_offset.map(|day| day + days),
        current_elapsed_days: Some(days),
        current_elapsed_seconds: Some(seconds),
        ..answer.clone()
    }
}

fn elapsed_seconds(input: &ReviewInput) -> i64 {
    if creation_elapsed_is_query_only(input) {
        return -1;
    }
    input
        .current_elapsed_seconds
        .or_else(|| {
            input
                .current_elapsed_days
                .map(|days| days * SECONDS_PER_DAY)
        })
        .unwrap_or(-1)
}

fn elapsed_days(input: &ReviewInput, elapsed_seconds: i64) -> i64 {
    if creation_elapsed_is_query_only(input) {
        return -1;
    }
    input.current_elapsed_days.unwrap_or({
        if elapsed_seconds >= 0 {
            elapsed_seconds / SECONDS_PER_DAY
        } else {
            -1
        }
    })
}

fn creation_elapsed_is_query_only(input: &ReviewInput) -> bool {
    !input.is_query && input.ease.is_some() && input.card_type == Some(0)
}

fn scaled_duration(input: &ReviewInput) -> f32 {
    input
        .duration_millis
        .map_or(0.0, |millis| scale_duration(millis as f32))
}

fn scale_elapsed_days(x: i64) -> f32 {
    (log_elapsed(x) - ELAPSED_DAYS_MEAN) / ELAPSED_DAYS_STD
}

fn scale_elapsed_days_cumulative(x: i64) -> f32 {
    (log_elapsed(x) - ELAPSED_DAYS_CUMULATIVE_MEAN) / ELAPSED_DAYS_CUMULATIVE_STD
}

fn scale_elapsed_seconds(x: i64) -> f32 {
    (log_elapsed(x) - ELAPSED_SECONDS_MEAN) / ELAPSED_SECONDS_STD
}

fn scale_elapsed_seconds_cumulative(x: i64) -> f32 {
    (log_elapsed(x) - ELAPSED_SECONDS_CUMULATIVE_MEAN) / ELAPSED_SECONDS_CUMULATIVE_STD
}

fn scale_duration(x: f32) -> f32 {
    ((10.0 + x).ln() - DURATION_MEAN) / DURATION_STD
}

fn scale_diff_new_cards(x: i64) -> f32 {
    ((3.0 + x as f32).ln() - DIFF_NEW_CARDS_MEAN) / DIFF_NEW_CARDS_STD
}

fn scale_diff_reviews(x: i64) -> f32 {
    ((3.0 + x as f32).ln() - DIFF_REVIEWS_MEAN) / DIFF_REVIEWS_STD
}

fn scale_cum_new_cards_today(x: i64) -> f32 {
    ((3.0 + x as f32).ln() - CUM_NEW_CARDS_TODAY_MEAN) / CUM_NEW_CARDS_TODAY_STD
}

fn scale_cum_reviews_today(x: i64) -> f32 {
    ((3.0 + x as f32).ln() - CUM_REVIEWS_TODAY_MEAN) / CUM_REVIEWS_TODAY_STD
}

fn scale_state(x: i64) -> f32 {
    x as f32 - 2.0
}

fn scale_day_offset_diff(x: i64) -> f32 {
    (std::f32::consts::E + x as f32).ln().ln()
}

fn log_elapsed(x: i64) -> f32 {
    if x == -1 {
        0.0
    } else {
        (1.0 + 1e-5 + x as f32).ln()
    }
}

fn cyclic_sin(value: i64, period: i64) -> f32 {
    ((value.rem_euclid(period) as f32) * 2.0 * std::f32::consts::PI / period as f32).sin()
}

fn cyclic_cos(value: i64, period: i64) -> f32 {
    ((value.rem_euclid(period) as f32) * 2.0 * std::f32::consts::PI / period as f32).cos()
}

struct WeightMap {
    tensors: HashMap<String, Tensor>,
}

struct Tensor {
    shape: Vec<usize>,
    values: Vec<f32>,
}

impl WeightMap {
    // Fushi: was `load(path)` reading the file first.
    fn from_bytes(data: &[u8]) -> io::Result<Self> {
        let mut cursor = Cursor::new(data);
        cursor.expect_magic(b"ARWKVWEIGHTS1")?;
        let count = cursor.u32()? as usize;
        let mut tensors = HashMap::with_capacity(count);

        for _ in 0..count {
            let name_len = cursor.u16()? as usize;
            let name = cursor.string(name_len)?;
            let rank = cursor.u8()? as usize;
            let mut shape = Vec::with_capacity(rank);
            let mut len = 1_usize;
            for _ in 0..rank {
                let dim = cursor.u32()? as usize;
                len = len.checked_mul(dim).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "tensor is too large")
                })?;
                shape.push(dim);
            }
            let mut values = Vec::with_capacity(len);
            for _ in 0..len {
                values.push(cursor.f32()?);
            }
            tensors.insert(name, Tensor { shape, values });
        }

        cursor.expect_end()?;
        Ok(Self { tensors })
    }

    fn values(&self, name: &str) -> io::Result<Vec<f32>> {
        self.tensors
            .get(name)
            .map(|tensor| tensor.values.clone())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, missing_weight(name)))
    }

    fn linear(&self, name: &str, input: usize, output: usize, bias: bool) -> io::Result<Linear> {
        let weight_name = format!("{name}.weight");
        let bias_name = format!("{name}.bias");
        let weight = &self.tensor(&weight_name, &[output, input])?.values;
        let mut weight_by_input = vec![0.0; weight.len()];
        for row in 0..output {
            for column in 0..input {
                weight_by_input[column * output + row] = weight[row * input + column];
            }
        }
        let bias = if bias {
            Some(self.tensor(&bias_name, &[output])?.values.clone())
        } else {
            None
        };
        Ok(Linear {
            input,
            output,
            weight_by_input,
            bias,
        })
    }

    fn layer_norm(&self, name: &str, dim: usize, eps: f32) -> io::Result<Norm> {
        Ok(Norm {
            groups: 1,
            dim,
            eps,
            weight: self
                .tensor(&format!("{name}.weight"), &[dim])?
                .values
                .clone(),
            bias: self.tensor(&format!("{name}.bias"), &[dim])?.values.clone(),
        })
    }

    fn group_norm(&self, name: &str, groups: usize, dim: usize, eps: f32) -> io::Result<Norm> {
        Ok(Norm {
            groups,
            dim,
            eps,
            weight: self
                .tensor(&format!("{name}.weight"), &[dim])?
                .values
                .clone(),
            bias: self.tensor(&format!("{name}.bias"), &[dim])?.values.clone(),
        })
    }

    fn tensor(&self, name: &str, shape: &[usize]) -> io::Result<&Tensor> {
        let tensor = self
            .tensors
            .get(name)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, missing_weight(name)))?;
        if tensor.shape != shape {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "weight {name} has shape {:?}, expected {shape:?}",
                    tensor.shape
                ),
            ));
        }
        Ok(tensor)
    }
}

fn missing_weight(name: &str) -> String {
    format!("missing weight: {name}")
}

/// Shared decoder for byte snapshots and buffered files. Its scratch buffer
/// holds at most one serialized state or the feature cache, never the full file.
struct SnapshotReader<'a, R> {
    input: &'a mut R,
    remaining: u64,
    scratch: Vec<u8>,
}

impl<'a, R: io::Read> SnapshotReader<'a, R> {
    fn new(input: &'a mut R, len: u64) -> Self {
        Self { input, remaining: len, scratch: Vec::new() }
    }

    fn bytes(&mut self, len: usize) -> io::Result<&[u8]> {
        if len as u64 > self.remaining {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "snapshot ended early"));
        }
        self.scratch.resize(len, 0);
        self.input.read_exact(&mut self.scratch)?;
        self.remaining -= len as u64;
        Ok(&self.scratch)
    }

    fn expect_magic(&mut self, magic: &[u8]) -> io::Result<()> {
        if self.bytes(magic.len())? != magic {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "unexpected file magic"));
        }
        Ok(())
    }

    fn u8(&mut self) -> io::Result<u8> {
        Ok(self.bytes(1)?[0])
    }

    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }

    fn i64(&mut self) -> io::Result<i64> {
        Ok(i64::from_le_bytes(self.bytes(8)?.try_into().unwrap()))
    }

    fn count(&mut self, entry_bytes: usize) -> io::Result<usize> {
        let count = self.u32()? as usize;
        if count as u64 > self.remaining / entry_bytes as u64 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "count larger than the data"));
        }
        Ok(count)
    }

    fn expect_end(&mut self) -> io::Result<()> {
        let mut trailing = [0];
        if self.remaining != 0 || self.input.read(&mut trailing)? != 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing bytes in file"));
        }
        Ok(())
    }
}

struct Cursor<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    fn expect_magic(&mut self, magic: &[u8]) -> io::Result<()> {
        let found = self.bytes(magic.len())?;
        if found != magic {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unexpected file magic",
            ));
        }
        Ok(())
    }

    fn expect_end(&self) -> io::Result<()> {
        if self.offset == self.data.len() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "trailing bytes in file",
            ))
        }
    }

    /// A count read from the data, refused when that many entries of at least
    /// `entry_bytes` can't fit in what is left: a damaged count would otherwise
    /// reserve gigabytes up front and abort the app.
    fn count(&mut self, entry_bytes: usize) -> io::Result<usize> {
        let count = self.u32()? as usize;
        if count.saturating_mul(entry_bytes) > self.data.len() - self.offset {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "count larger than the data",
            ));
        }
        Ok(count)
    }

    fn bytes(&mut self, len: usize) -> io::Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "offset overflow"))?;
        let bytes = self
            .data
            .get(self.offset..end)
            .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "file ended early"))?;
        self.offset = end;
        Ok(bytes)
    }

    fn string(&mut self, len: usize) -> io::Result<String> {
        let bytes = self.bytes(len)?;
        String::from_utf8(bytes.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid utf-8 string"))
    }

    fn u8(&mut self) -> io::Result<u8> {
        Ok(self.bytes(1)?[0])
    }

    fn u16(&mut self) -> io::Result<u16> {
        let mut bytes = [0; 2];
        bytes.copy_from_slice(self.bytes(2)?);
        Ok(u16::from_le_bytes(bytes))
    }

    fn u32(&mut self) -> io::Result<u32> {
        let mut bytes = [0; 4];
        bytes.copy_from_slice(self.bytes(4)?);
        Ok(u32::from_le_bytes(bytes))
    }

    fn i64(&mut self) -> io::Result<i64> {
        let mut bytes = [0; 8];
        bytes.copy_from_slice(self.bytes(8)?);
        Ok(i64::from_le_bytes(bytes))
    }

    fn option_i64(&mut self) -> io::Result<Option<i64>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.i64()?)),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid optional i64 tag",
            )),
        }
    }

    fn f32(&mut self) -> io::Result<f32> {
        let mut bytes = [0; 4];
        bytes.copy_from_slice(self.bytes(4)?);
        Ok(f32::from_le_bytes(bytes))
    }

    fn f32_vec(&mut self) -> io::Result<Vec<f32>> {
        let byte_len = (self.u32()? as usize)
            .checked_mul(std::mem::size_of::<f32>())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "vector too large"))?;
        // Bounds-check once, then convert in bulk: about 2.5x faster than
        // decoding element by element on the state-restore path.
        Ok(self
            .bytes(byte_len)?
            .chunks_exact(std::mem::size_of::<f32>())
            .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
            .collect())
    }

    fn skip_f32_vec(&mut self) -> io::Result<()> {
        let byte_len = (self.u32()? as usize)
            .checked_mul(std::mem::size_of::<f32>())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "vector too large"))?;
        self.bytes(byte_len)?;
        Ok(())
    }
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct SrsModel {
    features_0: Linear,
    features_norm: Norm,
    features_3: Linear,
    modules: Vec<RwkvModule>,
    prehead_norm: Norm,
    head_w_0: Linear,
    head_w_norm: Norm,
    head_w_4: Linear,
    w_linear: Linear,
    head_ahead_0: Linear,
    ahead_linear: Linear,
    head_p_0: Linear,
    p_linear: Linear,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
struct ReviewRetrievabilityScratch {
    feature_hidden: [f32; HEAD_DIM],
    normalized_features: [f32; HEAD_DIM],
    module: ModuleQueryScratch,
    prehead: [f32; D_MODEL],
    head: [f32; HEAD_DIM],
    logits: [f32; 4],
    probabilities: [f32; 4],
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
#[derive(Default)]
struct ReviewRetrievabilityBatchScratch {
    feature_input: Vec<f32>,
    feature_hidden: Vec<f32>,
    normalized_features: Vec<f32>,
    x: Vec<f32>,
    module: ModuleQueryBatchScratch,
    prehead: Vec<f32>,
    head: Vec<f32>,
    logits: Vec<f32>,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
impl Default for ReviewRetrievabilityScratch {
    fn default() -> Self {
        Self {
            feature_hidden: [0.0; HEAD_DIM],
            normalized_features: [0.0; HEAD_DIM],
            module: ModuleQueryScratch::default(),
            prehead: [0.0; D_MODEL],
            head: [0.0; HEAD_DIM],
            logits: [0.0; 4],
            probabilities: [0.0; 4],
        }
    }
}

impl SrsModel {
    // Fushi: was `load(path)`.
    fn from_weight_bytes(bytes: &[u8]) -> io::Result<Self> {
        let weights = WeightMap::from_bytes(bytes)?;
        let modules = MODULE_LAYERS
            .iter()
            .enumerate()
            .map(|(module_id, layer_count)| RwkvModule::load(&weights, module_id, *layer_count))
            .collect::<io::Result<Vec<_>>>()?;

        Ok(Self {
            features_0: weights.linear("features2card.0", CARD_FEATURES, HEAD_DIM, true)?,
            features_norm: weights.layer_norm("features2card.2", HEAD_DIM, 1e-5)?,
            features_3: weights.linear("features2card.3", HEAD_DIM, D_MODEL, true)?,
            modules,
            prehead_norm: weights.layer_norm("prehead_norm", D_MODEL, 1e-5)?,
            head_w_0: weights.linear("head_w.0", D_MODEL, D_MODEL, true)?,
            head_w_norm: weights.layer_norm("head_w.2", D_MODEL, 1e-5)?,
            head_w_4: weights.linear("head_w.4", D_MODEL, HEAD_DIM, true)?,
            w_linear: weights.linear("w_linear", HEAD_DIM, NUM_CURVES, true)?,
            head_ahead_0: weights.linear("head_ahead_logits.0", D_MODEL, HEAD_DIM, true)?,
            ahead_linear: weights.linear("ahead_linear", HEAD_DIM, NUM_CURVES, true)?,
            head_p_0: weights.linear("head_p.0", D_MODEL, HEAD_DIM, true)?,
            p_linear: weights.linear("p_linear", HEAD_DIM, 4, true)?,
        })
    }

    fn review(&self, features: &[f32], state: SrsStateRef<'_>) -> ReviewHeads {
        self.review_features(features, state)
    }

    fn review_retrievability_query_refs(&self, items: &[ReviewPredictionQueryRef<'_>]) -> Vec<f32> {
        #[cfg(all(any(target_os = "macos", target_arch = "aarch64"), not(test)))]
        {
            self.review_retrievability_query_refs_batched(items)
        }

        #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
        {
            self.review_retrievability_query_refs_scalar(items)
        }
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn review_retrievability_query_refs_scalar(
        &self,
        items: &[ReviewPredictionQueryRef<'_>],
    ) -> Vec<f32> {
        items
            .par_iter()
            .map_init(
                // Keep the large per-worker scratch off Rayon's limited worker stacks.
                || Box::new(ReviewRetrievabilityScratch::default()),
                |scratch, item| {
                    self.review_retrievability_features(item.features, item.state, scratch)
                },
            )
            .collect()
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn review_retrievability_query_refs_batched(
        &self,
        items: &[ReviewPredictionQueryRef<'_>],
    ) -> Vec<f32> {
        let mut retrievabilities = vec![0.0; items.len()];
        retrievabilities
            .par_chunks_mut(RETRIEVABILITY_GEMM_BATCH_SIZE)
            .zip(items.par_chunks(RETRIEVABILITY_GEMM_BATCH_SIZE))
            .for_each_init(
                ReviewRetrievabilityBatchScratch::default,
                |scratch, (retrievabilities, items)| {
                    self.review_retrievability_query_batch(items, scratch, retrievabilities);
                },
            );
        retrievabilities
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn review_retrievability_query_batch(
        &self,
        items: &[ReviewPredictionQueryRef<'_>],
        scratch: &mut ReviewRetrievabilityBatchScratch,
        retrievabilities: &mut [f32],
    ) {
        let rows = items.len();
        scratch.feature_input.clear();
        scratch.feature_input.reserve(rows * CARD_FEATURES);
        for item in items {
            scratch.feature_input.extend_from_slice(item.features);
        }

        self.features_0
            .apply_batch(&scratch.feature_input, rows, &mut scratch.feature_hidden);
        query_silu_batch_in_place(&mut scratch.feature_hidden);
        self.features_norm.apply_batch(
            &scratch.feature_hidden,
            rows,
            &mut scratch.normalized_features,
        );
        self.features_3
            .apply_batch(&scratch.normalized_features, rows, &mut scratch.x);
        query_silu_batch_in_place(&mut scratch.x);

        for (module_id, module) in self.modules.iter().enumerate() {
            module.run_query_batch(&mut scratch.x, items, module_id, &mut scratch.module);
        }

        self.prehead_norm
            .apply_batch(&scratch.x, rows, &mut scratch.prehead);
        self.head_p_0
            .apply_batch(&scratch.prehead, rows, &mut scratch.head);
        relu_in_place(&mut scratch.head);
        self.p_linear
            .apply_batch(&scratch.head, rows, &mut scratch.logits);
        for (retrievability, logits) in retrievabilities
            .iter_mut()
            .zip(scratch.logits.chunks_exact(4))
        {
            let mut probabilities = [0.0; 4];
            softmax_into(logits, &mut probabilities);
            *retrievability = 1.0 - probabilities[0];
        }
    }

    /// The feature MLP shared by the per-review and bulk replay paths.
    fn feature_mlp(&self, features: &[f32]) -> Vec<f32> {
        let mut x = self.features_0.apply(features);
        silu_in_place(&mut x);
        x = self.features_norm.apply(&x);
        x = self.features_3.apply(&x);
        silu_in_place(&mut x);
        x
    }

    /// The recall-curve heads shared by the per-review and bulk replay paths.
    /// `prehead_x` must already have `prehead_norm` applied.
    fn curve_head(&self, prehead_x: &[f32]) -> ReviewCurve {
        let mut head_w = self.head_w_0.apply(prehead_x);
        relu_in_place(&mut head_w);
        head_w = self.head_w_norm.apply(&head_w);
        head_w = self.head_w_4.apply(&head_w);
        let weights = softmax(&self.w_linear.apply(&head_w));

        let mut ahead = self.head_ahead_0.apply(prehead_x);
        relu_in_place(&mut ahead);
        let ahead_logits = self.ahead_linear.apply(&ahead);

        ReviewCurve {
            ahead_logits,
            weights,
        }
    }

    /// The retrievability head shared by the per-review and bulk replay
    /// paths. `prehead_x` must already have `prehead_norm` applied.
    fn button_probabilities_head(&self, prehead_x: &[f32]) -> [f32; 4] {
        let mut head_p = self.head_p_0.apply(prehead_x);
        relu_in_place(&mut head_p);
        let logits = self.p_linear.apply(&head_p);
        let probabilities = softmax(&logits);
        let mut out = [0.0; 4];
        out.copy_from_slice(&probabilities);
        out
    }

    fn retrievability_head(&self, prehead_x: &[f32]) -> f32 {
        1.0 - self.button_probabilities_head(prehead_x)[0]
    }

    fn review_features(&self, features: &[f32], state: SrsStateRef<'_>) -> ReviewHeads {
        let x = self.feature_mlp(features);

        let (x, card_state) = self.modules[0].run(&x, state.card);
        let (x, deck_state) = self.modules[1].run(&x, state.deck);
        let (x, note_state) = self.modules[2].run(&x, state.note);
        let (x, preset_state) = self.modules[3].run(&x, state.preset);
        let (x, global_state) = self.modules[4].run(&x, state.global);

        let x = self.prehead_norm.apply(&x);
        let curve = self.curve_head(&x);
        let button_probabilities = self.button_probabilities_head(&x);
        let retrievability = 1.0 - button_probabilities[0];

        let next_state = SrsState {
            card: card_state,
            deck: deck_state,
            note: note_state,
            preset: preset_state,
            global: global_state,
        };

        let heads = ReviewHeads {
            retrievability,
            button_probabilities,
            curve,
            next_state,
        };
        heads
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn review_retrievability_features(
        &self,
        features: &[f32],
        state: SrsStateRef<'_>,
        scratch: &mut ReviewRetrievabilityScratch,
    ) -> f32 {
        self.features_0
            .apply_into(features, &mut scratch.feature_hidden);
        silu_in_place(&mut scratch.feature_hidden);
        self.features_norm
            .apply_into(&scratch.feature_hidden, &mut scratch.normalized_features);
        let mut x = [0.0; D_MODEL];
        self.features_3
            .apply_into(&scratch.normalized_features, &mut x);
        silu_in_place(&mut x);

        let states = [
            state.card,
            state.deck,
            state.note,
            state.preset,
            state.global,
        ];
        for (module, state) in self.modules.iter().zip(states) {
            x = module.run_query(&x, state, &mut scratch.module);
        }

        self.prehead_norm.apply_into(&x, &mut scratch.prehead);
        self.head_p_0
            .apply_into(&scratch.prehead, &mut scratch.head);
        relu_in_place(&mut scratch.head);
        self.p_linear.apply_into(&scratch.head, &mut scratch.logits);
        softmax_into(&scratch.logits, &mut scratch.probabilities);
        1.0 - scratch.probabilities[0]
    }
}

// Fushi: only `next_state` is read (by the per-review reference replay); the
// heads are still computed exactly as upstream does.
#[allow(dead_code)]
struct ReviewHeads {
    retrievability: f32,
    button_probabilities: [f32; 4],
    curve: ReviewCurve,
    next_state: SrsState,
}

// The RWKV-Curve head output. Fushi schedules on `weights` (see
// [RwkvInference::answer_curves]); `ahead_logits` is computed as upstream does
// but, as upstream's `predict_curve`, never read.
#[derive(Clone)]
struct ReviewCurve {
    #[allow(dead_code)]
    ahead_logits: Vec<f32>,
    weights: Vec<f32>,
}

#[derive(Clone, Copy)]
struct SrsStateRef<'a> {
    card: Option<&'a ModuleState>,
    deck: Option<&'a ModuleState>,
    note: Option<&'a ModuleState>,
    preset: Option<&'a ModuleState>,
    global: Option<&'a ModuleState>,
}

impl<'a> SrsStateRef<'a> {
    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn module(self, module_id: usize) -> Option<&'a ModuleState> {
        match module_id {
            0 => self.card,
            1 => self.deck,
            2 => self.note,
            3 => self.preset,
            4 => self.global,
            _ => None,
        }
    }
}

/// [SrsStateRef] for states that may have been decoded for the query.
struct SrsStateView<'a> {
    card: Option<Cow<'a, ModuleState>>,
    note: Option<Cow<'a, ModuleState>>,
    deck: Option<&'a ModuleState>,
    preset: Option<&'a ModuleState>,
    global: Option<&'a ModuleState>,
}

impl SrsStateView<'_> {
    fn as_ref(&self) -> SrsStateRef<'_> {
        SrsStateRef {
            card: self.card.as_deref(),
            note: self.note.as_deref(),
            deck: self.deck,
            preset: self.preset,
            global: self.global,
        }
    }
}

struct SrsState {
    card: ModuleState,
    deck: ModuleState,
    note: ModuleState,
    preset: ModuleState,
    global: ModuleState,
}

#[derive(Default)]
struct ReviewStateMaps {
    card: SharedStateMap,
    note: SharedStateMap,
    deck: HashMap<i64, ModuleState>,
    preset: HashMap<i64, ModuleState>,
    global: Option<ModuleState>,
    // Fushi: no dirty sets; they fed the SQLite delta checkpoints.
}

impl ReviewStateMaps {
    /// The states `input` reads; card and note states are converted to f32.
    fn state_view(&self, input: &ReviewInput) -> SrsStateView<'_> {
        SrsStateView {
            card: self.card.state(&input.card_id),
            note: input.note_id.and_then(|id| self.note.state(&id)),
            deck: input.deck_id.and_then(|id| self.deck.get(&id)),
            preset: input.preset_id.and_then(|id| self.preset.get(&id)),
            global: self.global.as_ref(),
        }
    }

    fn store(&mut self, input: &ReviewInput, state: SrsState) {
        self.card.put(input.card_id, state.card);
        if let Some(note_id) = input.note_id {
            self.note.put(note_id, state.note);
        }
        if let Some(deck_id) = input.deck_id {
            self.deck.insert(deck_id, state.deck);
        }
        if let Some(preset_id) = input.preset_id {
            self.preset.insert(preset_id, state.preset);
        }
        self.global = Some(state.global);
    }
}

fn serialized_module_state_len(state: &ModuleState) -> usize {
    if let Some(packed) = &state.packed {
        return packed.len();
    }
    b"ARWKVMODSTATE1".len()
        + 4
        + state
            .layers
            .iter()
            .map(|layer| {
                12 + 4
                    * (layer.time.as_ref().map_or(0, |time| time.x_shift.len())
                        + layer.time.as_ref().map_or(0, |time| time.matrix.len())
                        + layer.channel_shift.as_ref().map_or(0, |shift| shift.len()))
            })
            .sum::<usize>()
}

fn write_serialized_module_state(out: &mut impl io::Write, state: &ModuleState) -> io::Result<()> {
    if let Some(packed) = &state.packed {
        return out.write_all(packed);
    }
    out.write_all(b"ARWKVMODSTATE1")?;
    write_snapshot_u32(out, state.layers.len())?;
    for layer in &state.layers {
        write_state_cache_f32_slice(
            out,
            layer
                .time
                .as_ref()
                .map_or(&[][..], |time| time.x_shift.as_slice()),
        )?;
        write_state_cache_f32_slice(
            out,
            layer
                .time
                .as_ref()
                .map_or(&[][..], |time| time.matrix.as_slice()),
        )?;
        write_state_cache_f32_slice(
            out,
            layer
                .channel_shift
                .as_ref()
                .map_or(&[][..], |shift| shift.as_slice()),
        )?;
    }
    Ok(())
}

fn write_snapshot_module_state(out: &mut impl io::Write, state: &ModuleState) -> io::Result<()> {
    write_snapshot_u32(out, serialized_module_state_len(state))?;
    write_serialized_module_state(out, state)
}

fn write_snapshot_state_map(out: &mut impl io::Write, states: &dyn StateMap) -> io::Result<()> {
    write_snapshot_u32(out, states.count())?;
    let mut identities = states.ids();
    identities.sort_unstable();
    for identity in identities {
        out.write_all(&identity.to_le_bytes())?;
        write_snapshot_module_state(out, &states.state(&identity).unwrap())?;
    }
    Ok(())
}

fn write_snapshot_u32(out: &mut impl io::Write, value: usize) -> io::Result<()> {
    let value = u32::try_from(value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "RWKV state is too large"))?;
    out.write_all(&value.to_le_bytes())
}

fn deserialize_module_state(bytes: Option<&[u8]>) -> io::Result<Option<ModuleState>> {
    let Some(bytes) = bytes else {
        return Ok(None);
    };
    if bytes.starts_with(precision::MAGIC) {
        // Validate before retaining an opaque packed state. Later inference can
        // decode it infallibly into bounded, short-lived scratch storage.
        precision::decode(bytes)?;
        return Ok(Some(ModuleState {
            layers: Vec::new(),
            packed: Some(bytes.to_vec()),
        }));
    }
    let mut cursor = Cursor::new(bytes);
    cursor.expect_magic(b"ARWKVMODSTATE1")?;
    let layer_count = cursor.u32()? as usize;
    if layer_count > MODULE_LAYERS.iter().copied().max().unwrap() {
        // Fushi: upstream returned its resident-state spill error here.
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid RWKV resident state spill",
        ));
    }
    let mut layers = Vec::with_capacity(layer_count);
    for _ in 0..layer_count {
        let x_shift = cursor.f32_vec()?;
        let matrix = cursor.f32_vec()?;
        let channel_shift = cursor.f32_vec()?;
        layers.push(LayerState {
            time: Some(TimeState {
                x_shift,
                matrix,
                packed_matrix: None,
            }),
            channel_shift: Some(channel_shift),
        });
    }
    cursor.expect_end()?;
    Ok(Some(ModuleState {
        layers,
        packed: None,
    }))
}

fn write_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn state_cache_optional_i64_len(value: Option<i64>) -> usize {
    if value.is_some() {
        9
    } else {
        1
    }
}

fn state_cache_i64_set_len(count: usize) -> usize {
    4 + 8 * count
}

fn state_cache_i64_map_len(count: usize) -> usize {
    4 + 16 * count
}

fn state_cache_id_encodings_len(values: &HashMap<(IdKind, i64), Vec<f32>>) -> usize {
    4 + values
        .values()
        .map(|encoding| 13 + 4 * encoding.len())
        .sum::<usize>()
}

fn write_state_cache_u32(out: &mut impl io::Write, value: usize) -> io::Result<()> {
    let value = u32::try_from(value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "RWKV state is too large"))?;
    out.write_all(&value.to_le_bytes())
}

fn write_state_cache_optional_i64(out: &mut impl io::Write, value: Option<i64>) -> io::Result<()> {
    match value {
        Some(value) => {
            out.write_all(&[1])?;
            out.write_all(&value.to_le_bytes())
        }
        None => out.write_all(&[0]),
    }
}

fn write_state_cache_i64_set(
    out: &mut impl io::Write,
    values: impl Iterator<Item = i64>,
) -> io::Result<()> {
    let mut values: Vec<_> = values.collect();
    values.sort_unstable();
    write_state_cache_u32(out, values.len())?;
    for value in values {
        out.write_all(&value.to_le_bytes())?;
    }
    Ok(())
}

fn read_i64_set(cursor: &mut Cursor<'_>) -> io::Result<HashMap<i64, ()>> {
    let count = cursor.count(8)?;
    let mut values = HashMap::with_capacity(count);
    for _ in 0..count {
        values.insert(cursor.i64()?, ());
    }
    Ok(values)
}

fn write_state_cache_i64_map(
    out: &mut impl io::Write,
    values: &HashMap<i64, i64>,
) -> io::Result<()> {
    let mut values: Vec<_> = values.iter().collect();
    values.sort_by_key(|(key, _)| *key);
    write_state_cache_u32(out, values.len())?;
    for (key, value) in values {
        out.write_all(&key.to_le_bytes())?;
        out.write_all(&value.to_le_bytes())?;
    }
    Ok(())
}

fn read_i64_map(cursor: &mut Cursor<'_>) -> io::Result<HashMap<i64, i64>> {
    let count = cursor.count(16)?;
    let mut values = HashMap::with_capacity(count);
    for _ in 0..count {
        values.insert(cursor.i64()?, cursor.i64()?);
    }
    Ok(values)
}

fn write_state_cache_f32_slice(out: &mut impl io::Write, values: &[f32]) -> io::Result<()> {
    write_state_cache_u32(out, values.len())?;
    let mut buffer = [0_u8; 8192];
    for values in values.chunks(buffer.len() / 4) {
        for (destination, value) in buffer.chunks_exact_mut(4).zip(values) {
            destination.copy_from_slice(&value.to_le_bytes());
        }
        out.write_all(&buffer[..values.len() * 4])?;
    }
    Ok(())
}

fn write_state_cache_id_encodings(
    out: &mut impl io::Write,
    values: &HashMap<(IdKind, i64), Vec<f32>>,
) -> io::Result<()> {
    let mut values: Vec<_> = values.iter().collect();
    values.sort_by_key(|((kind, value), _)| (kind.cache_code(), *value));
    write_state_cache_u32(out, values.len())?;
    for ((kind, value), encoding) in values {
        out.write_all(&[kind.cache_code()])?;
        out.write_all(&value.to_le_bytes())?;
        write_state_cache_f32_slice(out, encoding)?;
    }
    Ok(())
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct RwkvModule {
    layers: Vec<RwkvLayer>,
    precision: StatePrecision,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
struct ModuleQueryScratch {
    current: [f32; D_MODEL],
    next: [f32; D_MODEL],
    v0: [f32; D_MODEL],
    layer: LayerQueryScratch,
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
#[derive(Default)]
struct ModuleQueryBatchScratch {
    next: Vec<f32>,
    v0: Vec<f32>,
    layer: LayerQueryBatchScratch,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
impl Default for ModuleQueryScratch {
    fn default() -> Self {
        Self {
            current: [0.0; D_MODEL],
            next: [0.0; D_MODEL],
            v0: [0.0; D_MODEL],
            layer: LayerQueryScratch::default(),
        }
    }
}

impl RwkvModule {
    fn load(weights: &WeightMap, module_id: usize, layer_count: usize) -> io::Result<Self> {
        let mut layers = Vec::with_capacity(layer_count);
        for layer_id in 0..layer_count {
            layers.push(RwkvLayer::load(weights, module_id, layer_id)?);
        }
        Ok(Self {
            layers,
            precision: StatePrecision::F32,
        })
    }

    fn run(&self, input: &[f32], state: Option<&ModuleState>) -> (Vec<f32>, ModuleState) {
        let decoded = state.map(ModuleState::decoded);
        let state = decoded.as_deref();

        let mut x = input.to_vec();
        let mut v0 = vec![0.0; D_MODEL];
        let mut next_layers = Vec::with_capacity(self.layers.len());

        for (layer_id, layer) in self.layers.iter().enumerate() {
            let layer_state = state.and_then(|state| state.layers.get(layer_id));
            let (next_x, next_v0, next_layer_state) = layer.run(&x, &v0, layer_state);
            x = next_x;
            v0 = next_v0;
            next_layers.push(next_layer_state);
        }

        let output = (
            x,
            ModuleState {
                layers: next_layers,
                packed: None,
            }
            .compact(self.precision),
        );
        output
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn run_query(
        &self,
        input: &[f32],
        state: Option<&ModuleState>,
        scratch: &mut ModuleQueryScratch,
    ) -> [f32; D_MODEL] {
        let decoded = state.map(ModuleState::decoded);
        let state = decoded.as_deref();
        let ModuleQueryScratch {
            current,
            next,
            v0,
            layer: layer_scratch,
        } = scratch;
        current.copy_from_slice(input);
        v0.fill(0.0);
        let mut current = current;
        let mut next = next;

        for (layer_id, layer) in self.layers.iter().enumerate() {
            let layer_state = state.and_then(|state| state.layers.get(layer_id));
            layer.run_query_into(current, v0, layer_state, next, layer_scratch);
            std::mem::swap(&mut current, &mut next);
        }

        *current
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn run_query_batch(
        &self,
        x: &mut Vec<f32>,
        items: &[ReviewPredictionQueryRef<'_>],
        module_id: usize,
        scratch: &mut ModuleQueryBatchScratch,
    ) {
        let decoded: Vec<_> = items
            .iter()
            .map(|item| item.state.module(module_id).map(ModuleState::decoded))
            .collect();
        let decoded_items: Vec<_> = items
            .iter()
            .zip(&decoded)
            .map(|(item, state)| {
                let mut item = *item;
                match module_id {
                    0 => item.state.card = state.as_deref(),
                    1 => item.state.deck = state.as_deref(),
                    2 => item.state.note = state.as_deref(),
                    3 => item.state.preset = state.as_deref(),
                    _ => item.state.global = state.as_deref(),
                }
                item
            })
            .collect();
        let items = decoded_items.as_slice();
        let rows = items.len();
        scratch.v0.resize(rows * D_MODEL, 0.0);
        scratch.v0.fill(0.0);
        let mut current = std::mem::take(x);
        let mut next = std::mem::take(&mut scratch.next);

        for (layer_id, layer) in self.layers.iter().enumerate() {
            layer.run_query_batch(
                &current,
                &mut scratch.v0,
                items,
                module_id,
                layer_id,
                &mut next,
                &mut scratch.layer,
            );
            std::mem::swap(&mut current, &mut next);
        }

        *x = current;
        scratch.next = next;
    }
}

#[derive(Clone)]
struct ModuleState {
    layers: Vec<LayerState>,
    /// Compact states have no decoded layers; queries decode only their batch.
    packed: Option<Vec<u8>>,
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct RwkvLayer {
    time_mixer: TimeMixer,
    channel_mixer: ChannelMixer,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
struct LayerQueryScratch {
    time_output: [f32; D_MODEL],
    time: TimeMixerQueryScratch,
    channel: ChannelMixerQueryScratch,
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
#[derive(Default)]
struct LayerQueryBatchScratch {
    time_output: Vec<f32>,
    time: TimeMixerQueryBatchScratch,
    channel: ChannelMixerQueryBatchScratch,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
impl Default for LayerQueryScratch {
    fn default() -> Self {
        Self {
            time_output: [0.0; D_MODEL],
            time: TimeMixerQueryScratch::default(),
            channel: ChannelMixerQueryScratch::default(),
        }
    }
}

impl RwkvLayer {
    fn load(weights: &WeightMap, module_id: usize, layer_id: usize) -> io::Result<Self> {
        Ok(Self {
            time_mixer: TimeMixer::load(weights, module_id, layer_id)?,
            channel_mixer: ChannelMixer::load(weights, module_id, layer_id)?,
        })
    }

    fn run(
        &self,
        input: &[f32],
        v0: &[f32],
        state: Option<&LayerState>,
    ) -> (Vec<f32>, Vec<f32>, LayerState) {
        let (x, v0, time_state) =
            self.time_mixer
                .run(input, v0, state.and_then(|state| state.time.as_ref()));
        let (x, channel_shift) = self
            .channel_mixer
            .run(&x, state.and_then(|state| state.channel_shift.as_ref()));
        (
            x,
            v0,
            LayerState {
                time: Some(time_state),
                channel_shift: Some(channel_shift),
            },
        )
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn run_query_into(
        &self,
        input: &[f32],
        v0: &mut [f32; D_MODEL],
        state: Option<&LayerState>,
        out: &mut [f32; D_MODEL],
        scratch: &mut LayerQueryScratch,
    ) {
        self.time_mixer.run_query_into(
            input,
            v0,
            state.and_then(|state| state.time.as_ref()),
            &mut scratch.time_output,
            &mut scratch.time,
        );
        self.channel_mixer.run_query_into(
            &scratch.time_output,
            state.and_then(|state| state.channel_shift.as_deref()),
            out,
            &mut scratch.channel,
        );
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    #[allow(clippy::too_many_arguments)]
    fn run_query_batch(
        &self,
        input: &[f32],
        v0: &mut [f32],
        items: &[ReviewPredictionQueryRef<'_>],
        module_id: usize,
        layer_id: usize,
        out: &mut Vec<f32>,
        scratch: &mut LayerQueryBatchScratch,
    ) {
        self.time_mixer.run_query_batch(
            input,
            v0,
            items,
            module_id,
            layer_id,
            &mut scratch.time_output,
            &mut scratch.time,
        );
        self.channel_mixer.run_query_batch(
            &scratch.time_output,
            items,
            module_id,
            layer_id,
            out,
            &mut scratch.channel,
        );
    }
}

/// Card and note states: one per card and note, so they are most of the RWKV
/// memory (3 GB for a 101k-card collection in f32 on a Pixel 8a). They are
/// kept as the model makes them: compact (int8 by default, [StatePrecision])
/// and shared (`Arc`), so copying a map copies pointers: the state file is
/// written from such a copy on another thread ([RwkvStateSnapshot]). A state
/// is never changed in place, only replaced, so the copy stays as it was.
///
/// Fushi: compact states live in fixed-size slots ([slots::SlotStore]) rather
/// than one `Vec` each, so replay overwrites them in place instead of
/// re-allocating them around its scratch (which fragmented the heap to about
/// twice the live state). f32 states (no packed bytes) stay shared `Arc`s.
#[derive(Default)]
struct SharedStateMap {
    full: HashMap<i64, Arc<ModuleState>>,
    packed: Option<slots::SlotStore>,
}

impl SharedStateMap {
    fn contains(&self, id: i64) -> bool {
        self.full.contains_key(&id) || self.packed.as_ref().is_some_and(|p| p.get(id).is_some())
    }

    /// Bytes the states serialize to (= resident bytes of compact states).
    fn serialized_len(&self) -> usize {
        self.full
            .values()
            .map(|s| serialized_module_state_len(s))
            .sum::<usize>()
            + self.packed.as_ref().map_or(0, slots::SlotStore::state_bytes)
    }
}

/// Queries at a time when scoring many cards: compact states are decoded
/// for their batch only.
const STATE_VIEW_CHUNK: usize = 512;

/// What the state helpers need from a map of states, f32 or half.
trait StateMap {
    fn state(&self, id: &i64) -> Option<Cow<'_, ModuleState>>;
    fn put(&mut self, id: i64, state: ModuleState);
    fn take(&mut self, id: &i64) -> Option<ModuleState>;
    fn ids(&self) -> Vec<i64>;
    fn count(&self) -> usize;
    // Fushi: no `serialized_len` / `write_file_state` (workload sizing and
    // kuma3's half-float offline state file).
}

impl StateMap for HashMap<i64, ModuleState> {
    fn state(&self, id: &i64) -> Option<Cow<'_, ModuleState>> {
        self.get(id).map(Cow::Borrowed)
    }
    fn put(&mut self, id: i64, state: ModuleState) {
        self.insert(id, state);
    }
    fn take(&mut self, id: &i64) -> Option<ModuleState> {
        self.remove(id)
    }
    fn ids(&self) -> Vec<i64> {
        self.keys().copied().collect()
    }
    fn count(&self) -> usize {
        self.len()
    }
}

impl StateMap for SharedStateMap {
    fn state(&self, id: &i64) -> Option<Cow<'_, ModuleState>> {
        if let Some(bytes) = self.packed.as_ref().and_then(|p| p.get(*id)) {
            return Some(Cow::Owned(ModuleState {
                layers: Vec::new(),
                packed: Some(bytes.to_vec()),
            }));
        }
        self.full.get(id).map(|state| Cow::Borrowed(&**state))
    }
    fn put(&mut self, id: i64, state: ModuleState) {
        match &state.packed {
            Some(bytes) if self.packed.as_ref().is_none_or(|p| p.slot_len() == bytes.len()) => {
                self.packed
                    .get_or_insert_with(|| slots::SlotStore::new(bytes.len()))
                    .get_or_insert(id)
                    .copy_from_slice(bytes);
                self.full.remove(&id);
            }
            _ => {
                if let Some(packed) = &mut self.packed {
                    packed.take(id);
                }
                self.full.insert(id, Arc::new(state));
            }
        }
    }
    fn take(&mut self, id: &i64) -> Option<ModuleState> {
        if let Some(bytes) = self.packed.as_mut().and_then(|p| p.take(*id)) {
            return Some(ModuleState {
                layers: Vec::new(),
                packed: Some(bytes),
            });
        }
        self.full.remove(id).map(Arc::unwrap_or_clone)
    }
    fn ids(&self) -> Vec<i64> {
        let mut ids: Vec<i64> = self.full.keys().copied().collect();
        if let Some(packed) = &self.packed {
            ids.extend(packed.ids());
        }
        ids
    }
    fn count(&self) -> usize {
        self.full.len() + self.packed.as_ref().map_or(0, slots::SlotStore::len)
    }
}

#[derive(Clone)]
struct LayerState {
    time: Option<TimeState>,
    channel_shift: Option<Vec<f32>>,
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct TimeMixer {
    layer_id: usize,
    layer_norm: Norm,
    rkvdag_lerp: Vec<f32>,
    bonus: Vec<f32>,
    w_r: Linear,
    w_k: Linear,
    w_v: Linear,
    w_o: Linear,
    k_scale_linear: Linear,
    v_scale_linear: Linear,
    v_lora: LoraSimple,
    a_lora: LoraSimple,
    d_lora: LoraSimple,
    lora_a_g: Linear,
    lora_b_g: Linear,
    out_group_norm: Norm,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
struct TimeMixerQueryScratch {
    x: [f32; D_MODEL],
    mixed: [[f32; D_MODEL]; 8],
    r: [f32; D_MODEL],
    k: [f32; D_MODEL],
    v: [f32; D_MODEL],
    k_scale: [f32; HEADS],
    v_scale: [f32; HEADS],
    a: [f32; D_MODEL],
    g: [f32; D_MODEL],
    w: [f32; D_MODEL],
    k_deformed: [f32; D_MODEL],
    timestep_out: [f32; D_MODEL],
    temp: [f32; D_MODEL],
    lora_hidden: [f32; MAX_LORA_RANK],
    next_row: [f32; HEAD_SIZE],
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
#[derive(Default)]
struct TimeMixerQueryBatchScratch {
    x: Vec<f32>,
    mixed: [Vec<f32>; 8],
    r: Vec<f32>,
    k: Vec<f32>,
    v: Vec<f32>,
    k_scale: Vec<f32>,
    v_scale: Vec<f32>,
    a: Vec<f32>,
    g: Vec<f32>,
    w: Vec<f32>,
    k_deformed: Vec<f32>,
    timestep_out: Vec<f32>,
    temp: Vec<f32>,
    lora_hidden: Vec<f32>,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
impl Default for TimeMixerQueryScratch {
    fn default() -> Self {
        Self {
            x: [0.0; D_MODEL],
            mixed: [[0.0; D_MODEL]; 8],
            r: [0.0; D_MODEL],
            k: [0.0; D_MODEL],
            v: [0.0; D_MODEL],
            k_scale: [0.0; HEADS],
            v_scale: [0.0; HEADS],
            a: [0.0; D_MODEL],
            g: [0.0; D_MODEL],
            w: [0.0; D_MODEL],
            k_deformed: [0.0; D_MODEL],
            timestep_out: [0.0; D_MODEL],
            temp: [0.0; D_MODEL],
            lora_hidden: [0.0; MAX_LORA_RANK],
            next_row: [0.0; HEAD_SIZE],
        }
    }
}

impl TimeMixer {
    fn load(weights: &WeightMap, module_id: usize, layer_id: usize) -> io::Result<Self> {
        let prefix = format!("rwkv_modules.{module_id}.blocks.{layer_id}.time_mixer");
        Ok(Self {
            layer_id,
            layer_norm: weights.layer_norm(&format!("{prefix}.layer_norm"), D_MODEL, 1e-5)?,
            rkvdag_lerp: weights.values(&format!("{prefix}.rkvdag_lerp"))?,
            bonus: weights.values(&format!("{prefix}.bonus"))?,
            w_r: weights.linear(&format!("{prefix}.W_r"), D_MODEL, D_MODEL, false)?,
            w_k: weights.linear(&format!("{prefix}.W_k"), D_MODEL, D_MODEL, false)?,
            w_v: weights.linear(&format!("{prefix}.W_v"), D_MODEL, D_MODEL, false)?,
            w_o: weights.linear(&format!("{prefix}.W_o"), D_MODEL, D_MODEL, false)?,
            k_scale_linear: weights.linear(
                &format!("{prefix}.k_scale_linear"),
                D_MODEL,
                HEADS,
                true,
            )?,
            v_scale_linear: weights.linear(
                &format!("{prefix}.v_scale_linear"),
                D_MODEL,
                HEADS,
                true,
            )?,
            v_lora: LoraSimple::load(weights, &format!("{prefix}.v_lora_simple"), 8)?,
            a_lora: LoraSimple::load(weights, &format!("{prefix}.a_lora_simple"), 16)?,
            d_lora: LoraSimple::load(weights, &format!("{prefix}.d_lora_mlp"), 16)?,
            lora_a_g: weights.linear(&format!("{prefix}.lora_A_g"), D_MODEL, 16, false)?,
            lora_b_g: weights.linear(&format!("{prefix}.lora_B_g"), 16, D_MODEL, false)?,
            out_group_norm: weights.group_norm(
                &format!("{prefix}.out_group_norm"),
                HEADS,
                D_MODEL,
                64e-5,
            )?,
        })
    }

    fn run(
        &self,
        input: &[f32],
        v0: &[f32],
        state: Option<&TimeState>,
    ) -> (Vec<f32>, Vec<f32>, TimeState) {
        let x = self.layer_norm.apply(input);
        let (x_shift, state_matrix) = match state {
            Some(state) => (state.x_shift.as_slice(), state.matrix.as_slice()),
            None => (x.as_slice(), &[0.0; HEADS * HEAD_SIZE * HEAD_SIZE][..]),
        };

        let parts = self.mix_parts(&x, x_shift, v0);

        let (out, next_matrix) = single_timestep(
            &parts.r,
            &parts.k,
            &parts.v,
            &parts.w,
            &parts.a,
            &parts.k_deformed,
            state_matrix,
        );
        let out = self.mix_output(&parts, out, input);

        let output = (
            out,
            parts.next_v0,
            TimeState {
                x_shift: x,
                matrix: next_matrix,
                packed_matrix: None,
            },
        );
        output
    }

    /// The pre-recurrence per-timestep math shared by the per-review and bulk
    /// replay paths: lerp mixes, projections, loras, activations, and head
    /// normalization. `x` must already be layer-normed; `x_shift` is the
    /// previous timestep's normed input for this stream (or `x` itself when
    /// the stream has no state yet).
    fn mix_parts(&self, x: &[f32], x_shift: &[f32], v0: &[f32]) -> TimeMixParts {
        let mut mixed = [0.0; D_MODEL];
        let fill_mixed = |mix_id: usize, mixed: &mut [f32; D_MODEL]| {
            let lerp_offset = mix_id * D_MODEL;
            for channel in 0..D_MODEL {
                mixed[channel] = lerp(
                    x[channel],
                    x_shift[channel],
                    self.rkvdag_lerp[lerp_offset + channel],
                );
            }
        };

        fill_mixed(0, &mut mixed);
        let r = self.w_r.apply(&mixed);
        fill_mixed(1, &mut mixed);
        let mut k = self.w_k.apply(&mixed);
        fill_mixed(6, &mut mixed);
        let mut k_scale = self.k_scale_linear.apply(&mixed);
        sigmoid_in_place(&mut k_scale);
        fill_mixed(7, &mut mixed);
        let mut v_scale = self.v_scale_linear.apply(&mixed);
        sigmoid_in_place(&mut v_scale);

        fill_mixed(2, &mut mixed);
        let (v, next_v0) = if self.layer_id == 0 {
            let v = self.w_v.apply(&mixed);
            (v.clone(), v)
        } else {
            let mut v_lerp = self.v_lora.apply_sigmoid(&mixed);
            let w_v = self.w_v.apply(&mixed);
            for channel in 0..D_MODEL {
                v_lerp[channel] = lerp(w_v[channel], v0[channel], v_lerp[channel]);
            }
            (v_lerp, v0.to_vec())
        };

        fill_mixed(4, &mut mixed);
        let a = self.a_lora.apply_sigmoid(&mixed);
        fill_mixed(5, &mut mixed);
        let mut g = self.lora_a_g.apply(&mixed);
        sigmoid_in_place(&mut g);
        g = self.lora_b_g.apply(&g);

        fill_mixed(3, &mut mixed);
        let mut w = self.d_lora.apply_tanh(&mixed);
        for value in &mut w {
            let d = -0.5 - softplus(-*value);
            *value = (-d.exp()).exp();
        }

        normalize_heads_in_place(&mut k);
        for head in 0..HEADS {
            for index in 0..HEAD_SIZE {
                k[head * HEAD_SIZE + index] *= k_scale[head];
            }
        }

        let mut v = v;
        normalize_heads_in_place(&mut v);
        for head in 0..HEADS {
            for index in 0..HEAD_SIZE {
                v[head * HEAD_SIZE + index] *= v_scale[head];
            }
        }

        let k_deformed = k.clone();
        for channel in 0..D_MODEL {
            k[channel] *= a[channel];
        }

        TimeMixParts {
            r,
            k,
            v,
            w,
            a,
            k_deformed,
            g,
            next_v0,
        }
    }

    /// The post-recurrence per-timestep math shared by the per-review and
    /// bulk replay paths: group norm, bonus, gate, output projection, and the
    /// residual add against the un-normed layer input.
    fn mix_output(
        &self,
        parts: &TimeMixParts,
        recurrence_out: Vec<f32>,
        input: &[f32],
    ) -> Vec<f32> {
        let mut out = self.out_group_norm.apply(&recurrence_out);

        let mut bonus = [0.0; D_MODEL];
        for head in 0..HEADS {
            let base = head * HEAD_SIZE;
            let mut bonus_scale = 0.0;
            for index in 0..HEAD_SIZE {
                bonus_scale +=
                    parts.r[base + index] * self.bonus[base + index] * parts.k[base + index];
            }
            for index in 0..HEAD_SIZE {
                bonus[base + index] = bonus_scale * parts.v[base + index];
            }
        }

        for channel in 0..D_MODEL {
            out[channel] = parts.g[channel] * (out[channel] + bonus[channel]);
        }
        let mut out = self.w_o.apply(&out);
        for channel in 0..D_MODEL {
            out[channel] += input[channel];
        }
        out
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn run_query_into(
        &self,
        input: &[f32],
        v0: &mut [f32; D_MODEL],
        state: Option<&TimeState>,
        out: &mut [f32; D_MODEL],
        scratch: &mut TimeMixerQueryScratch,
    ) {
        let TimeMixerQueryScratch {
            x,
            mixed,
            r,
            k,
            v,
            k_scale,
            v_scale,
            a,
            g,
            w,
            k_deformed,
            timestep_out,
            temp,
            lora_hidden,
            next_row,
        } = scratch;

        self.layer_norm.apply_into(input, x);
        let x_shift = state.map_or(x.as_slice(), |state| state.x_shift.as_slice());
        for (mix_id, mixed_row) in mixed.iter_mut().enumerate() {
            let lerp_offset = mix_id * D_MODEL;
            for channel in 0..D_MODEL {
                mixed_row[channel] = lerp(
                    x[channel],
                    x_shift[channel],
                    self.rkvdag_lerp[lerp_offset + channel],
                );
            }
        }

        self.w_r.apply_into(&mixed[0], r);
        self.w_k.apply_into(&mixed[1], k);
        self.k_scale_linear.apply_into(&mixed[6], k_scale);
        sigmoid_in_place(k_scale);
        self.v_scale_linear.apply_into(&mixed[7], v_scale);
        sigmoid_in_place(v_scale);

        if self.layer_id == 0 {
            self.w_v.apply_into(&mixed[2], v);
            v0.copy_from_slice(v);
        } else {
            self.v_lora.apply_sigmoid_into(&mixed[2], lora_hidden, v);
            self.w_v.apply_into(&mixed[2], temp);
            for channel in 0..D_MODEL {
                v[channel] = lerp(temp[channel], v0[channel], v[channel]);
            }
        }

        self.a_lora.apply_sigmoid_into(&mixed[4], lora_hidden, a);
        self.lora_a_g.apply_into(&mixed[5], lora_hidden);
        sigmoid_in_place(lora_hidden);
        self.lora_b_g.apply_into(lora_hidden, g);

        self.d_lora.apply_tanh_into(&mixed[3], lora_hidden, w);
        for value in w.iter_mut() {
            let decay = -0.5 - softplus(-*value);
            *value = (-decay.exp()).exp();
        }

        normalize_heads_in_place(k);
        for head in 0..HEADS {
            for index in 0..HEAD_SIZE {
                k[head * HEAD_SIZE + index] *= k_scale[head];
            }
        }

        normalize_heads_in_place(v);
        for head in 0..HEADS {
            for index in 0..HEAD_SIZE {
                v[head * HEAD_SIZE + index] *= v_scale[head];
            }
        }

        k_deformed.copy_from_slice(k);
        for channel in 0..D_MODEL {
            k[channel] *= a[channel];
        }

        single_timestep_query_into(
            r,
            k,
            v,
            w,
            a,
            k_deformed,
            state.map(|state| state.matrix.as_slice()),
            timestep_out,
            next_row,
        );
        self.out_group_norm.apply_into(timestep_out, temp);

        for head in 0..HEADS {
            let base = head * HEAD_SIZE;
            let mut bonus_scale = 0.0;
            for index in 0..HEAD_SIZE {
                bonus_scale += r[base + index] * self.bonus[base + index] * k[base + index];
            }
            for index in 0..HEAD_SIZE {
                let channel = base + index;
                temp[channel] = g[channel] * (temp[channel] + bonus_scale * v[channel]);
            }
        }

        self.w_o.apply_into(temp, out);
        for channel in 0..D_MODEL {
            out[channel] += input[channel];
        }
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    #[allow(clippy::too_many_arguments)]
    fn run_query_batch(
        &self,
        input: &[f32],
        v0: &mut [f32],
        items: &[ReviewPredictionQueryRef<'_>],
        module_id: usize,
        layer_id: usize,
        out: &mut Vec<f32>,
        scratch: &mut TimeMixerQueryBatchScratch,
    ) {
        let rows = items.len();
        debug_assert_eq!(input.len(), rows * D_MODEL);
        debug_assert_eq!(v0.len(), rows * D_MODEL);

        self.layer_norm.apply_batch(input, rows, &mut scratch.x);
        for mixed in &mut scratch.mixed {
            mixed.resize(rows * D_MODEL, 0.0);
        }
        // Resolve each row's shift state once for all eight mixes.
        for (row, item) in items.iter().enumerate() {
            let x = &scratch.x[row * D_MODEL..(row + 1) * D_MODEL];
            let x_shift = item
                .layer_state(module_id, layer_id)
                .and_then(|state| state.time.as_ref())
                .map_or(x, |state| state.x_shift.as_slice());
            time_shift_mix_row(x, x_shift, &self.rkvdag_lerp, &mut scratch.mixed, row);
        }

        self.w_r
            .apply_batch(&scratch.mixed[0], rows, &mut scratch.r);
        self.w_k
            .apply_batch(&scratch.mixed[1], rows, &mut scratch.k);
        self.k_scale_linear
            .apply_batch(&scratch.mixed[6], rows, &mut scratch.k_scale);
        query_sigmoid_batch_in_place(&mut scratch.k_scale);
        self.v_scale_linear
            .apply_batch(&scratch.mixed[7], rows, &mut scratch.v_scale);
        query_sigmoid_batch_in_place(&mut scratch.v_scale);

        if self.layer_id == 0 {
            self.w_v
                .apply_batch(&scratch.mixed[2], rows, &mut scratch.v);
            v0.copy_from_slice(&scratch.v);
        } else {
            self.v_lora.apply_sigmoid_batch(
                &scratch.mixed[2],
                rows,
                &mut scratch.lora_hidden,
                &mut scratch.v,
            );
            self.w_v
                .apply_batch(&scratch.mixed[2], rows, &mut scratch.temp);
            scratch
                .v
                .chunks_mut(D_MODEL)
                .enumerate()
                .for_each(|(row, v)| {
                    let projected = &scratch.temp[row * D_MODEL..(row + 1) * D_MODEL];
                    let v0 = &v0[row * D_MODEL..(row + 1) * D_MODEL];
                    for channel in 0..D_MODEL {
                        v[channel] = lerp(projected[channel], v0[channel], v[channel]);
                    }
                });
        }

        self.a_lora.apply_sigmoid_batch(
            &scratch.mixed[4],
            rows,
            &mut scratch.lora_hidden,
            &mut scratch.a,
        );
        self.lora_a_g
            .apply_batch(&scratch.mixed[5], rows, &mut scratch.lora_hidden);
        query_sigmoid_batch_in_place(&mut scratch.lora_hidden);
        self.lora_b_g
            .apply_batch(&scratch.lora_hidden, rows, &mut scratch.g);

        self.d_lora.apply_tanh_batch(
            &scratch.mixed[3],
            rows,
            &mut scratch.lora_hidden,
            &mut scratch.w,
        );
        query_decay_batch_in_place(&mut scratch.w);

        scratch
            .k
            .chunks_mut(D_MODEL)
            .zip(scratch.k_scale.chunks(HEADS))
            .for_each(|(k, scales)| normalize_scale_heads_in_place(k, scales));
        scratch
            .v
            .chunks_mut(D_MODEL)
            .zip(scratch.v_scale.chunks(HEADS))
            .for_each(|(v, scales)| normalize_scale_heads_in_place(v, scales));

        scratch.k_deformed.resize(rows * D_MODEL, 0.0);
        scratch.k_deformed.copy_from_slice(&scratch.k);
        scratch
            .k
            .iter_mut()
            .zip(scratch.a.iter())
            .for_each(|(k, a)| *k *= *a);

        scratch.timestep_out.resize(rows * D_MODEL, 0.0);
        scratch
            .timestep_out
            .chunks_mut(D_MODEL)
            .enumerate()
            .for_each(|(row, timestep_out)| {
                let range = row * D_MODEL..(row + 1) * D_MODEL;
                let state = items[row]
                    .layer_state(module_id, layer_id)
                    .and_then(|state| state.time.as_ref())
                    .map(|state| state.matrix.as_slice());
                single_timestep_query_fast_into(
                    &scratch.r[range.clone()],
                    &scratch.k[range.clone()],
                    &scratch.v[range.clone()],
                    &scratch.w[range.clone()],
                    &scratch.a[range.clone()],
                    &scratch.k_deformed[range],
                    state,
                    timestep_out,
                );
            });
        self.out_group_norm
            .apply_batch(&scratch.timestep_out, rows, &mut scratch.temp);

        scratch
            .temp
            .chunks_mut(D_MODEL)
            .enumerate()
            .for_each(|(row, output)| {
                let range = row * D_MODEL..(row + 1) * D_MODEL;
                bonus_gate_in_place(
                    output,
                    &scratch.r[range.clone()],
                    &self.bonus,
                    &scratch.k[range.clone()],
                    &scratch.v[range.clone()],
                    &scratch.g[range],
                );
            });

        self.w_o.apply_batch(&scratch.temp, rows, out);
        out.iter_mut()
            .zip(input.iter())
            .for_each(|(output, input)| *output += *input);
    }
}

/// Per-timestep time-mixer coefficients produced ahead of the recurrence.
struct TimeMixParts {
    r: Vec<f32>,
    k: Vec<f32>,
    v: Vec<f32>,
    w: Vec<f32>,
    a: Vec<f32>,
    k_deformed: Vec<f32>,
    g: Vec<f32>,
    next_v0: Vec<f32>,
}

#[derive(Clone)]
struct TimeState {
    x_shift: Vec<f32>,
    matrix: Vec<f32>,
    packed_matrix: Option<precision::PackedMatrix>,
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct ChannelMixer {
    layer_norm: Norm,
    lerp_k: Vec<f32>,
    w_k: Linear,
    w_v: Linear,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
struct ChannelMixerQueryScratch {
    x: [f32; D_MODEL],
    mixed: [f32; D_MODEL],
    hidden: [f32; MAX_CHANNEL_MIXER_DIM],
    projected: [f32; D_MODEL],
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
#[derive(Default)]
struct ChannelMixerQueryBatchScratch {
    x: Vec<f32>,
    mixed: Vec<f32>,
    hidden: Vec<f32>,
    projected: Vec<f32>,
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
impl Default for ChannelMixerQueryScratch {
    fn default() -> Self {
        Self {
            x: [0.0; D_MODEL],
            mixed: [0.0; D_MODEL],
            hidden: [0.0; MAX_CHANNEL_MIXER_DIM],
            projected: [0.0; D_MODEL],
        }
    }
}

impl ChannelMixer {
    fn load(weights: &WeightMap, module_id: usize, layer_id: usize) -> io::Result<Self> {
        let channel_dim = CHANNEL_MIXER_DIMS[module_id];
        let prefix = format!("rwkv_modules.{module_id}.blocks.{layer_id}.channel_mixer");
        Ok(Self {
            layer_norm: weights.layer_norm(&format!("{prefix}.layer_norm"), D_MODEL, 1e-5)?,
            lerp_k: weights.values(&format!("{prefix}.lerp_k"))?,
            w_k: weights.linear(&format!("{prefix}.W_k"), D_MODEL, channel_dim, false)?,
            w_v: weights.linear(&format!("{prefix}.W_v"), channel_dim, D_MODEL, false)?,
        })
    }

    fn run(&self, input: &[f32], state: Option<&Vec<f32>>) -> (Vec<f32>, Vec<f32>) {
        let x = self.layer_norm.apply(input);
        let x_shift = state.map_or(x.as_slice(), |state| state.as_slice());
        let out = self.mix_value(&x, x_shift, input);
        let output = (out, x);
        output
    }

    /// The per-timestep channel-mixer math shared by the per-review and bulk
    /// replay paths. `x` must already be layer-normed; `x_shift` is the
    /// previous timestep's normed input for this stream (or `x` itself when
    /// the stream has no state yet); `input` is the un-normed layer input
    /// used for the residual add.
    fn mix_value(&self, x: &[f32], x_shift: &[f32], input: &[f32]) -> Vec<f32> {
        let mut mixed = [0.0; D_MODEL];
        for channel in 0..D_MODEL {
            mixed[channel] = lerp(x[channel], x_shift[channel], self.lerp_k[channel]);
        }

        let mut k = self.w_k.apply(&mixed);
        for value in &mut k {
            *value = value.max(0.0).powi(2);
        }
        let mut out = self.w_v.apply(&k);
        for channel in 0..D_MODEL {
            out[channel] += input[channel];
        }
        out
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn run_query_into(
        &self,
        input: &[f32],
        state: Option<&[f32]>,
        out: &mut [f32; D_MODEL],
        scratch: &mut ChannelMixerQueryScratch,
    ) {
        self.layer_norm.apply_into(input, &mut scratch.x);
        let x_shift = state.unwrap_or(&scratch.x);
        for (channel, mixed) in scratch.mixed.iter_mut().enumerate() {
            *mixed = lerp(scratch.x[channel], x_shift[channel], self.lerp_k[channel]);
        }

        let hidden = &mut scratch.hidden[..self.w_k.output];
        self.w_k.apply_into(&scratch.mixed, hidden);
        for value in hidden.iter_mut() {
            *value = value.max(0.0).powi(2);
        }
        self.w_v.apply_into(hidden, &mut scratch.projected);
        for channel in 0..D_MODEL {
            out[channel] = input[channel] + scratch.projected[channel];
        }
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn run_query_batch(
        &self,
        input: &[f32],
        items: &[ReviewPredictionQueryRef<'_>],
        module_id: usize,
        layer_id: usize,
        out: &mut Vec<f32>,
        scratch: &mut ChannelMixerQueryBatchScratch,
    ) {
        let rows = items.len();
        self.layer_norm.apply_batch(input, rows, &mut scratch.x);
        scratch.mixed.resize(rows * D_MODEL, 0.0);
        scratch
            .mixed
            .chunks_mut(D_MODEL)
            .enumerate()
            .for_each(|(row, mixed)| {
                let x = &scratch.x[row * D_MODEL..(row + 1) * D_MODEL];
                let x_shift = items[row]
                    .layer_state(module_id, layer_id)
                    .and_then(|state| state.channel_shift.as_deref())
                    .unwrap_or(x);
                for channel in 0..D_MODEL {
                    mixed[channel] = lerp(x[channel], x_shift[channel], self.lerp_k[channel]);
                }
            });

        self.w_k
            .apply_batch(&scratch.mixed, rows, &mut scratch.hidden);
        scratch
            .hidden
            .iter_mut()
            .for_each(|value| *value = value.max(0.0).powi(2));
        self.w_v
            .apply_batch(&scratch.hidden, rows, &mut scratch.projected);
        out.resize(rows * D_MODEL, 0.0);
        out.iter_mut()
            .zip(input.iter())
            .zip(scratch.projected.iter())
            .for_each(|((output, input), projected)| *output = *input + *projected);
    }
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct LoraSimple {
    a: Linear,
    b: Linear,
}

impl LoraSimple {
    fn load(weights: &WeightMap, prefix: &str, rank: usize) -> io::Result<Self> {
        Ok(Self {
            a: weights.linear(&format!("{prefix}.A"), D_MODEL, rank, false)?,
            b: weights.linear(&format!("{prefix}.B_and_lamb"), rank, D_MODEL, true)?,
        })
    }

    fn apply_sigmoid(&self, input: &[f32]) -> Vec<f32> {
        let mut out = self.b.apply(&self.a.apply(input));
        sigmoid_in_place(&mut out);
        out
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn apply_sigmoid_into(&self, input: &[f32], hidden: &mut [f32], out: &mut [f32]) {
        let hidden = &mut hidden[..self.a.output];
        self.a.apply_into(input, hidden);
        self.b.apply_into(hidden, out);
        sigmoid_in_place(out);
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn apply_sigmoid_batch(
        &self,
        input: &[f32],
        rows: usize,
        hidden: &mut Vec<f32>,
        out: &mut Vec<f32>,
    ) {
        self.a.apply_batch(input, rows, hidden);
        self.b.apply_batch(hidden, rows, out);
        query_sigmoid_batch_in_place(out);
    }

    fn apply_tanh(&self, input: &[f32]) -> Vec<f32> {
        let mut hidden = self.a.apply(input);
        for value in &mut hidden {
            *value = value.tanh();
        }
        self.b.apply(&hidden)
    }

    /// Block variant of `apply_sigmoid`; bit-identical per row.
    fn apply_sigmoid_block_into(&self, inputs: &[f32], outs: &mut [f32], rows: usize) {
        let rank = self.a.output;
        debug_assert!(rank <= 16);
        debug_assert!(rows <= LINEAR_BLOCK_ROWS);
        let mut hidden = [0.0; 16 * LINEAR_BLOCK_ROWS];
        let hidden = &mut hidden[..rows * rank];
        self.a.apply_block_into(inputs, hidden, rows);
        self.b.apply_block_into(hidden, outs, rows);
        sigmoid_in_place(outs);
    }

    /// Block variant of `apply_tanh`; bit-identical per row.
    fn apply_tanh_block_into(&self, inputs: &[f32], outs: &mut [f32], rows: usize) {
        let rank = self.a.output;
        debug_assert!(rank <= 16);
        debug_assert!(rows <= LINEAR_BLOCK_ROWS);
        let mut hidden = [0.0; 16 * LINEAR_BLOCK_ROWS];
        let hidden = &mut hidden[..rows * rank];
        self.a.apply_block_into(inputs, hidden, rows);
        for value in hidden.iter_mut() {
            *value = value.tanh();
        }
        self.b.apply_block_into(hidden, outs, rows);
    }

    #[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
    fn apply_tanh_into(&self, input: &[f32], hidden: &mut [f32], out: &mut [f32]) {
        let hidden = &mut hidden[..self.a.output];
        self.a.apply_into(input, hidden);
        for value in hidden.iter_mut() {
            *value = value.tanh();
        }
        self.b.apply_into(hidden, out);
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn apply_tanh_batch(
        &self,
        input: &[f32],
        rows: usize,
        hidden: &mut Vec<f32>,
        out: &mut Vec<f32>,
    ) {
        self.a.apply_batch(input, rows, hidden);
        query_tanh_batch_in_place(hidden);
        self.b.apply_batch(hidden, rows, out);
    }
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct Linear {
    input: usize,
    output: usize,
    weight_by_input: Vec<f32>,
    bias: Option<Vec<f32>>,
}

impl Linear {
    fn apply(&self, input: &[f32]) -> Vec<f32> {
        let mut out = vec![0.0; self.output];
        self.apply_into(input, &mut out);
        out
    }

    fn apply_into(&self, input: &[f32], out: &mut [f32]) {
        debug_assert_eq!(input.len(), self.input);
        debug_assert_eq!(out.len(), self.output);
        if let Some(bias) = &self.bias {
            out.copy_from_slice(bias);
        } else {
            out.fill(0.0);
        }

        #[cfg(target_arch = "aarch64")]
        {
            // SAFETY: aarch64 guarantees NEON support. The helper receives
            // slices whose dimensions were checked above and only accesses
            // complete weight columns and output elements within them.
            unsafe { linear_apply_row_neon(input, &self.weight_by_input, out) };
            return;
        }

        #[allow(unreachable_code)]
        for (column, scale) in input.iter().copied().enumerate() {
            if scale == 0.0 {
                continue;
            }
            let weight_column =
                &self.weight_by_input[column * self.output..(column + 1) * self.output];
            add_scaled_in_place(out, weight_column, scale);
        }
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn apply_batch(&self, input: &[f32], rows: usize, out: &mut Vec<f32>) {
        let input_len = rows
            .checked_mul(self.input)
            .expect("linear batch input is too large");
        let output_len = rows
            .checked_mul(self.output)
            .expect("linear batch output is too large");
        assert_eq!(input.len(), input_len);
        out.resize(output_len, 0.0);
        if rows == 0 {
            return;
        }

        #[cfg(target_os = "macos")]
        matmul::matrix_times_matrix(
            input,
            &self.weight_by_input,
            rows,
            self.output,
            self.input,
            out,
        );

        // kuma3: phones (aarch64) take the batched query path too; the block
        // kernel streams each weight column once per block of rows (NEON),
        // bit-identical to `apply_into` per row. Callers already run batches
        // in parallel.
        #[cfg(not(target_os = "macos"))]
        self.apply_block_into(input, out, rows);

        #[cfg(target_os = "macos")]
        if let Some(bias) = &self.bias {
            out.chunks_mut(self.output).for_each(|output| {
                for (output, bias) in output.iter_mut().zip(bias) {
                    *output += bias;
                }
            });
        }
    }

    /// Applies the projection to `rows` packed input rows at once, streaming
    /// each weight column once per block instead of once per row. For every
    /// output element this performs the identical operation sequence as
    /// `apply_into` (bias init, then ascending-column fused accumulation with
    /// the same zero-column skip), so results are bit-identical to calling
    /// `apply_into` per row.
    fn apply_block_into(&self, inputs: &[f32], outs: &mut [f32], rows: usize) {
        debug_assert_eq!(inputs.len(), rows * self.input);
        debug_assert_eq!(outs.len(), rows * self.output);
        for out in outs.chunks_exact_mut(self.output) {
            if let Some(bias) = &self.bias {
                out.copy_from_slice(bias);
            } else {
                out.fill(0.0);
            }
        }

        #[cfg(target_arch = "aarch64")]
        if rows >= 4 {
            // SAFETY: aarch64 guarantees NEON support. The helper receives
            // slices whose dimensions were checked above and only accesses
            // complete rows and output vectors within those dimensions.
            unsafe {
                linear_apply_block_neon(
                    inputs,
                    &self.weight_by_input,
                    outs,
                    rows,
                    self.input,
                    self.output,
                );
            }
            return;
        }

        #[cfg(target_arch = "x86_64")]
        if rows >= 4 && x86_avx2_fma_available() {
            // SAFETY: availability was checked above. The helper receives
            // slices whose dimensions were checked above and only accesses
            // complete rows and output vectors within those dimensions.
            unsafe {
                linear_apply_block_avx2_fma(
                    inputs,
                    &self.weight_by_input,
                    outs,
                    rows,
                    self.input,
                    self.output,
                );
            }
            return;
        }

        for column in 0..self.input {
            let weight_column =
                &self.weight_by_input[column * self.output..(column + 1) * self.output];
            for (row, out) in outs.chunks_exact_mut(self.output).enumerate() {
                let scale = inputs[row * self.input + column];
                if scale == 0.0 {
                    continue;
                }
                add_scaled_in_place(out, weight_column, scale);
            }
        }
    }

    /// Uses the native matrix backend for non-persisted bulk query rows when
    /// requested. Answer rows retain `apply_block_into()`'s exact accumulation
    /// order so warm-up state snapshots remain byte-identical.
    fn apply_block_approx_into(
        &self,
        inputs: &[f32],
        outs: &mut [f32],
        rows: usize,
        approximate: bool,
    ) {
        #[cfg(not(target_os = "macos"))]
        let _ = approximate;

        #[cfg(target_os = "macos")]
        if approximate && rows >= 16 && self.input * self.output >= 4096 {
            matmul::matrix_times_matrix(
                inputs,
                &self.weight_by_input,
                rows,
                self.output,
                self.input,
                outs,
            );
            if let Some(bias) = &self.bias {
                for out in outs.chunks_exact_mut(self.output) {
                    for (value, bias) in out.iter_mut().zip(bias) {
                        *value += bias;
                    }
                }
            }
            return;
        }

        self.apply_block_into(inputs, outs, rows);
    }
}

#[inline(always)]
fn add_scaled_in_place(out: &mut [f32], weights: &[f32], scale: f32) {
    debug_assert_eq!(out.len(), weights.len());
    add_scaled_in_place_arch(out, weights, scale)
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn add_scaled_in_place_arch(out: &mut [f32], weights: &[f32], scale: f32) {
    // SAFETY: aarch64 guarantees NEON support, and the helper only uses
    // unaligned loads/stores within the bounds checked by its loop conditions.
    unsafe { add_scaled_in_place_neon(out, weights, scale) }
}

#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn add_scaled_in_place_arch(out: &mut [f32], weights: &[f32], scale: f32) {
    if x86_avx2_fma_available() {
        // SAFETY: availability was checked above, and the helper only uses
        // unaligned loads/stores within the bounds checked by its loops.
        unsafe { add_scaled_in_place_avx2_fma(out, weights, scale) }
    } else {
        add_scaled_in_place_scalar(out, weights, scale)
    }
}

#[cfg(all(not(target_arch = "aarch64"), not(target_arch = "x86_64")))]
#[inline(always)]
fn add_scaled_in_place_arch(out: &mut [f32], weights: &[f32], scale: f32) {
    add_scaled_in_place_scalar(out, weights, scale)
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn add_scaled_in_place_neon(out: &mut [f32], weights: &[f32], scale: f32) {
    use std::arch::aarch64::*;

    let mut offset = 0;
    let len = out.len();
    let scale = vdupq_n_f32(scale);
    while offset + 16 <= len {
        let out_ptr = out.as_mut_ptr().add(offset);
        let weight_ptr = weights.as_ptr().add(offset);
        vst1q_f32(
            out_ptr,
            vfmaq_f32(vld1q_f32(out_ptr), vld1q_f32(weight_ptr), scale),
        );
        vst1q_f32(
            out_ptr.add(4),
            vfmaq_f32(
                vld1q_f32(out_ptr.add(4)),
                vld1q_f32(weight_ptr.add(4)),
                scale,
            ),
        );
        vst1q_f32(
            out_ptr.add(8),
            vfmaq_f32(
                vld1q_f32(out_ptr.add(8)),
                vld1q_f32(weight_ptr.add(8)),
                scale,
            ),
        );
        vst1q_f32(
            out_ptr.add(12),
            vfmaq_f32(
                vld1q_f32(out_ptr.add(12)),
                vld1q_f32(weight_ptr.add(12)),
                scale,
            ),
        );
        offset += 16;
    }
    while offset + 4 <= len {
        let out_ptr = out.as_mut_ptr().add(offset);
        let weight_ptr = weights.as_ptr().add(offset);
        vst1q_f32(
            out_ptr,
            vfmaq_f32(vld1q_f32(out_ptr), vld1q_f32(weight_ptr), scale),
        );
        offset += 4;
    }
    while offset < len {
        out[offset] += weights[offset] * vgetq_lane_f32(scale, 0);
        offset += 1;
    }
}

/// Exact single-row linear projection microkernel for AArch64 NEON machines.
///
/// Keeps a tile of up to 64 output accumulators in registers while walking
/// every input column, so the output is loaded and stored once per tile
/// instead of once per column. Each output element still starts from `out`'s
/// initial value and accumulates ascending columns with the same fused
/// multiply-add and zero-scale skip as `add_scaled_in_place()`, so results
/// are bit-identical to the column-at-a-time loop.
#[cfg(target_arch = "aarch64")]
unsafe fn linear_apply_row_neon(input: &[f32], weights: &[f32], out: &mut [f32]) {
    use std::arch::aarch64::*;

    let output = out.len();
    debug_assert_eq!(weights.len(), input.len() * output);
    let out_ptr = out.as_mut_ptr();
    let weight_ptr = weights.as_ptr();
    let mut tile = 0;

    macro_rules! tile {
        ($lanes:literal) => {
            while tile + 4 * $lanes <= output {
                let mut acc = [vdupq_n_f32(0.0); $lanes];
                for (lane, acc) in acc.iter_mut().enumerate() {
                    *acc = vld1q_f32(out_ptr.add(tile + 4 * lane));
                }
                for (column, &scale) in input.iter().enumerate() {
                    if scale == 0.0 {
                        continue;
                    }
                    let scale = vdupq_n_f32(scale);
                    let column_ptr = weight_ptr.add(column * output + tile);
                    for (lane, acc) in acc.iter_mut().enumerate() {
                        *acc = vfmaq_f32(*acc, vld1q_f32(column_ptr.add(4 * lane)), scale);
                    }
                }
                for (lane, acc) in acc.iter().enumerate() {
                    vst1q_f32(out_ptr.add(tile + 4 * lane), *acc);
                }
                tile += 4 * $lanes;
            }
        };
    }
    tile!(16);
    tile!(4);
    tile!(1);

    for offset in tile..output {
        let mut value = *out_ptr.add(offset);
        for (column, &scale) in input.iter().enumerate() {
            if scale == 0.0 {
                continue;
            }
            value += *weight_ptr.add(column * output + offset) * scale;
        }
        *out_ptr.add(offset) = value;
    }
}

/// Exact four-row linear projection microkernel for AArch64 NEON machines.
///
/// Each output accumulator still visits input columns in ascending order and
/// skips zero scales, matching `Linear::apply_into()`. Four rows share each
/// weight load while retaining the column-major loop order, so input scales
/// are loaded only once per projection column.
#[cfg(target_arch = "aarch64")]
unsafe fn linear_apply_block_neon(
    inputs: &[f32],
    weights: &[f32],
    outs: &mut [f32],
    rows: usize,
    input: usize,
    output: usize,
) {
    use std::arch::aarch64::*;

    let tiled_rows = rows / 4 * 4;
    for row_base in (0..tiled_rows).step_by(4) {
        for column in 0..input {
            let scale0 = *inputs.get_unchecked(row_base * input + column);
            let scale1 = *inputs.get_unchecked((row_base + 1) * input + column);
            let scale2 = *inputs.get_unchecked((row_base + 2) * input + column);
            let scale3 = *inputs.get_unchecked((row_base + 3) * input + column);
            if scale0 == 0.0 && scale1 == 0.0 && scale2 == 0.0 && scale3 == 0.0 {
                continue;
            }

            let weight_column = weights.as_ptr().add(column * output);
            let mut output_offset = 0;
            while output_offset + 16 <= output {
                let weights = [
                    vld1q_f32(weight_column.add(output_offset)),
                    vld1q_f32(weight_column.add(output_offset + 4)),
                    vld1q_f32(weight_column.add(output_offset + 8)),
                    vld1q_f32(weight_column.add(output_offset + 12)),
                ];
                if scale0 != 0.0 {
                    add_scaled_16_neon(
                        outs.as_mut_ptr().add(row_base * output + output_offset),
                        weights,
                        scale0,
                    );
                }
                if scale1 != 0.0 {
                    add_scaled_16_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 1) * output + output_offset),
                        weights,
                        scale1,
                    );
                }
                if scale2 != 0.0 {
                    add_scaled_16_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 2) * output + output_offset),
                        weights,
                        scale2,
                    );
                }
                if scale3 != 0.0 {
                    add_scaled_16_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 3) * output + output_offset),
                        weights,
                        scale3,
                    );
                }
                output_offset += 16;
            }
            while output_offset + 4 <= output {
                let weight = vld1q_f32(weight_column.add(output_offset));
                if scale0 != 0.0 {
                    add_scaled_4_neon(
                        outs.as_mut_ptr().add(row_base * output + output_offset),
                        weight,
                        scale0,
                    );
                }
                if scale1 != 0.0 {
                    add_scaled_4_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 1) * output + output_offset),
                        weight,
                        scale1,
                    );
                }
                if scale2 != 0.0 {
                    add_scaled_4_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 2) * output + output_offset),
                        weight,
                        scale2,
                    );
                }
                if scale3 != 0.0 {
                    add_scaled_4_neon(
                        outs.as_mut_ptr()
                            .add((row_base + 3) * output + output_offset),
                        weight,
                        scale3,
                    );
                }
                output_offset += 4;
            }
            while output_offset < output {
                let weight = *weight_column.add(output_offset);
                if scale0 != 0.0 {
                    *outs.get_unchecked_mut(row_base * output + output_offset) += weight * scale0;
                }
                if scale1 != 0.0 {
                    *outs.get_unchecked_mut((row_base + 1) * output + output_offset) +=
                        weight * scale1;
                }
                if scale2 != 0.0 {
                    *outs.get_unchecked_mut((row_base + 2) * output + output_offset) +=
                        weight * scale2;
                }
                if scale3 != 0.0 {
                    *outs.get_unchecked_mut((row_base + 3) * output + output_offset) +=
                        weight * scale3;
                }
                output_offset += 1;
            }
        }
    }

    for row in tiled_rows..rows {
        let out = &mut outs[row * output..(row + 1) * output];
        for column in 0..input {
            let scale = *inputs.get_unchecked(row * input + column);
            if scale == 0.0 {
                continue;
            }
            let weight_column = &weights[column * output..(column + 1) * output];
            add_scaled_in_place_neon(out, weight_column, scale);
        }
    }
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn add_scaled_16_neon(
    out: *mut f32,
    weights: [std::arch::aarch64::float32x4_t; 4],
    scale: f32,
) {
    use std::arch::aarch64::*;

    let scale = vdupq_n_f32(scale);
    vst1q_f32(out, vfmaq_f32(vld1q_f32(out), weights[0], scale));
    vst1q_f32(
        out.add(4),
        vfmaq_f32(vld1q_f32(out.add(4)), weights[1], scale),
    );
    vst1q_f32(
        out.add(8),
        vfmaq_f32(vld1q_f32(out.add(8)), weights[2], scale),
    );
    vst1q_f32(
        out.add(12),
        vfmaq_f32(vld1q_f32(out.add(12)), weights[3], scale),
    );
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn add_scaled_4_neon(out: *mut f32, weights: std::arch::aarch64::float32x4_t, scale: f32) {
    use std::arch::aarch64::*;

    vst1q_f32(out, vfmaq_f32(vld1q_f32(out), weights, vdupq_n_f32(scale)));
}

#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn x86_avx2_fma_available() -> bool {
    use std::sync::atomic::AtomicU8;
    use std::sync::atomic::Ordering;

    static AVAILABLE: AtomicU8 = AtomicU8::new(0);

    match AVAILABLE.load(Ordering::Relaxed) {
        1 => false,
        2 => true,
        _ => {
            let available =
                std::is_x86_feature_detected!("avx2") && std::is_x86_feature_detected!("fma");
            AVAILABLE.store(if available { 2 } else { 1 }, Ordering::Relaxed);
            available
        }
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
unsafe fn add_scaled_in_place_avx2_fma(out: &mut [f32], weights: &[f32], scale: f32) {
    use std::arch::x86_64::*;

    let mut offset = 0;
    let len = out.len();
    let scale_vector = _mm256_set1_ps(scale);
    while offset + 32 <= len {
        let out_ptr = out.as_mut_ptr().add(offset);
        let weight_ptr = weights.as_ptr().add(offset);
        _mm256_storeu_ps(
            out_ptr,
            _mm256_fmadd_ps(
                _mm256_loadu_ps(weight_ptr),
                scale_vector,
                _mm256_loadu_ps(out_ptr),
            ),
        );
        _mm256_storeu_ps(
            out_ptr.add(8),
            _mm256_fmadd_ps(
                _mm256_loadu_ps(weight_ptr.add(8)),
                scale_vector,
                _mm256_loadu_ps(out_ptr.add(8)),
            ),
        );
        _mm256_storeu_ps(
            out_ptr.add(16),
            _mm256_fmadd_ps(
                _mm256_loadu_ps(weight_ptr.add(16)),
                scale_vector,
                _mm256_loadu_ps(out_ptr.add(16)),
            ),
        );
        _mm256_storeu_ps(
            out_ptr.add(24),
            _mm256_fmadd_ps(
                _mm256_loadu_ps(weight_ptr.add(24)),
                scale_vector,
                _mm256_loadu_ps(out_ptr.add(24)),
            ),
        );
        offset += 32;
    }
    while offset + 8 <= len {
        let out_ptr = out.as_mut_ptr().add(offset);
        let weight_ptr = weights.as_ptr().add(offset);
        _mm256_storeu_ps(
            out_ptr,
            _mm256_fmadd_ps(
                _mm256_loadu_ps(weight_ptr),
                scale_vector,
                _mm256_loadu_ps(out_ptr),
            ),
        );
        offset += 8;
    }
    while offset < len {
        out[offset] += weights[offset] * scale;
        offset += 1;
    }
}

/// Exact four-row linear projection microkernel for AVX2/FMA machines.
///
/// Each output accumulator still visits input columns in ascending order and
/// skips zero scales, matching `Linear::apply_into()`. Changing only the row
/// and output-vector loop order lets four reviews share each weight load. Two
/// input columns are handled per inner-loop iteration to reduce loop-control
/// overhead without changing the per-output accumulation order.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
unsafe fn linear_apply_block_avx2_fma(
    inputs: &[f32],
    weights: &[f32],
    outs: &mut [f32],
    rows: usize,
    input: usize,
    output: usize,
) {
    use std::arch::x86_64::*;

    let tiled_rows = rows / 4 * 4;
    for row_base in (0..tiled_rows).step_by(4) {
        let mut output_offset = 0;
        while output_offset + 8 <= output {
            let mut acc0 = _mm256_loadu_ps(outs.as_ptr().add(row_base * output + output_offset));
            let mut acc1 =
                _mm256_loadu_ps(outs.as_ptr().add((row_base + 1) * output + output_offset));
            let mut acc2 =
                _mm256_loadu_ps(outs.as_ptr().add((row_base + 2) * output + output_offset));
            let mut acc3 =
                _mm256_loadu_ps(outs.as_ptr().add((row_base + 3) * output + output_offset));

            let mut column = 0;
            while column + 2 <= input {
                let weight0 =
                    _mm256_loadu_ps(weights.as_ptr().add(column * output + output_offset));
                let scale00 = *inputs.get_unchecked(row_base * input + column);
                let scale10 = *inputs.get_unchecked((row_base + 1) * input + column);
                let scale20 = *inputs.get_unchecked((row_base + 2) * input + column);
                let scale30 = *inputs.get_unchecked((row_base + 3) * input + column);
                if scale00 != 0.0 {
                    acc0 = _mm256_fmadd_ps(weight0, _mm256_set1_ps(scale00), acc0);
                }
                if scale10 != 0.0 {
                    acc1 = _mm256_fmadd_ps(weight0, _mm256_set1_ps(scale10), acc1);
                }
                if scale20 != 0.0 {
                    acc2 = _mm256_fmadd_ps(weight0, _mm256_set1_ps(scale20), acc2);
                }
                if scale30 != 0.0 {
                    acc3 = _mm256_fmadd_ps(weight0, _mm256_set1_ps(scale30), acc3);
                }

                let weight1 =
                    _mm256_loadu_ps(weights.as_ptr().add((column + 1) * output + output_offset));
                let scale01 = *inputs.get_unchecked(row_base * input + column + 1);
                let scale11 = *inputs.get_unchecked((row_base + 1) * input + column + 1);
                let scale21 = *inputs.get_unchecked((row_base + 2) * input + column + 1);
                let scale31 = *inputs.get_unchecked((row_base + 3) * input + column + 1);
                if scale01 != 0.0 {
                    acc0 = _mm256_fmadd_ps(weight1, _mm256_set1_ps(scale01), acc0);
                }
                if scale11 != 0.0 {
                    acc1 = _mm256_fmadd_ps(weight1, _mm256_set1_ps(scale11), acc1);
                }
                if scale21 != 0.0 {
                    acc2 = _mm256_fmadd_ps(weight1, _mm256_set1_ps(scale21), acc2);
                }
                if scale31 != 0.0 {
                    acc3 = _mm256_fmadd_ps(weight1, _mm256_set1_ps(scale31), acc3);
                }

                column += 2;
            }
            if column < input {
                let weight = _mm256_loadu_ps(weights.as_ptr().add(column * output + output_offset));
                let scale0 = *inputs.get_unchecked(row_base * input + column);
                let scale1 = *inputs.get_unchecked((row_base + 1) * input + column);
                let scale2 = *inputs.get_unchecked((row_base + 2) * input + column);
                let scale3 = *inputs.get_unchecked((row_base + 3) * input + column);
                if scale0 != 0.0 {
                    acc0 = _mm256_fmadd_ps(weight, _mm256_set1_ps(scale0), acc0);
                }
                if scale1 != 0.0 {
                    acc1 = _mm256_fmadd_ps(weight, _mm256_set1_ps(scale1), acc1);
                }
                if scale2 != 0.0 {
                    acc2 = _mm256_fmadd_ps(weight, _mm256_set1_ps(scale2), acc2);
                }
                if scale3 != 0.0 {
                    acc3 = _mm256_fmadd_ps(weight, _mm256_set1_ps(scale3), acc3);
                }
            }

            _mm256_storeu_ps(
                outs.as_mut_ptr().add(row_base * output + output_offset),
                acc0,
            );
            _mm256_storeu_ps(
                outs.as_mut_ptr()
                    .add((row_base + 1) * output + output_offset),
                acc1,
            );
            _mm256_storeu_ps(
                outs.as_mut_ptr()
                    .add((row_base + 2) * output + output_offset),
                acc2,
            );
            _mm256_storeu_ps(
                outs.as_mut_ptr()
                    .add((row_base + 3) * output + output_offset),
                acc3,
            );
            output_offset += 8;
        }

        while output_offset < output {
            let mut acc0 = *outs.get_unchecked(row_base * output + output_offset);
            let mut acc1 = *outs.get_unchecked((row_base + 1) * output + output_offset);
            let mut acc2 = *outs.get_unchecked((row_base + 2) * output + output_offset);
            let mut acc3 = *outs.get_unchecked((row_base + 3) * output + output_offset);
            let mut column = 0;
            while column + 2 <= input {
                let weight0 = *weights.get_unchecked(column * output + output_offset);
                let scale00 = *inputs.get_unchecked(row_base * input + column);
                let scale10 = *inputs.get_unchecked((row_base + 1) * input + column);
                let scale20 = *inputs.get_unchecked((row_base + 2) * input + column);
                let scale30 = *inputs.get_unchecked((row_base + 3) * input + column);
                if scale00 != 0.0 {
                    acc0 += weight0 * scale00;
                }
                if scale10 != 0.0 {
                    acc1 += weight0 * scale10;
                }
                if scale20 != 0.0 {
                    acc2 += weight0 * scale20;
                }
                if scale30 != 0.0 {
                    acc3 += weight0 * scale30;
                }

                let weight1 = *weights.get_unchecked((column + 1) * output + output_offset);
                let scale01 = *inputs.get_unchecked(row_base * input + column + 1);
                let scale11 = *inputs.get_unchecked((row_base + 1) * input + column + 1);
                let scale21 = *inputs.get_unchecked((row_base + 2) * input + column + 1);
                let scale31 = *inputs.get_unchecked((row_base + 3) * input + column + 1);
                if scale01 != 0.0 {
                    acc0 += weight1 * scale01;
                }
                if scale11 != 0.0 {
                    acc1 += weight1 * scale11;
                }
                if scale21 != 0.0 {
                    acc2 += weight1 * scale21;
                }
                if scale31 != 0.0 {
                    acc3 += weight1 * scale31;
                }

                column += 2;
            }
            if column < input {
                let weight = *weights.get_unchecked(column * output + output_offset);
                let scale0 = *inputs.get_unchecked(row_base * input + column);
                let scale1 = *inputs.get_unchecked((row_base + 1) * input + column);
                let scale2 = *inputs.get_unchecked((row_base + 2) * input + column);
                let scale3 = *inputs.get_unchecked((row_base + 3) * input + column);
                if scale0 != 0.0 {
                    acc0 += weight * scale0;
                }
                if scale1 != 0.0 {
                    acc1 += weight * scale1;
                }
                if scale2 != 0.0 {
                    acc2 += weight * scale2;
                }
                if scale3 != 0.0 {
                    acc3 += weight * scale3;
                }
            }
            *outs.get_unchecked_mut(row_base * output + output_offset) = acc0;
            *outs.get_unchecked_mut((row_base + 1) * output + output_offset) = acc1;
            *outs.get_unchecked_mut((row_base + 2) * output + output_offset) = acc2;
            *outs.get_unchecked_mut((row_base + 3) * output + output_offset) = acc3;
            output_offset += 1;
        }
    }

    for row in tiled_rows..rows {
        let out = &mut outs[row * output..(row + 1) * output];
        for column in 0..input {
            let scale = *inputs.get_unchecked(row * input + column);
            if scale == 0.0 {
                continue;
            }
            let weight_column = &weights[column * output..(column + 1) * output];
            add_scaled_in_place_avx2_fma(out, weight_column, scale);
        }
    }
}

#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
fn add_scaled_in_place_scalar(out: &mut [f32], weights: &[f32], scale: f32) {
    for (output, weight) in out.iter_mut().zip(weights) {
        *output += weight * scale;
    }
}

#[inline(always)]
fn dot_product(left: &[f32], right: &[f32]) -> f32 {
    debug_assert_eq!(left.len(), right.len());
    dot_product_arch(left, right)
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn dot_product_arch(left: &[f32], right: &[f32]) -> f32 {
    // SAFETY: aarch64 guarantees NEON support, and the helper only uses
    // unaligned loads within the bounds checked by its loop conditions.
    unsafe { dot_product_neon(left, right) }
}

#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn dot_product_arch(left: &[f32], right: &[f32]) -> f32 {
    if x86_avx2_fma_available() {
        // SAFETY: availability was checked above, and the helper only uses
        // unaligned loads within the bounds checked by its loops.
        unsafe { dot_product_avx2_fma(left, right) }
    } else {
        dot_product_scalar(left, right)
    }
}

#[cfg(all(not(target_arch = "aarch64"), not(target_arch = "x86_64")))]
#[inline(always)]
fn dot_product_arch(left: &[f32], right: &[f32]) -> f32 {
    dot_product_scalar(left, right)
}

#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn dot_product_neon(left: &[f32], right: &[f32]) -> f32 {
    use std::arch::aarch64::*;

    let mut offset = 0;
    let len = left.len();
    let mut acc0 = vdupq_n_f32(0.0);
    let mut acc1 = vdupq_n_f32(0.0);
    let mut acc2 = vdupq_n_f32(0.0);
    let mut acc3 = vdupq_n_f32(0.0);

    while offset + 16 <= len {
        let left_ptr = left.as_ptr().add(offset);
        let right_ptr = right.as_ptr().add(offset);
        acc0 = vfmaq_f32(acc0, vld1q_f32(left_ptr), vld1q_f32(right_ptr));
        acc1 = vfmaq_f32(
            acc1,
            vld1q_f32(left_ptr.add(4)),
            vld1q_f32(right_ptr.add(4)),
        );
        acc2 = vfmaq_f32(
            acc2,
            vld1q_f32(left_ptr.add(8)),
            vld1q_f32(right_ptr.add(8)),
        );
        acc3 = vfmaq_f32(
            acc3,
            vld1q_f32(left_ptr.add(12)),
            vld1q_f32(right_ptr.add(12)),
        );
        offset += 16;
    }

    let mut acc = vaddq_f32(vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3));
    while offset + 4 <= len {
        acc = vfmaq_f32(
            acc,
            vld1q_f32(left.as_ptr().add(offset)),
            vld1q_f32(right.as_ptr().add(offset)),
        );
        offset += 4;
    }

    let mut sum = vaddvq_f32(acc);
    while offset < len {
        sum += left[offset] * right[offset];
        offset += 1;
    }
    sum
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
unsafe fn dot_product_avx2_fma(left: &[f32], right: &[f32]) -> f32 {
    use std::arch::x86_64::*;

    let mut offset = 0;
    let len = left.len();
    let mut acc0 = _mm256_setzero_ps();
    let mut acc1 = _mm256_setzero_ps();
    let mut acc2 = _mm256_setzero_ps();
    let mut acc3 = _mm256_setzero_ps();

    while offset + 32 <= len {
        let left_ptr = left.as_ptr().add(offset);
        let right_ptr = right.as_ptr().add(offset);
        acc0 = _mm256_fmadd_ps(_mm256_loadu_ps(left_ptr), _mm256_loadu_ps(right_ptr), acc0);
        acc1 = _mm256_fmadd_ps(
            _mm256_loadu_ps(left_ptr.add(8)),
            _mm256_loadu_ps(right_ptr.add(8)),
            acc1,
        );
        acc2 = _mm256_fmadd_ps(
            _mm256_loadu_ps(left_ptr.add(16)),
            _mm256_loadu_ps(right_ptr.add(16)),
            acc2,
        );
        acc3 = _mm256_fmadd_ps(
            _mm256_loadu_ps(left_ptr.add(24)),
            _mm256_loadu_ps(right_ptr.add(24)),
            acc3,
        );
        offset += 32;
    }

    let mut acc = _mm256_add_ps(_mm256_add_ps(acc0, acc1), _mm256_add_ps(acc2, acc3));
    while offset + 8 <= len {
        acc = _mm256_fmadd_ps(
            _mm256_loadu_ps(left.as_ptr().add(offset)),
            _mm256_loadu_ps(right.as_ptr().add(offset)),
            acc,
        );
        offset += 8;
    }

    let mut lanes = [0.0_f32; 8];
    _mm256_storeu_ps(lanes.as_mut_ptr(), acc);
    let mut sum = lanes.iter().copied().sum::<f32>();
    while offset < len {
        sum += left[offset] * right[offset];
        offset += 1;
    }
    sum
}

#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
fn dot_product_scalar(left: &[f32], right: &[f32]) -> f32 {
    left.iter()
        .zip(right)
        .map(|(left, right)| left * right)
        .sum()
}

#[derive(Clone)] // Fushi: per-precision copies of the network (RwkvInference::new)
struct Norm {
    groups: usize,
    dim: usize,
    eps: f32,
    weight: Vec<f32>,
    bias: Vec<f32>,
}

impl Norm {
    fn apply(&self, input: &[f32]) -> Vec<f32> {
        let mut out = vec![0.0; self.dim];
        self.apply_into(input, &mut out);
        out
    }

    fn apply_into(&self, input: &[f32], out: &mut [f32]) {
        debug_assert_eq!(input.len(), self.dim);
        debug_assert_eq!(out.len(), self.dim);
        let group_size = self.dim / self.groups;

        for group in 0..self.groups {
            let start = group * group_size;
            let end = start + group_size;
            let values = &input[start..end];
            let mean = values.iter().sum::<f32>() / group_size as f32;
            let variance = values
                .iter()
                .map(|value| {
                    let diff = value - mean;
                    diff * diff
                })
                .sum::<f32>()
                / group_size as f32;
            let scale = (variance + self.eps).sqrt().recip();
            for index in start..end {
                out[index] = (input[index] - mean) * scale * self.weight[index] + self.bias[index];
            }
        }
    }

    #[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
    fn apply_batch(&self, input: &[f32], rows: usize, out: &mut Vec<f32>) {
        assert_eq!(input.len(), rows * self.dim);
        out.resize(rows * self.dim, 0.0);
        // Accumulate independent rows together, keeping each row's reduction
        // order unchanged so SIMD does not change normalization results.
        const LANES: usize = 4;
        let group_size = self.dim / self.groups;

        #[cfg(target_arch = "aarch64")]
        if group_size % 4 == 0 && group_size * self.groups == self.dim {
            assert!(self.weight.len() == self.dim && self.bias.len() == self.dim);
            let mut row = 0;
            // SAFETY: aarch64 guarantees NEON support. Each call reads and
            // writes the `4 * BLOCKS` complete rows starting at `row`, which
            // lie within the lengths checked above.
            unsafe {
                while row + 16 <= rows {
                    query_kernels::norm_rows_neon::<4>(
                        input.as_ptr().add(row * self.dim),
                        out.as_mut_ptr().add(row * self.dim),
                        self.dim,
                        self.groups,
                        self.eps,
                        &self.weight,
                        &self.bias,
                    );
                    row += 16;
                }
                while row + 4 <= rows {
                    query_kernels::norm_rows_neon::<1>(
                        input.as_ptr().add(row * self.dim),
                        out.as_mut_ptr().add(row * self.dim),
                        self.dim,
                        self.groups,
                        self.eps,
                        &self.weight,
                        &self.bias,
                    );
                    row += 4;
                }
            }
            out[row * self.dim..]
                .chunks_mut(self.dim)
                .zip(input[row * self.dim..].chunks(self.dim))
                .for_each(|(output, input)| self.apply_into(input, output));
            return;
        }

        let mut inputs = input.chunks_exact(self.dim * LANES);
        let mut outputs = out.chunks_exact_mut(self.dim * LANES);
        for (input, output) in inputs.by_ref().zip(outputs.by_ref()) {
            for group in 0..self.groups {
                let start = group * group_size;
                let end = start + group_size;
                let mut means = [-0.0; LANES];
                for channel in start..end {
                    for lane in 0..LANES {
                        means[lane] += input[lane * self.dim + channel];
                    }
                }
                for mean in &mut means {
                    *mean /= group_size as f32;
                }
                let mut scales = [-0.0; LANES];
                for channel in start..end {
                    for lane in 0..LANES {
                        let diff = input[lane * self.dim + channel] - means[lane];
                        scales[lane] += diff * diff;
                    }
                }
                for scale in &mut scales {
                    *scale = (*scale / group_size as f32 + self.eps).sqrt().recip();
                }
                for lane in 0..LANES {
                    for channel in start..end {
                        let index = lane * self.dim + channel;
                        output[index] =
                            (input[index] - means[lane]) * scales[lane] * self.weight[channel]
                                + self.bias[channel];
                    }
                }
            }
        }
        outputs
            .into_remainder()
            .chunks_mut(self.dim)
            .zip(inputs.remainder().chunks(self.dim))
            .for_each(|(output, input)| self.apply_into(input, output));
    }
}

fn single_timestep(
    r: &[f32],
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    k_deformed: &[f32],
    state: &[f32],
) -> (Vec<f32>, Vec<f32>) {
    let mut next_state = vec![0.0; HEADS * HEAD_SIZE * HEAD_SIZE];
    let mut out = vec![0.0; D_MODEL];
    single_timestep_into(r, k, v, w, a, k_deformed, state, &mut out, &mut next_state);
    (out, next_state)
}

#[allow(clippy::too_many_arguments)]
fn single_timestep_into(
    r: &[f32],
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    k_deformed: &[f32],
    state: &[f32],
    out: &mut [f32],
    next_state: &mut [f32],
) {
    debug_assert_eq!(state.len(), HEADS * HEAD_SIZE * HEAD_SIZE);
    debug_assert_eq!(next_state.len(), HEADS * HEAD_SIZE * HEAD_SIZE);
    debug_assert_eq!(out.len(), D_MODEL);

    for head in 0..HEADS {
        let head_base = head * HEAD_SIZE;
        let matrix_base = head * HEAD_SIZE * HEAD_SIZE;
        let mut state_dot_k = [0.0_f32; HEAD_SIZE];
        let key_deformed = &k_deformed[head_base..head_base + HEAD_SIZE];
        let receptance = &r[head_base..head_base + HEAD_SIZE];

        for (row, value) in state_dot_k.iter_mut().enumerate() {
            let row_start = matrix_base + row * HEAD_SIZE;
            let state_row = &state[row_start..row_start + HEAD_SIZE];
            *value = dot_product(state_row, key_deformed);
        }

        update_recurrence_head(
            &k[head_base..head_base + HEAD_SIZE],
            &v[head_base..head_base + HEAD_SIZE],
            &w[head_base..head_base + HEAD_SIZE],
            &a[head_base..head_base + HEAD_SIZE],
            key_deformed,
            &state[matrix_base..matrix_base + HEAD_SIZE * HEAD_SIZE],
            &state_dot_k,
            &mut next_state[matrix_base..matrix_base + HEAD_SIZE * HEAD_SIZE],
        );

        for row in 0..HEAD_SIZE {
            let row_start = matrix_base + row * HEAD_SIZE;
            let state_row = &next_state[row_start..row_start + HEAD_SIZE];
            out[head_base + row] = dot_product(state_row, receptance);
        }
    }
}

#[allow(clippy::too_many_arguments)]
#[inline(always)]
fn update_recurrence_head(
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    key_deformed: &[f32],
    state: &[f32],
    state_dot_k: &[f32; HEAD_SIZE],
    next_state: &mut [f32],
) {
    #[cfg(target_arch = "x86_64")]
    if x86_avx2_fma_available() {
        // SAFETY: availability was checked above. Every head is exactly
        // `HEAD_SIZE` square and `HEAD_SIZE` is a multiple of eight.
        unsafe {
            update_recurrence_head_avx2(k, v, w, a, key_deformed, state, state_dot_k, next_state);
        }
        return;
    }

    update_recurrence_head_scalar(k, v, w, a, key_deformed, state, state_dot_k, next_state);
}

#[allow(clippy::too_many_arguments)]
fn update_recurrence_head_scalar(
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    key_deformed: &[f32],
    state: &[f32],
    state_dot_k: &[f32; HEAD_SIZE],
    next_state: &mut [f32],
) {
    for row in 0..HEAD_SIZE {
        for column in 0..HEAD_SIZE {
            let old = state[row * HEAD_SIZE + column];
            next_state[row * HEAD_SIZE + column] = old * w[column]
                - state_dot_k[row] * a[column] * key_deformed[column]
                + v[row] * k[column];
        }
    }
}

#[cfg(target_arch = "x86_64")]
#[allow(clippy::too_many_arguments)]
#[target_feature(enable = "avx2")]
unsafe fn update_recurrence_head_avx2(
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    key_deformed: &[f32],
    state: &[f32],
    state_dot_k: &[f32; HEAD_SIZE],
    next_state: &mut [f32],
) {
    use std::arch::x86_64::*;

    debug_assert_eq!(k.len(), HEAD_SIZE);
    debug_assert_eq!(v.len(), HEAD_SIZE);
    debug_assert_eq!(w.len(), HEAD_SIZE);
    debug_assert_eq!(a.len(), HEAD_SIZE);
    debug_assert_eq!(key_deformed.len(), HEAD_SIZE);
    debug_assert_eq!(state.len(), HEAD_SIZE * HEAD_SIZE);
    debug_assert_eq!(next_state.len(), HEAD_SIZE * HEAD_SIZE);

    for row in 0..HEAD_SIZE {
        let state_dot = _mm256_set1_ps(state_dot_k[row]);
        let value = _mm256_set1_ps(v[row]);
        let row_base = row * HEAD_SIZE;
        for column in (0..HEAD_SIZE).step_by(8) {
            let old = _mm256_loadu_ps(state.as_ptr().add(row_base + column));
            let weighted = _mm256_mul_ps(old, _mm256_loadu_ps(w.as_ptr().add(column)));
            let penalty = _mm256_mul_ps(
                _mm256_mul_ps(state_dot, _mm256_loadu_ps(a.as_ptr().add(column))),
                _mm256_loadu_ps(key_deformed.as_ptr().add(column)),
            );
            let injected = _mm256_mul_ps(value, _mm256_loadu_ps(k.as_ptr().add(column)));
            let updated = _mm256_add_ps(_mm256_sub_ps(weighted, penalty), injected);
            _mm256_storeu_ps(next_state.as_mut_ptr().add(row_base + column), updated);
        }
    }
}

#[cfg(any(not(any(target_os = "macos", target_arch = "aarch64")), test))]
#[allow(clippy::too_many_arguments)]
fn single_timestep_query_into(
    r: &[f32],
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    k_deformed: &[f32],
    state: Option<&[f32]>,
    out: &mut [f32],
    next_row: &mut [f32],
) {
    debug_assert_eq!(out.len(), D_MODEL);
    debug_assert_eq!(next_row.len(), HEAD_SIZE);
    debug_assert!(
        state.is_none() || state.is_some_and(|state| state.len() == HEADS * HEAD_SIZE * HEAD_SIZE)
    );

    for head in 0..HEADS {
        let head_base = head * HEAD_SIZE;
        let matrix_base = head * HEAD_SIZE * HEAD_SIZE;
        let mut state_dot_k = [0.0_f32; HEAD_SIZE];
        let key_deformed = &k_deformed[head_base..head_base + HEAD_SIZE];
        let receptance = &r[head_base..head_base + HEAD_SIZE];

        if let Some(state) = state {
            for (row, value) in state_dot_k.iter_mut().enumerate() {
                let row_start = matrix_base + row * HEAD_SIZE;
                *value = dot_product(&state[row_start..row_start + HEAD_SIZE], key_deformed);
            }
        }

        for row in 0..HEAD_SIZE {
            for (column, next) in next_row.iter_mut().enumerate().take(HEAD_SIZE) {
                let channel = head_base + column;
                let matrix_index = matrix_base + row * HEAD_SIZE + column;
                let old = state.map_or(0.0, |state| state[matrix_index]);
                *next = old * w[channel] - state_dot_k[row] * a[channel] * k_deformed[channel]
                    + v[head_base + row] * k[channel];
            }
            out[head_base + row] = dot_product(next_row, receptance);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn single_timestep_query_fast_into(
    r: &[f32],
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    k_deformed: &[f32],
    state: Option<&[f32]>,
    out: &mut [f32],
) {
    assert!(
        [r, k, v, w, a, k_deformed]
            .iter()
            .all(|values| values.len() == D_MODEL)
            && out.len() == D_MODEL
    );
    assert!(
        state.is_none() || state.is_some_and(|state| state.len() == HEADS * HEAD_SIZE * HEAD_SIZE)
    );

    #[cfg(target_arch = "aarch64")]
    // SAFETY: aarch64 guarantees NEON support, and every slice length was
    // checked above; the kernel only reads and writes within those lengths.
    unsafe {
        query_kernels::single_timestep_query_fast_neon(r, k, v, w, a, k_deformed, state, out);
    }

    #[cfg(not(target_arch = "aarch64"))]
    single_timestep_query_fast_scalar(r, k, v, w, a, k_deformed, state, out);
}

/// Portable reference for `single_timestep_query_fast_into()`.
#[cfg(any(not(target_arch = "aarch64"), test))]
#[allow(clippy::too_many_arguments)]
fn single_timestep_query_fast_scalar(
    r: &[f32],
    k: &[f32],
    v: &[f32],
    w: &[f32],
    a: &[f32],
    k_deformed: &[f32],
    state: Option<&[f32]>,
    out: &mut [f32],
) {
    for head in 0..HEADS {
        let head_base = head * HEAD_SIZE;
        let matrix_base = head * HEAD_SIZE * HEAD_SIZE;
        let receptance = &r[head_base..head_base + HEAD_SIZE];
        let key = &k[head_base..head_base + HEAD_SIZE];
        let key_deformed = &k_deformed[head_base..head_base + HEAD_SIZE];
        let key_receptance = dot_product(key, receptance);

        let Some(state) = state else {
            for row in 0..HEAD_SIZE {
                out[head_base + row] = v[head_base + row] * key_receptance;
            }
            continue;
        };

        let mut decayed_receptance = [0.0; HEAD_SIZE];
        let mut adaptation_receptance = 0.0;
        for column in 0..HEAD_SIZE {
            let channel = head_base + column;
            decayed_receptance[column] = w[channel] * receptance[column];
            adaptation_receptance += a[channel] * key_deformed[column] * receptance[column];
        }

        for row in 0..HEAD_SIZE {
            let row_start = matrix_base + row * HEAD_SIZE;
            let state_row = &state[row_start..row_start + HEAD_SIZE];
            let state_dot_key = dot_product(state_row, key_deformed);
            let retained = dot_product(state_row, &decayed_receptance);
            out[head_base + row] = retained - state_dot_key * adaptation_receptance
                + v[head_base + row] * key_receptance;
        }
    }
}

fn normalize_heads_in_place(values: &mut [f32]) {
    for head in 0..HEADS {
        let start = head * HEAD_SIZE;
        let end = start + HEAD_SIZE;
        let norm = values[start..end]
            .iter()
            .map(|value| value * value)
            .sum::<f32>()
            .sqrt()
            .max(1e-12);
        for value in &mut values[start..end] {
            *value /= norm;
        }
    }
}

/// Writes row `row` of all eight time-mix inputs,
/// `mixed[mix] = lerp(x, x_shift, lerp_weights[mix])`, in one pass. Sharing
/// `x_shift - x` between the mixes keeps `lerp()`'s exact arithmetic.
#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn time_shift_mix_row(
    x: &[f32],
    x_shift: &[f32],
    lerp_weights: &[f32],
    mixed: &mut [Vec<f32>; 8],
    row: usize,
) {
    assert!(x.len() == D_MODEL && x_shift.len() == D_MODEL);
    assert_eq!(lerp_weights.len(), mixed.len() * D_MODEL);
    let mut shift_delta = [0.0; D_MODEL];
    for channel in 0..D_MODEL {
        shift_delta[channel] = x_shift[channel] - x[channel];
    }
    for (mixed, weights) in mixed.iter_mut().zip(lerp_weights.chunks_exact(D_MODEL)) {
        let mixed = &mut mixed[row * D_MODEL..(row + 1) * D_MODEL];
        for channel in 0..D_MODEL {
            mixed[channel] = x[channel] + weights[channel] * shift_delta[channel];
        }
    }
}

/// `normalize_heads_in_place()` followed by `scale_heads_in_place()`.
#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn normalize_scale_heads_in_place(values: &mut [f32], scales: &[f32]) {
    assert!(values.len() == D_MODEL && scales.len() == HEADS);

    #[cfg(target_arch = "aarch64")]
    // SAFETY: aarch64 guarantees NEON support, and both lengths were checked
    // above; the kernel only accesses elements within them.
    unsafe {
        query_kernels::normalize_scale_heads_neon(values, scales);
    }

    #[cfg(not(target_arch = "aarch64"))]
    {
        normalize_heads_in_place(values);
        scale_heads_in_place(values, scales);
    }
}

/// Adds the per-head bonus to the group-normed recurrence output and applies
/// the output gate: `output = g * (output + sum_head(r * bonus * k) * v)`.
#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn bonus_gate_in_place(
    output: &mut [f32],
    r: &[f32],
    bonus: &[f32],
    k: &[f32],
    v: &[f32],
    g: &[f32],
) {
    assert!([&*output, r, bonus, k, v, g]
        .iter()
        .all(|values| values.len() == D_MODEL));

    #[cfg(target_arch = "aarch64")]
    // SAFETY: aarch64 guarantees NEON support, and every length was checked
    // above; the kernel only accesses elements within them.
    unsafe {
        query_kernels::bonus_gate_neon(output, r, bonus, k, v, g);
    }

    #[cfg(not(target_arch = "aarch64"))]
    bonus_gate_scalar(output, r, bonus, k, v, g);
}

/// Portable reference for `bonus_gate_in_place()`.
#[cfg(any(all(target_os = "macos", not(target_arch = "aarch64")), test))]
fn bonus_gate_scalar(
    output: &mut [f32],
    r: &[f32],
    bonus: &[f32],
    k: &[f32],
    v: &[f32],
    g: &[f32],
) {
    for head in 0..HEADS {
        let head_base = head * HEAD_SIZE;
        let mut bonus_scale = 0.0;
        for channel in head_base..head_base + HEAD_SIZE {
            bonus_scale += r[channel] * bonus[channel] * k[channel];
        }
        for channel in head_base..head_base + HEAD_SIZE {
            output[channel] = g[channel] * (output[channel] + bonus_scale * v[channel]);
        }
    }
}

#[cfg(any(all(target_os = "macos", not(target_arch = "aarch64")), test))]
fn scale_heads_in_place(values: &mut [f32], scales: &[f32]) {
    debug_assert_eq!(values.len(), D_MODEL);
    debug_assert_eq!(scales.len(), HEADS);
    for head in 0..HEADS {
        for index in 0..HEAD_SIZE {
            values[head * HEAD_SIZE + index] *= scales[head];
        }
    }
}

fn softmax(input: &[f32]) -> Vec<f32> {
    let max = input
        .iter()
        .copied()
        .fold(f32::NEG_INFINITY, |a, b| a.max(b));
    let mut out = input
        .iter()
        .map(|value| (*value - max).exp())
        .collect::<Vec<_>>();
    let sum = out.iter().sum::<f32>();
    for value in &mut out {
        *value /= sum;
    }
    out
}

fn softmax_into(input: &[f32], out: &mut [f32]) {
    debug_assert_eq!(input.len(), out.len());
    let max = input
        .iter()
        .copied()
        .fold(f32::NEG_INFINITY, |a, b| a.max(b));
    for (output, value) in out.iter_mut().zip(input) {
        *output = (*value - max).exp();
    }
    let sum = out.iter().sum::<f32>();
    for value in out {
        *value /= sum;
    }
}

fn sigmoid_in_place(values: &mut [f32]) {
    for value in values {
        *value = sigmoid(*value);
    }
}

fn sigmoid(value: f32) -> f32 {
    if value >= 0.0 {
        1.0 / (1.0 + (-value).exp())
    } else {
        let exp = value.exp();
        exp / (1.0 + exp)
    }
}

// exp(-0.5), rounded to f32.
#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
const QUERY_DECAY_SCALE: f32 = 0.606_530_67;

/// Scalar reference for `query_decay_batch_in_place()`, which also uses it off
/// macOS (phones).
#[cfg(any(all(target_arch = "aarch64", not(target_os = "macos")), test))]
fn query_decay(value: f32) -> f32 {
    // exp(-exp(-0.5 - softplus(-x))) = exp(-exp(-0.5) * sigmoid(x)).
    // Query-only: recurrent state updates keep their original arithmetic.
    (-QUERY_DECAY_SCALE * sigmoid(value)).exp()
}

// Batched query-only activations. On macOS they use Accelerate's vectorized
// transcendental functions, which may differ from the scalar ones in the last
// bit; answer rows and warm-up state updates keep the scalar functions.

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn query_sigmoid_batch_in_place(values: &mut [f32]) {
    #[cfg(target_os = "macos")]
    matmul::sigmoid_in_place(values);
    #[cfg(not(target_os = "macos"))]
    sigmoid_in_place(values);
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn query_silu_batch_in_place(values: &mut [f32]) {
    #[cfg(target_os = "macos")]
    matmul::silu_in_place(values);
    #[cfg(not(target_os = "macos"))]
    silu_in_place(values);
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn query_tanh_batch_in_place(values: &mut [f32]) {
    #[cfg(target_os = "macos")]
    matmul::tanh_in_place(values);
    #[cfg(not(target_os = "macos"))]
    values.iter_mut().for_each(|value| *value = value.tanh());
}

#[cfg(any(target_os = "macos", target_arch = "aarch64", test))]
fn query_decay_batch_in_place(values: &mut [f32]) {
    #[cfg(target_os = "macos")]
    matmul::scaled_sigmoid_decay_in_place(values, QUERY_DECAY_SCALE);
    #[cfg(not(target_os = "macos"))]
    values
        .iter_mut()
        .for_each(|value| *value = query_decay(*value));
}

fn softplus(value: f32) -> f32 {
    if value > 20.0 {
        value
    } else if value < -20.0 {
        value.exp()
    } else {
        value.exp().ln_1p()
    }
}

fn silu_in_place(values: &mut [f32]) {
    for value in values {
        *value *= sigmoid(*value);
    }
}

fn relu_in_place(values: &mut [f32]) {
    for value in values {
        *value = value.max(0.0);
    }
}

fn lerp(start: f32, end: f32, weight: f32) -> f32 {
    start + weight * (end - start)
}
