// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: runtime for the small RWKV model (331,511 parameters, d_model 64,
//! JSchoreels/anki-rwkv release `small-model-sm56-2026-10-24`, package
//! sm56). Not upstream code: written for Fushi from the INTEGRATION.md and
//! NumPy reference of package sm40v2; sm56 retrains the same architecture
//! (identical `architecture.json` and reference code, new weights).
//!
//! It shares the input side with the big model unchanged (the 92 features of
//! [FeatureState], ID codes and all; the model ignores feature 22) and keeps
//! the same contract: answered reviews are replayed in order, queries read
//! the states without changing them.

mod model;
mod weights;

use std::io;
use std::sync::Arc;

use super::{
    read_runtime_feature_state, SnapshotReader, FeatureState, ReviewInput, RwkvStats, StatePrecision,
    CARD_FEATURES, ID_PLACEHOLDER,
};
pub use model::SmallHeads;
use model::{Layout, Rows, SmallNet, COMPACT_STREAMS, STREAMS};
use super::slots::SlotStore;
use weights::Weights;

/// Answered reviews per engine call. A call holds about 2.2 KB of scratch
/// per row (twice the rows when predictions are recorded), so 4,096 reviews
/// stay under 20 MB, and the states touched are encoded back once per call.
const CHUNK_REVIEWS: usize = 4096;

const SNAPSHOT_MAGIC: &[u8] = b"FRWKVSMALL1\0";

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

    /// The 13-step interleaved layer schedule, (stream, layer) in order.
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
        let layouts: [Layout; STREAMS] =
            std::array::from_fn(|stream| model.net.layout(stream, stream_precision(stream, precision)));
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

    /// Same contract as the big model's `warm_up_reviews`: rating-less rows
    /// are skipped; with `record_predictions` every answered row also gets the
    /// R a query just before it would have given (index into `reviews`).
    /// Diagnostic replay (examples/curve_calibration.rs): like
    /// [Self::warm_up_reviews] with predictions, but also returns each
    /// answered row's own heads with the curve, i.e. the forgetting curve that
    /// scheduling would read after that answer. `(index, p_imm before the
    /// answer, heads of the answer row)`.
    #[doc(hidden)]
    pub fn replay_with_curves(&mut self, reviews: Vec<ReviewInput>) -> io::Result<Vec<(usize, f32, SmallHeads)>> {
        let answered: Vec<(usize, ReviewInput)> = reviews
            .into_iter()
            .enumerate()
            .filter(|(_, input)| input.ease.is_some())
            .collect();
        let mut out = Vec::with_capacity(answered.len());
        for chunk in answered.chunks(CHUNK_REVIEWS) {
            let mut features = Vec::with_capacity(2 * chunk.len() * CARD_FEATURES);
            let mut keys = Vec::with_capacity(2 * chunk.len());
            let mut commit = Vec::with_capacity(2 * chunk.len());
            for (_, input) in chunk {
                let mut query = input.clone();
                query.is_query = true;
                query.ease = None;
                query.duration_millis = None;
                features.extend(self.features.features_for(&query));
                keys.push(stream_keys(input));
                commit.push(false);
                features.extend(self.features.features_for(input));
                self.features.store_review(input);
                keys.push(stream_keys(input));
                commit.push(true);
            }
            let heads = vec![true; commit.len()];
            let rows = model::run(
                &self.model.net,
                &self.layouts,
                &mut self.stores,
                &Rows {
                    features: &features,
                    keys: &keys,
                    commit: &commit,
                    heads: &heads,
                },
                true,
                true,
            );
            for ((index, _), pair) in chunk.iter().zip(rows.chunks_exact(2)) {
                out.push((*index, pair[0].retrievability(), pair[1]));
            }
        }
        Ok(out)
    }

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
            let mut heads = Vec::with_capacity(rows);
            for (_, input) in chunk {
                // Query features before answer features, as the big model's
                // replay does, so first-seen ID codes come in the same order.
                if record_predictions {
                    let mut query = input.clone();
                    query.is_query = true;
                    query.ease = None;
                    query.duration_millis = None;
                    features.extend(self.features.features_for(&query));
                    keys.push(stream_keys(input));
                    commit.push(false);
                    heads.push(true);
                }
                features.extend(self.features.features_for(input));
                self.features.store_review(input);
                keys.push(stream_keys(input));
                commit.push(true);
                heads.push(false);
            }
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
                Some(bytes) => self.stores[stream].get_or_insert(id).copy_from_slice(&bytes),
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

    /// The heads (with the curve) of `answer` answered Again / Hard / Good /
    /// Easy: four what-if update rows from the current states in one call,
    /// none committed (a row's own output does not depend on whether it
    /// commits), nothing kept. INTEGRATION.md §9.2 "intervals for each
    /// possible answer".
    pub fn answer_curves(&mut self, answer: &ReviewInput) -> io::Result<[SmallHeads; 4]> {
        let mut features = Vec::with_capacity(4 * CARD_FEATURES);
        let mut keys = Vec::with_capacity(4);
        for rating in 1..=4u8 {
            let mut answer = answer.clone();
            answer.is_query = false;
            answer.ease = Some(rating);
            features.extend(self.features.features_for(&answer));
            keys.push(stream_keys(&answer));
        }
        let heads = model::run(
            &self.model.net,
            &self.layouts,
            &mut self.stores,
            &Rows {
                features: &features,
                keys: &keys,
                commit: &[false; 4],
                heads: &[true; 4],
            },
            true,
            false,
        );
        Ok([heads[0], heads[1], heads[2], heads[3]])
    }

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

    /// `FRWKVSMALL1\0`, precision byte (0 / 8 / 4), weight fingerprint (u64),
    /// then per stream (card, deck, note, preset, user): slot length (u32),
    /// count (u32), states by ascending id (i64 id + slot bytes); then u32
    /// length + the `ARWKVPROCSTATE2` feature cache. Lossless.
    pub fn snapshot(&self) -> Vec<u8> {
        let state_bytes: usize = self.stores.iter().map(|s| s.len() * (8 + s.slot_len())).sum();
        let feature_len = b"ARWKVPROCSTATE2".len() + self.features.cache_state_len() + 4;
        let mut out = Vec::with_capacity(64 + state_bytes + feature_len);
        self.write_snapshot(&mut out).expect("writing to a Vec should not fail");
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
        let invalid = |message: &str| io::Error::new(io::ErrorKind::InvalidData, message.to_owned());
        let mut cursor = SnapshotReader::new(input, len);
        cursor.expect_magic(SNAPSHOT_MAGIC).map_err(|_| {
            invalid("not a small-model RWKV snapshot (a big-model snapshot or damaged bytes)")
        })?;
        if cursor.u8()? != super::precision_code(self.precision) {
            return Err(invalid("RWKV snapshot was taken with another state precision"));
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
