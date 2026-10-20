// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: per-stream state storage of the small model.
//!
//! Every entity of a stream has a state of the same byte length (fixed by the
//! architecture and the stream's precision), so states live in fixed-size
//! slots carved out of large blocks and are overwritten in place. Replay
//! therefore never frees and re-allocates per-card buffers: the big model's
//! per-state `Vec`s, interleaved with the decoded f32 scratch of every replay
//! chunk, left the process heap at about twice the live state (measured
//! 2026-10-20: 14,715 cards, 401 MB live, 760 MB working set), and the holes
//! could neither be reused nor returned to the OS.

use std::collections::HashMap;

/// Bytes per block: big enough that blocks come straight from the OS (and go
/// back to it when the store is dropped), small enough not to overshoot.
const BLOCK_BYTES: usize = 1 << 20;

pub(super) struct SlotStore {
    slot_len: usize,
    slots_per_block: usize,
    blocks: Vec<Box<[u8]>>,
    /// Slot index by entity id.
    index: HashMap<i64, u32>,
    /// Slots handed out so far.
    used: u32,
}

impl SlotStore {
    pub fn new(slot_len: usize) -> Self {
        assert!(slot_len > 0);
        Self {
            slot_len,
            slots_per_block: (BLOCK_BYTES / slot_len).max(1),
            blocks: Vec::new(),
            index: HashMap::new(),
            used: 0,
        }
    }

    pub fn slot_len(&self) -> usize {
        self.slot_len
    }

    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Bytes held by states (what a snapshot of this stream stores).
    pub fn state_bytes(&self) -> usize {
        self.index.len() * self.slot_len
    }

    pub fn get(&self, id: i64) -> Option<&[u8]> {
        self.index.get(&id).map(|&slot| self.slot(slot))
    }

    /// The entity's slot, allocated (zero-filled) when it has none yet.
    pub fn get_or_insert(&mut self, id: i64) -> &mut [u8] {
        let slot = match self.index.get(&id) {
            Some(&slot) => slot,
            None => {
                let slot = self.allocate();
                self.index.insert(id, slot);
                slot
            }
        };
        self.slot_mut(slot)
    }

    pub fn ids(&self) -> Vec<i64> {
        let mut ids: Vec<i64> = self.index.keys().copied().collect();
        ids.sort_unstable();
        ids
    }

    pub fn clear(&mut self) {
        *self = Self::new(self.slot_len);
    }

    fn allocate(&mut self) -> u32 {
        let slot = self.used;
        if slot as usize == self.blocks.len() * self.slots_per_block {
            // A whole block at once: one allocation per ~1 MB of states.
            self.blocks
                .push(vec![0u8; self.slots_per_block * self.slot_len].into_boxed_slice());
        }
        self.used += 1;
        slot
    }

    fn slot(&self, slot: u32) -> &[u8] {
        let slot = slot as usize;
        let block = &self.blocks[slot / self.slots_per_block];
        let start = (slot % self.slots_per_block) * self.slot_len;
        &block[start..start + self.slot_len]
    }

    fn slot_mut(&mut self, slot: u32) -> &mut [u8] {
        let slot = slot as usize;
        let block = &mut self.blocks[slot / self.slots_per_block];
        let start = (slot % self.slots_per_block) * self.slot_len;
        &mut block[start..start + self.slot_len]
    }
}

#[cfg(test)]
mod tests {
    use super::SlotStore;

    #[test]
    fn slots_are_stable_and_reused() {
        let mut store = SlotStore::new(300_000);
        for id in 0..10 {
            store.get_or_insert(id).fill(id as u8);
        }
        assert_eq!(store.len(), 10);
        assert!(store.blocks.len() >= 3);
        for id in 0..10 {
            assert!(store.get(id).unwrap().iter().all(|&b| b == id as u8));
        }
        store.get_or_insert(3).fill(77);
        assert!(store.get(3).unwrap().iter().all(|&b| b == 77));
        assert_eq!(store.ids(), (0..10).collect::<Vec<_>>());
        assert!(store.get(11).is_none());
    }
}
