#[cfg(feature = "embedded")]
mod embedded;

#[cfg(feature = "embedded")]
pub use embedded::{fushi_aidoku_invoke, fushi_aidoku_string_free, invoke_json};
