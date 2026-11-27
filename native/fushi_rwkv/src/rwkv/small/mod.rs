// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: runtime for the small RWKV models (d_model 64; the Instant-Only
//! Small `sm113`, 331,511 parameters, and six-layer Tiny `sm130io`, 185,057,
//! from JSchoreels/anki `qt/aqt/rwkv_inference/`). Not upstream code: written for Fushi from
//! the INTEGRATION.md and NumPy reference of package sm40v2. The network is
//! built from the weight file's tensor directory (layers per stream, which
//! layers have a channel mixer, the layer-major `layer_steps`), so the
//! same-architecture retrains (SM56 ... SM98, SM113) and the six-layer Tiny
//! "w64-c1-d2p1u1" (sm130io) load alike; layer counts outside the known
//! plans are refused (`model.rs` `LAYER_PLANS`).
//!
//! It shares the input side with the big model unchanged (the 92 features of
//! [FeatureState], ID codes and all; the model ignores feature 22 and, by the
//! SM72 leak-free rule, the missing-id flags 13–15) and keeps
//! the same contract: answered reviews are replayed in order, queries read
//! the states without changing them. A replayed review's prediction query uses
//! the show-time interval (§6.10). Only the instant / rating head is used: the
//! curve head of an Instant-Only model was never trained.

mod model;
mod weights;

use std::io;
use std::sync::Arc;

use super::slots::SlotStore;
use super::{
    CARD_FEATURES, FeatureState, ID_PLACEHOLDER, ReviewInput, RwkvStats, SnapshotReader,
    StatePrecision, read_runtime_feature_state,
};
pub use model::SmallHeads;
use model::{COMPACT_STREAMS, Layout, Rows, STREAMS, SmallNet};
use weights::Weights;

/// Answered reviews per engine call. A call holds about 2.2 KB of scratch
/// per row (twice the rows when predictions are recorded), so 4,096 reviews
/// stay under 20 MB, and the states touched are encoded back once per call.
const CHUNK_REVIEWS: usize = 4096;

/// Version 2 (2026-11-26): states computed with the platform-independent
/// arithmetic of `det`. Version 1 snapshots hold states from the old
/// per-platform kernels and libm; they are refused, so the host replays the
/// review log once and every device continues from identical states.
pub(crate) const SNAPSHOT_MAGIC: &[u8] = b"FRWKVSMALL2\0";

/// The parsed small network, shareable between runtimes.
#[derive(Clone)]
pub struct SmallModel {
    net: Arc<SmallNet>,
    fingerprint: u64,
}

impl SmallModel {
    /// Whether `bytes` holds the small model's weights (cheap: reads the
    /// tensor directory only). Errors when it is no weight file at all.
    pub fn is_small_model_file(bytes: &[u8]) -> io::Result<bool> {
        Weights::is_small_model_file(bytes)
    }

    /// Parses an `ARWKVWEIGHTS1` (f32) or `ARWKVWEIGHTS8PC1` (int8 per-row)
    /// weight file of the small model.
    pub fn from_bytes(bytes: &[u8]) -> io::Result<Self> {
        let weights = Weights::parse(bytes)?;
        if !SmallNet::is_small(&weights) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "not a small-model RWKV weight file",
            ));
        }
        Ok(Self {
            net: Arc::new(SmallNet::load(weights)?),
            fingerprint: fnv1a(bytes),
        })
    }

    /// The interleaved layer schedule, (stream, layer) in order (13 steps for
    /// "w64", 6 for the six-layer Tiny).
    #[doc(hidden)]
    pub fn layer_steps(&self) -> Vec<(usize, usize)> {
        self.net.steps().to_vec()
    }

    /// FNV-1a 64 of the weight file: snapshots carry it, so states built with
    /// other weights (another file, or the f32 vs the int8 file) are refused.
    pub fn fingerprint(&self) -> u64 {
        self.fingerprint
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &b| {
        (hash ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// The precision a stream is stored at: card and note streams at the
/// runtime's, deck / preset / user in f32.
fn stream_precision(stream: usize, precision: StatePrecision) -> StatePrecision {
    if COMPACT_STREAMS.contains(&stream) {
        precision
    } else {
        StatePrecision::F32
    }
}

/// Fushi: what one journaled review overwrote (the five stream states it
/// touched, `None` = the entity had none yet, and the feature bookkeeping).
pub struct SmallUndo {
    keys: [i64; STREAMS],
    prior: [Option<Vec<u8>>; STREAMS],
    features: super::FeatureUndo,
}

impl SmallUndo {
    /// (card, note) keys whose states this entry restores.
    pub fn affected(&self) -> (i64, i64) {
        (self.keys[0], self.keys[2])
    }

    /// Bytes this entry holds (the journal is capped by it).
    pub fn bytes(&self) -> usize {
        self.prior.iter().flatten().map(Vec::len).sum::<usize>() + 256
    }
}

pub struct SmallInference {
    model: SmallModel,
    precision: StatePrecision,
    layouts: [Layout; STREAMS],
    stores: [SlotStore; STREAMS],
    features: FeatureState,
}

impl SmallInference {
    pub fn new(model: &SmallModel, precision: StatePrecision) -> Self {
        let layouts: [Layout; STREAMS] = std::array::from_fn(|stream| {
            model
                .net
                .layout(stream, stream_precision(stream, precision))
        });
        let stores = std::array::from_fn(|stream| SlotStore::new(layouts[stream].slot_len));
        Self {
            model: model.clone(),
            precision,
            layouts,
            stores,
            features: FeatureState::default(),
        }
    }

    pub fn precision(&self) -> StatePrecision {
        self.precision
    }

    /// The model rows of one answered review, as replay feeds them: with
    /// `record_predictions` first the query asked just before it (show-time
    /// intervals, INTEGRATION.md §6.10, [super::show_time_query]), then the
    /// update row (answer-to-answer interval), whose bookkeeping is committed.
    /// Query features come first, as in the big model's replay, so first-seen
    /// ID codes are drawn in the same order. The one place replay rows are
    /// built ([Self::warm_up_reviews], [Self::replay_features]).
    fn push_replay_rows(
        &mut self,
        input: &ReviewInput,
        record_predictions: bool,
        features: &mut Vec<f32>,
        keys: &mut Vec<[i64; STREAMS]>,
        commit: &mut Vec<bool>,
    ) {
        if record_predictions {
            features.extend(self.features.features_for(&super::show_time_query(input)));
            keys.push(stream_keys(input));
            commit.push(false);
        }
        features.extend(self.features.features_for(input));
        self.features.store_review(input);
        keys.push(stream_keys(input));
        commit.push(true);
    }

    /// Test hook: the 92 inputs replay with predictions builds for each
    /// answered review of `reviews`, `(index, query row, update row)`, through
    /// the same builder as [Self::warm_up_reviews]. Advances only the feature
    /// bookkeeping (not the network states): use a scratch runtime.
    #[doc(hidden)]
    pub fn replay_features(&mut self, reviews: &[ReviewInput]) -> Vec<(usize, Vec<f32>, Vec<f32>)> {
        let mut out = Vec::new();
        for (index, input) in reviews.iter().enumerate() {
            if input.ease.is_none() {
                continue;
            }
            let (mut features, mut keys, mut commit) = (Vec::new(), Vec::new(), Vec::new());
            self.push_replay_rows(input, true, &mut features, &mut keys, &mut commit);
            let update = features.split_off(CARD_FEATURES);
            out.push((index, features, update));
        }
        out
    }

    /// Same contract as the big model's `warm_up_reviews`: rating-less rows
    /// are skipped; with `record_predictions` every answered row also gets the
    /// R a query just before it would have given (index into `reviews`); that
    /// query uses the show-time interval the model was trained on
    /// ([Self::push_replay_rows]).
    pub fn warm_up_reviews(
        &mut self,
        reviews: Vec<ReviewInput>,
        record_predictions: bool,
    ) -> io::Result<Vec<(usize, f32)>> {
        let answered: Vec<(usize, ReviewInput)> = reviews
            .into_iter()
            .enumerate()
            .filter(|(_, input)| input.ease.is_some())
            .collect();
        let mut predictions = Vec::new();
        for chunk in answered.chunks(CHUNK_REVIEWS) {
            let lanes = if record_predictions { 2 } else { 1 };
            let rows = chunk.len() * lanes;
            let mut features = Vec::with_capacity(rows * CARD_FEATURES);
            let mut keys = Vec::with_capacity(rows);
            let mut commit = Vec::with_capacity(rows);
            for (_, input) in chunk {
                self.push_replay_rows(
                    input,
                    record_predictions,
                    &mut features,
                    &mut keys,
                    &mut commit,
                );
            }
            // Heads only for the queries (an update row's own output is unused).
            let heads: Vec<bool> = commit.iter().map(|&c| !c).collect();
            let out = model::run(
                &self.model.net,
                &self.layouts,
                &mut self.stores,
                &Rows {
                    features: &features,
                    keys: &keys,
                    commit: &commit,
                    heads: &heads,
                },
                false,
                true,
            );
            if record_predictions {
                for ((index, _), heads) in chunk.iter().zip(out.chunks_exact(2)) {
                    predictions.push((*index, heads[0].retrievability()));
                }
            }
        }
        Ok(predictions)
    }

    /// Fushi: replays one answered review exactly as [Self::warm_up_reviews]
    /// would (a chunk of one row; chunk boundaries do not change results) and
    /// returns what it overwrote, for [Self::rewind].
    pub fn append_journaled(&mut self, input: ReviewInput) -> io::Result<SmallUndo> {
        let keys = stream_keys(&input);
        let prior: [Option<Vec<u8>>; STREAMS] =
            std::array::from_fn(|stream| self.stores[stream].get(keys[stream]).map(<[u8]>::to_vec));
        let mut features_undo = self.features.checkpoint(&input);
        self.warm_up_reviews(vec![input], false)?;
        self.features.seal(&mut features_undo);
        Ok(SmallUndo {
            keys,
            prior,
            features: features_undo,
        })
    }

    /// Fushi: undoes the last [Self::append_journaled] whose journal entry
    /// this is; entries must be rewound newest first.
    pub fn rewind(&mut self, undo: SmallUndo) {
        for (stream, prior) in undo.prior.into_iter().enumerate() {
            let id = undo.keys[stream];
            match prior {
                Some(bytes) => self.stores[stream]
                    .get_or_insert(id)
                    .copy_from_slice(&bytes),
                None => {
                    self.stores[stream].take(id);
                }
            }
        }
        self.features.rewind(undo.features);
    }

    /// R of each query (all must be queries); no state changes apart from the
    /// ID codes of first-seen entities, as in the big model.
    pub fn predict_retrievability_many_from_warm_up(
        &mut self,
        inputs: Vec<ReviewInput>,
    ) -> io::Result<Vec<f32>> {
        Ok(self
            .query_heads(&inputs, false)?
            .iter()
            .map(SmallHeads::retrievability)
            .collect())
    }

    /// R of `answer`'s card at each of `queries` had `answer` been given with
    /// each rating in `ratings` (see the big model's `forecast`). Nothing is
    /// kept. Result: `ratings.len() * queries.len()` values, rating-major.
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
            let mut features = self.features.features_for(&answer);
            self.features.with_hypothetical_review(&answer, |state| {
                for query in queries {
                    features.extend(state.features_for(query));
                }
            });
            let rows = 1 + queries.len();
            let mut keys = vec![stream_keys(&answer)];
            keys.extend(queries.iter().map(stream_keys));
            let mut commit = vec![false; rows];
            commit[0] = true;
            let mut heads = vec![true; rows];
            heads[0] = false;
            let result = model::run(
                &self.model.net,
                &self.layouts,
                &mut self.stores,
                &Rows {
                    features: &features,
                    keys: &keys,
                    commit: &commit,
                    heads: &heads,
                },
                false,
                false,
            );
            out.extend(result[1..].iter().map(SmallHeads::retrievability));
        }
        Ok(out)
    }

    // No `answer_curves` (RWKV-Curve) here: the small models Fushi runs are
    // Instant-Only (sm113 / sm130io, trained with curve_loss_weight 0.0), whose
    // curve head was never trained. `ModelKind::has_trained_curve_head`.

    fn query_heads(&mut self, inputs: &[ReviewInput], curve: bool) -> io::Result<Vec<SmallHeads>> {
        if inputs.iter().any(|input| !input.is_query) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "RWKV batched retrievability prediction only supports query inputs",
            ));
        }
        let mut out = Vec::with_capacity(inputs.len());
        for chunk in inputs.chunks(2 * CHUNK_REVIEWS) {
            let features: Vec<f32> = chunk
                .iter()
                .flat_map(|input| self.features.features_for(input))
                .collect();
            let keys: Vec<_> = chunk.iter().map(stream_keys).collect();
            let commit = vec![false; chunk.len()];
            let heads = vec![true; chunk.len()];
            out.extend(model::run(
                &self.model.net,
                &self.layouts,
                &mut self.stores,
                &Rows {
                    features: &features,
                    keys: &keys,
                    commit: &commit,
                    heads: &heads,
                },
                curve,
                true,
            ));
        }
        Ok(out)
    }

    /// Test hook: runs prepared model inputs (INTEGRATION.md §13 test-vector
    /// rows: features, entity keys, update vs query) through this runtime's
    /// states, `chunk` rows per engine call, returning every row's heads with
    /// the curve head. Bypasses the feature builder.
    #[doc(hidden)]
    pub fn run_prepared_rows(
        &mut self,
        features: &[f32],
        keys: &[[i64; 5]],
        commit: &[bool],
        chunk: usize,
    ) -> Vec<SmallHeads> {
        let mut out = Vec::with_capacity(keys.len());
        let mut start = 0;
        while start < keys.len() {
            let end = (start + chunk.max(1)).min(keys.len());
            let heads = vec![true; end - start];
            out.extend(model::run(
                &self.model.net,
                &self.layouts,
                &mut self.stores,
                &Rows {
                    features: &features[start * CARD_FEATURES..end * CARD_FEATURES],
                    keys: &keys[start..end],
                    commit: &commit[start..end],
                    heads: &heads,
                },
                true,
                true,
            ));
            start = end;
        }
        out
    }

    /// Largest absolute WKV value per layer of an entity's stored state, or
    /// `None` when it has none (`stream`: 0 card, 1 deck, 2 note, 3 preset,
    /// 4 user with id 0). For the long-history stability checks.
    #[doc(hidden)]
    pub fn state_peaks(&self, stream: usize, id: i64) -> Option<Vec<f32>> {
        let bytes = self.stores[stream].get(id)?;
        Some(self.layouts[stream].matrix_peaks(bytes))
    }

    /// Largest absolute WKV value over every stored state of `stream`.
    #[doc(hidden)]
    pub fn stream_peak(&self, stream: usize) -> f32 {
        let store = &self.stores[stream];
        store
            .ids()
            .into_iter()
            .filter_map(|id| store.get(id))
            .flat_map(|bytes| self.layouts[stream].matrix_peaks(bytes))
            .fold(0.0, f32::max)
    }

    /// Ids with a stored state in `stream` (see [Self::state_peaks]).
    #[doc(hidden)]
    pub fn state_ids(&self, stream: usize) -> Vec<i64> {
        self.stores[stream].ids()
    }

    pub fn reset(&mut self) {
        self.stores.iter_mut().for_each(SlotStore::clear);
        self.features = FeatureState::default();
    }

    pub fn last_day_offset(&self) -> Option<i64> {
        Some(self.features.first_day_offset? + self.features.previous_day_offset?)
    }

    /// `FRWKVSMALL2\0`, precision byte (0 / 8 / 4), weight fingerprint (u64),
    /// then per stream (card, deck, note, preset, user): slot length (u32),
    /// count (u32), states by ascending id (i64 id + slot bytes); then u32
    /// length + the `ARWKVPROCSTATE2` feature cache. Lossless.
    pub fn snapshot(&self) -> Vec<u8> {
        let state_bytes: usize = self
            .stores
            .iter()
            .map(|s| s.len() * (8 + s.slot_len()))
            .sum();
        let feature_len = b"ARWKVPROCSTATE2".len() + self.features.cache_state_len() + 4;
        let mut out = Vec::with_capacity(64 + state_bytes + feature_len);
        self.write_snapshot(&mut out)
            .expect("writing to a Vec should not fail");
        out
    }

    /// Writes the lossless byte snapshot format without a whole-file buffer.
    pub fn write_snapshot(&self, out: &mut impl io::Write) -> io::Result<()> {
        out.write_all(SNAPSHOT_MAGIC)?;
        out.write_all(&[super::precision_code(self.precision)])?;
        out.write_all(&self.model.fingerprint.to_le_bytes())?;
        for store in &self.stores {
            super::write_snapshot_u32(out, store.slot_len())?;
            let ids = store.ids();
            super::write_snapshot_u32(out, ids.len())?;
            for id in ids {
                out.write_all(&id.to_le_bytes())?;
                out.write_all(store.get(id).unwrap())?;
            }
        }
        let feature_len = b"ARWKVPROCSTATE2".len() + self.features.cache_state_len() + 4;
        super::write_snapshot_u32(out, feature_len)?;
        out.write_all(b"ARWKVPROCSTATE2")?;
        self.features.write_cache_state_to(out)?;
        out.write_all(&0u32.to_le_bytes())
    }

    // Previous whole-buffer encoder, used only to pin the on-disk format.
    #[cfg(test)]
    pub(crate) fn legacy_snapshot(&self) -> Vec<u8> {
        let mut features = Vec::new();
        features.extend_from_slice(b"ARWKVPROCSTATE2");
        self.features.write_cache_state_to(&mut features).unwrap();
        features.extend_from_slice(&0u32.to_le_bytes());
        let mut out = Vec::new();
        out.extend_from_slice(SNAPSHOT_MAGIC);
        out.push(super::precision_code(self.precision));
        out.extend_from_slice(&self.model.fingerprint.to_le_bytes());
        for store in &self.stores {
            out.extend_from_slice(&(store.slot_len() as u32).to_le_bytes());
            let ids = store.ids();
            out.extend_from_slice(&(ids.len() as u32).to_le_bytes());
            for id in ids {
                out.extend_from_slice(&id.to_le_bytes());
                out.extend_from_slice(store.get(id).unwrap());
            }
        }
        out.extend_from_slice(&(features.len() as u32).to_le_bytes());
        out.extend_from_slice(&features);
        out
    }

    /// Replaces the state with a [Self::snapshot]; nothing changes on error.
    pub fn restore_snapshot(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.read_snapshot(&mut io::Cursor::new(bytes), bytes.len() as u64)
    }

    /// Bounded decoder shared with the byte API. Errors preserve the old state.
    pub fn read_snapshot(&mut self, input: &mut impl io::Read, len: u64) -> io::Result<()> {
        let invalid =
            |message: &str| io::Error::new(io::ErrorKind::InvalidData, message.to_owned());
        let mut cursor = SnapshotReader::new(input, len);
        cursor.expect_magic(SNAPSHOT_MAGIC).map_err(|_| {
            invalid(
                "not a current small-model RWKV snapshot (a big-model snapshot, a version-1 \
                 snapshot from before the platform-independent arithmetic, or damaged bytes)",
            )
        })?;
        if cursor.u8()? != super::precision_code(self.precision) {
            return Err(invalid(
                "RWKV snapshot was taken with another state precision",
            ));
        }
        let mut fingerprint = [0u8; 8];
        fingerprint.copy_from_slice(cursor.bytes(8)?);
        if u64::from_le_bytes(fingerprint) != self.model.fingerprint {
            return Err(invalid("RWKV snapshot was taken with other model weights"));
        }
        let mut stores: [SlotStore; STREAMS] =
            std::array::from_fn(|stream| SlotStore::new(self.layouts[stream].slot_len));
        for (stream, store) in stores.iter_mut().enumerate() {
            let layout = &self.layouts[stream];
            if cursor.u32()? as usize != layout.slot_len {
                return Err(invalid("RWKV snapshot state size does not match the model"));
            }
            let count = cursor.count(8 + layout.slot_len)?;
            let mut previous = None;
            for _ in 0..count {
                let id = cursor.i64()?;
                if previous.is_some_and(|previous| id <= previous) {
                    return Err(invalid("RWKV snapshot ids are not ascending"));
                }
                previous = Some(id);
                let state = cursor.bytes(layout.slot_len)?;
                layout.validate(state)?;
                store.get_or_insert(id).copy_from_slice(state);
            }
        }
        let len = cursor.u32()? as usize;
        let features = read_runtime_feature_state(cursor.bytes(len)?)?;
        cursor.expect_end()?;
        self.stores = stores;
        self.features = features;
        Ok(())
    }

    pub fn stats(&self) -> RwkvStats {
        let [card, deck, note, preset, user] = &self.stores;
        RwkvStats {
            reviews: self.features.review_index,
            cards: card.len(),
            notes: note.len(),
            decks: deck.len(),
            presets: preset.len(),
            card_state_bytes: card.state_bytes(),
            note_state_bytes: note.state_bytes(),
            shared_state_bytes: deck.state_bytes() + preset.state_bytes() + user.state_bytes(),
            feature_state_bytes: b"ARWKVPROCSTATE2".len() + self.features.cache_state_len() + 4,
        }
    }
}

/// The entity of each stream a review belongs to. Missing ids map to the
/// training data's placeholders (INTEGRATION.md §6.1): one shared deck /
/// preset entity, and a note per card; the user stream is the collection.
fn stream_keys(input: &ReviewInput) -> [i64; STREAMS] {
    [
        input.card_id,
        input.deck_id.unwrap_or(ID_PLACEHOLDER),
        input.note_id.unwrap_or(ID_PLACEHOLDER + input.card_id),
        input.preset_id.unwrap_or(ID_PLACEHOLDER),
        0,
    ]
}
