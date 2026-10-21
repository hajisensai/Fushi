// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: fixed-size state slots (not upstream).
//!
//! Every card (or note) state of one stream has the same byte length, fixed
//! by the architecture and the state precision, so states live in slots
//! carved out of large blocks and are overwritten in place. Replay therefore
//! never frees and re-allocates long-lived per-card buffers. Upstream kept
//! each compact state in its own `Vec`; replay replaced them every chunk,
//! interleaved with that chunk's decoded f32 scratch, and the long-lived
//! buffers pinned the scratch's holes: measured 2026-10-20 on 14,715 cards
//! (big model, int8 state), 401 MB of live allocations held a 760 MB working
//! set, and `HeapCompact` could return none of it.

use std::collections::HashMap;

/// Bytes per block: large enough that the allocator maps each block straight
/// from the OS (and unmaps it when the store is dropped), so long-lived state
/// never shares heap pages with short-lived scratch.
const BLOCK_BYTES: usize = 1 << 20;

pub(super) struct SlotStore {
    slot_len: usize,
    slots_per_block: usize,
    blocks: Vec<Box<[u8]>>,
    /// Slot index by entity id.
    index: HashMap<i64, u32>,
    /// Slots given back by [Self::take], reused before new ones.
    free: Vec<u32>,
    /// Slots handed out so far (in use or free).
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
            free: Vec::new(),
            used: 0,
        }
    }

    pub fn slot_len(&self) -> usize {
        self.slot_len
    }

    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Bytes held by states (what a snapshot of these states stores).
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

    /// Removes the entity's state, returning a copy; its slot is reused by
    /// the next insertion.
    pub fn take(&mut self, id: i64) -> Option<Vec<u8>> {
        let slot = self.index.remove(&id)?;
        let bytes = self.slot(slot).to_vec();
        self.free.push(slot);
        Some(bytes)
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
        if let Some(slot) = self.free.pop() {
            self.slot_mut(slot).fill(0);
            return slot;
        }
        let slot = self.used;
        if slot as usize == self.blocks.len() * self.slots_per_block {
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

        let blocks = store.blocks.len();
        let taken = store.take(4).unwrap();
        assert!(taken.iter().all(|&b| b == 4));
        assert!(store.get(4).is_none());
        assert_eq!(store.len(), 9);
        // The freed slot is reused, zero-filled, without a new block.
        assert!(store.get_or_insert(42).iter().all(|&b| b == 0));
        assert_eq!(store.blocks.len(), blocks);
        assert_eq!(store.used, 10);
    }
}
