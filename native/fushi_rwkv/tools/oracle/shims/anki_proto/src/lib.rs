//! Oracle-only shim of the one proto enum the upstream rwkv module names
//! (workload simulation only; never exercised by the oracle).
pub mod deck_config {
    pub mod deck_config {
        pub mod config {
            #[derive(Clone, Copy, Debug, PartialEq, Eq)]
            pub enum ReviewCardOrder {
                Day,
                DayThenDeck,
                DeckThenDay,
                IntervalsAscending,
                IntervalsDescending,
                EaseAscending,
                EaseDescending,
                RetrievabilityAscending,
                RetrievabilityDescending,
                RelativeOverdueness,
                Random,
                Added,
                ReverseAdded,
            }
        }
    }
}
