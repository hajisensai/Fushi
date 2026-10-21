// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: weight containers of the small model. `ARWKVWEIGHTS1` is the fork's
//! float32 container; `ARWKVWEIGHTS8PC1` stores 2-D `.weight` tensors as int8
//! codes with one float32 scale per row (INTEGRATION.md §4.2), dequantised
//! here at load (`code * scale`, bit-identical to the scorer's int8 weights).

use std::collections::HashMap;
use std::io;

use super::super::Cursor;

pub(super) const MAGIC_F32: &[u8] = b"ARWKVWEIGHTS1";
pub(super) const MAGIC_INT8: &[u8] = b"ARWKVWEIGHTS8PC1";

pub(super) struct Tensor {
    pub shape: Vec<usize>,
    pub values: Vec<f32>,
}

pub(super) struct Weights {
    tensors: HashMap<String, Tensor>,
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

impl Weights {
    pub fn parse(data: &[u8]) -> io::Result<Self> {
        if data.starts_with(MAGIC_INT8) {
            Self::parse_with(data, MAGIC_INT8, true)
        } else {
            Self::parse_with(data, MAGIC_F32, false)
        }
    }

    fn parse_with(data: &[u8], magic: &[u8], int8: bool) -> io::Result<Self> {
        let mut cursor = Cursor::new(data);
        cursor.expect_magic(magic)?;
        let count = cursor.count(4)?;
        let mut tensors = HashMap::with_capacity(count);
        for _ in 0..count {
            let name_len = cursor.u16()? as usize;
            let name = cursor.string(name_len)?;
            let kind = if int8 { cursor.u8()? } else { 0 };
            let rank = cursor.u8()? as usize;
            let mut shape = Vec::with_capacity(rank);
            let mut len = 1_usize;
            for _ in 0..rank {
                let dim = cursor.u32()? as usize;
                len = len
                    .checked_mul(dim)
                    .ok_or_else(|| invalid("tensor is too large"))?;
                shape.push(dim);
            }
            let values = match kind {
                0 => f32s(cursor.bytes(len.checked_mul(4).ok_or_else(|| invalid("tensor is too large"))?)?),
                1 => {
                    if rank != 2 {
                        return Err(invalid(format!("int8 tensor {name} is not 2-D")));
                    }
                    let (rows, columns) = (shape[0], shape[1]);
                    let scales = f32s(cursor.bytes(rows * 4)?);
                    let codes = cursor.bytes(len)?;
                    let mut values = Vec::with_capacity(len);
                    for (row, scale) in scales.iter().enumerate() {
                        for &code in &codes[row * columns..(row + 1) * columns] {
                            values.push(code as i8 as f32 * scale);
                        }
                    }
                    values
                }
                other => return Err(invalid(format!("unknown tensor kind {other} for {name}"))),
            };
            if values.iter().any(|value| !value.is_finite()) {
                return Err(invalid(format!("tensor {name} has non-finite values")));
            }
            if tensors.insert(name.clone(), Tensor { shape, values }).is_some() {
                return Err(invalid(format!("duplicate tensor {name}")));
            }
        }
        cursor.expect_end()?;
        Ok(Self { tensors })
    }

    /// Whether `data` is a weight file of the small model, from the tensor
    /// directory alone (values are skipped, not parsed): the big model's file
    /// has no power-curve head (`gru_w_weight`).
    pub fn is_small_model_file(data: &[u8]) -> io::Result<bool> {
        let int8 = data.starts_with(MAGIC_INT8);
        let mut cursor = Cursor::new(data);
        cursor.expect_magic(if int8 { MAGIC_INT8 } else { MAGIC_F32 })?;
        let count = cursor.count(4)?;
        for _ in 0..count {
            let name_len = cursor.u16()? as usize;
            let name = cursor.bytes(name_len)?;
            if name == b"gru_w_weight" {
                return Ok(true);
            }
            let kind = if int8 { cursor.u8()? } else { 0 };
            let rank = cursor.u8()? as usize;
            let mut shape = Vec::with_capacity(rank);
            for _ in 0..rank {
                shape.push(cursor.u32()? as usize);
            }
            let len = shape
                .iter()
                .try_fold(1_usize, |len, &dim| len.checked_mul(dim))
                .ok_or_else(|| invalid("tensor is too large"))?;
            let skip = match kind {
                0 => len.checked_mul(4),
                _ => shape.first().and_then(|rows| (rows * 4).checked_add(len)),
            }
            .ok_or_else(|| invalid("tensor is too large"))?;
            cursor.bytes(skip)?;
        }
        Ok(false)
    }

    pub fn contains(&self, name: &str) -> bool {
        self.tensors.contains_key(name)
    }

    pub fn shape(&self, name: &str) -> Option<&[usize]> {
        self.tensors.get(name).map(|tensor| tensor.shape.as_slice())
    }

    /// The tensor's values, checked to have `len` elements in total (the
    /// containers store some vectors as `[1, 1, n]` and the like).
    pub fn take(&mut self, name: &str, len: usize) -> io::Result<Vec<f32>> {
        let tensor = self
            .tensors
            .remove(name)
            .ok_or_else(|| invalid(format!("missing weight: {name}")))?;
        if tensor.values.len() != len {
            return Err(invalid(format!(
                "weight {name} has shape {:?}, expected {len} values",
                tensor.shape
            )));
        }
        Ok(tensor.values)
    }

    /// A `[rows, columns]` matrix.
    pub fn matrix(&mut self, name: &str, rows: usize, columns: usize) -> io::Result<Vec<f32>> {
        match self.shape(name) {
            Some(shape) if shape == [rows, columns] => self.take(name, rows * columns),
            Some(shape) => Err(invalid(format!(
                "weight {name} has shape {shape:?}, expected [{rows}, {columns}]"
            ))),
            None => Err(invalid(format!("missing weight: {name}"))),
        }
    }
}

fn f32s(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect()
}
