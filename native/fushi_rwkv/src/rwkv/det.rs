// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
//! Fushi: the crate's floating-point contract. Every platform (x86_64 with or
//! without AVX2+FMA, aarch64 NEON, anything else) evaluates the network with
//! the same IEEE-754 operation sequence, so the same weights and the same
//! review history give bit-identical states and R everywhere (devices that
//! sync a collection must agree on which cards are due).
//!
//! - **Reductions** ([dot]): 32 striped lanes, lane `j % 32` accumulates
//!   element `j` with a fused multiply-add in ascending `j`; the lanes are then
//!   summed by one fixed tree ([reduce32]). AVX2 holds the lanes in four
//!   8-wide registers, NEON in eight 4-wide ones, the portable code in an
//!   array; none of them lets a compiler or a BLAS choose the order.
//! - **Multiply-adds** ([axpy], and every multiply-add of a vector kernel):
//!   always fused, tails included.
//!   x86_64 without the FMA extension and other architectures without a
//!   hardware FMA use [soft_fma] (exact, a few times slower).
//! - **Transcendentals** ([exp], [ln], [ln_1p], [tanh], [sin], [cos],
//!   [powf], [sigmoid]): never the platform libm (MSVC, glibc, bionic and
//!   Apple's libm differ in the last bit). Each is computed in f64 from basic
//!   operations only (polynomials, exact range reduction) and rounded to f32
//!   once; the f64 error is ~1e-15 relative, so the f32 result is the
//!   correctly rounded one except in rare near-halfway cases, and identical
//!   on every platform in all cases. `sqrt` and division are exact IEEE
//!   operations and are used directly.
//!
//! Rust itself never contracts `a * b + c` into an FMA nor reassociates, so
//! plain scalar arithmetic elsewhere in the crate is already deterministic;
//! only the code below has a choice to make. Assumed: the FPU runs with its
//! default IEEE environment (round to nearest, subnormals not flushed), which
//! is the default for threads on every supported OS.

// ---------------------------------------------------------------------------
// Fused multiply-add
// ---------------------------------------------------------------------------

/// `a * b + c` with one rounding, the hardware instruction where there is
/// one (the kernels below inline the same instruction; this scalar entry is
/// the yardstick the tests hold [soft_fma] against).
#[cfg(test)]
#[inline(always)]
pub(crate) fn fma(a: f32, b: f32, c: f32) -> f32 {
    #[cfg(target_arch = "aarch64")]
    {
        // aarch64 always has `fmadd`; `mul_add` lowers to it.
        a.mul_add(b, c)
    }
    #[cfg(target_arch = "x86_64")]
    {
        if x86_avx2_fma_available() {
            // SAFETY: the FMA extension was detected.
            unsafe { fma_x86(a, b, c) }
        } else {
            soft_fma(a, b, c)
        }
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    {
        soft_fma(a, b, c)
    }
}

#[cfg(all(test, target_arch = "x86_64"))]
#[target_feature(enable = "fma")]
#[inline]
unsafe fn fma_x86(a: f32, b: f32, c: f32) -> f32 {
    a.mul_add(b, c)
}

/// True when x86_64 has AVX2 and FMA (the vector kernels need both).
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub(crate) fn x86_avx2_fma_available() -> bool {
    use std::sync::atomic::{AtomicU8, Ordering};

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

/// Exactly rounded `a * b + c` from f64 arithmetic, for CPUs without an FMA
/// instruction (never the libm `fmaf`, whose quality varies by platform).
///
/// `a * b` is exact in f64 (48-bit product). `s = a * b + c` rounds once in
/// f64; TwoSum gives its exact error. Rounding `s` to f32 is then the correct
/// rounding of the exact value unless `s` sits exactly halfway between two
/// f32 values while the exact value does not, in which case `s` is moved one
/// f64 step toward the exact value first.
pub(crate) fn soft_fma(a: f32, b: f32, c: f32) -> f32 {
    let product = a as f64 * b as f64;
    let addend = c as f64;
    let sum = product + addend;
    if !sum.is_finite() {
        return sum as f32;
    }
    let virtual_addend = sum - product;
    let error = (product - (sum - virtual_addend)) + (addend - virtual_addend);
    if error == 0.0 || !is_f32_midpoint(sum) {
        return sum as f32;
    }
    let bits = sum.to_bits();
    let away_from_zero = (error > 0.0) == (sum > 0.0);
    f64::from_bits(if away_from_zero { bits + 1 } else { bits - 1 }) as f32
}

/// `value` (finite, nonzero) is exactly halfway between two neighbouring f32
/// values (or between `f32::MAX` and the overflow threshold).
fn is_f32_midpoint(value: f64) -> bool {
    const F32_MIN_NORMAL: f64 = 1.175_494_350_822_287_5e-38; // 2^-126
    if value.abs() >= F32_MIN_NORMAL {
        // 52 - 23 = 29 mantissa bits below f32 precision: exactly "1000…0".
        value.to_bits() & 0x1fff_ffff == 0x1000_0000
    } else {
        // Subnormal f32 grid: multiples of 2^-149; halfway points are odd
        // multiples of 2^-150. The scaling is exact.
        let scaled = value * f64::from_bits((1023u64 + 150) << 52);
        scaled == scaled.trunc() && (scaled as i64) % 2 != 0
    }
}

// ---------------------------------------------------------------------------
// Dot product and axpy
// ---------------------------------------------------------------------------

/// Lanes of the canonical dot product.
pub(crate) const DOT_LANES: usize = 32;

/// The fixed lane-reduction tree of [dot]:
/// `v[i] = (l[i] + l[8+i]) + (l[16+i] + l[24+i])`, `s[i] = v[i] + v[4+i]`,
/// result `(s[0] + s[2]) + (s[1] + s[3])`.
#[inline]
pub(crate) fn reduce32(lanes: &[f32; DOT_LANES]) -> f32 {
    let mut v = [0.0f32; 8];
    for (i, v) in v.iter_mut().enumerate() {
        *v = (lanes[i] + lanes[8 + i]) + (lanes[16 + i] + lanes[24 + i]);
    }
    let s = [v[0] + v[4], v[1] + v[5], v[2] + v[6], v[3] + v[7]];
    (s[0] + s[2]) + (s[1] + s[3])
}

/// The canonical dot product (see the module docs), evaluated with the given
/// scalar multiply-add. Reference for the vector kernels; also the kernel
/// itself where there are no vectors.
#[inline]
pub(crate) fn dot_reference(left: &[f32], right: &[f32], fma: impl Fn(f32, f32, f32) -> f32) -> f32 {
    debug_assert_eq!(left.len(), right.len());
    let mut lanes = [0.0f32; DOT_LANES];
    for (index, (l, r)) in left.iter().zip(right).enumerate() {
        let lane = &mut lanes[index % DOT_LANES];
        *lane = fma(*l, *r, *lane);
    }
    reduce32(&lanes)
}

/// `out[i] = fma(weights[i], scale, out[i])` with the given multiply-add.
#[inline]
pub(crate) fn axpy_reference(
    out: &mut [f32],
    weights: &[f32],
    scale: f32,
    fma: impl Fn(f32, f32, f32) -> f32,
) {
    debug_assert_eq!(out.len(), weights.len());
    for (out, weight) in out.iter_mut().zip(weights) {
        *out = fma(*weight, scale, *out);
    }
}

/// The canonical dot product of two equally long slices.
#[inline(always)]
pub(crate) fn dot(left: &[f32], right: &[f32]) -> f32 {
    assert_eq!(left.len(), right.len());
    #[cfg(target_arch = "aarch64")]
    {
        // SAFETY: aarch64 guarantees NEON; the lengths were checked above.
        unsafe { dot_neon(left, right) }
    }
    #[cfg(target_arch = "x86_64")]
    {
        if x86_avx2_fma_available() {
            // SAFETY: AVX2 and FMA were detected; the lengths were checked above.
            unsafe { dot_avx2_fma(left, right) }
        } else {
            dot_reference(left, right, soft_fma)
        }
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    {
        dot_reference(left, right, soft_fma)
    }
}

/// `out[i] = fma(weights[i], scale, out[i])` (every element fused).
#[inline(always)]
pub(crate) fn axpy(out: &mut [f32], weights: &[f32], scale: f32) {
    assert_eq!(out.len(), weights.len());
    #[cfg(target_arch = "aarch64")]
    {
        // SAFETY: aarch64 guarantees NEON; the lengths were checked above.
        unsafe { axpy_neon(out, weights, scale) }
    }
    #[cfg(target_arch = "x86_64")]
    {
        if x86_avx2_fma_available() {
            // SAFETY: AVX2 and FMA were detected; the lengths were checked above.
            unsafe { axpy_avx2_fma(out, weights, scale) }
        } else {
            axpy_reference(out, weights, scale, soft_fma)
        }
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    {
        axpy_reference(out, weights, scale, soft_fma)
    }
}

/// AVX2: lanes `8g..8g+8` live in `acc[g]`; element `j` of a full 8-block
/// `b = j / 8` goes to `acc[b % 4]`, the `len % 8` tail elements are
/// accumulated into the spilled lanes.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
pub(crate) unsafe fn dot_avx2_fma(left: &[f32], right: &[f32]) -> f32 {
    use std::arch::x86_64::*;

    let len = left.len();
    let l = left.as_ptr();
    let r = right.as_ptr();
    let mut acc0 = _mm256_setzero_ps();
    let mut acc1 = _mm256_setzero_ps();
    let mut acc2 = _mm256_setzero_ps();
    let mut acc3 = _mm256_setzero_ps();
    let mut j = 0;
    while j + 32 <= len {
        acc0 = _mm256_fmadd_ps(_mm256_loadu_ps(l.add(j)), _mm256_loadu_ps(r.add(j)), acc0);
        acc1 = _mm256_fmadd_ps(
            _mm256_loadu_ps(l.add(j + 8)),
            _mm256_loadu_ps(r.add(j + 8)),
            acc1,
        );
        acc2 = _mm256_fmadd_ps(
            _mm256_loadu_ps(l.add(j + 16)),
            _mm256_loadu_ps(r.add(j + 16)),
            acc2,
        );
        acc3 = _mm256_fmadd_ps(
            _mm256_loadu_ps(l.add(j + 24)),
            _mm256_loadu_ps(r.add(j + 24)),
            acc3,
        );
        j += 32;
    }
    // At most three more full blocks, into acc0, acc1, acc2 in that order.
    if j + 8 <= len {
        acc0 = _mm256_fmadd_ps(_mm256_loadu_ps(l.add(j)), _mm256_loadu_ps(r.add(j)), acc0);
        j += 8;
        if j + 8 <= len {
            acc1 = _mm256_fmadd_ps(_mm256_loadu_ps(l.add(j)), _mm256_loadu_ps(r.add(j)), acc1);
            j += 8;
            if j + 8 <= len {
                acc2 =
                    _mm256_fmadd_ps(_mm256_loadu_ps(l.add(j)), _mm256_loadu_ps(r.add(j)), acc2);
                j += 8;
            }
        }
    }
    if j == len {
        let v = _mm256_add_ps(_mm256_add_ps(acc0, acc1), _mm256_add_ps(acc2, acc3));
        let s = _mm_add_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps::<1>(v));
        let t = _mm_add_ps(s, _mm_movehl_ps(s, s));
        return _mm_cvtss_f32(_mm_add_ss(t, _mm_shuffle_ps::<0b01>(t, t)));
    }
    let mut lanes = [0.0f32; DOT_LANES];
    _mm256_storeu_ps(lanes.as_mut_ptr(), acc0);
    _mm256_storeu_ps(lanes.as_mut_ptr().add(8), acc1);
    _mm256_storeu_ps(lanes.as_mut_ptr().add(16), acc2);
    _mm256_storeu_ps(lanes.as_mut_ptr().add(24), acc3);
    while j < len {
        let lane = &mut lanes[j % DOT_LANES];
        *lane = (*l.add(j)).mul_add(*r.add(j), *lane);
        j += 1;
    }
    reduce32(&lanes)
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
pub(crate) unsafe fn axpy_avx2_fma(out: &mut [f32], weights: &[f32], scale: f32) {
    use std::arch::x86_64::*;

    let len = out.len();
    let o = out.as_mut_ptr();
    let w = weights.as_ptr();
    let s = _mm256_set1_ps(scale);
    let mut j = 0;
    while j + 32 <= len {
        _mm256_storeu_ps(o.add(j), _mm256_fmadd_ps(_mm256_loadu_ps(w.add(j)), s, _mm256_loadu_ps(o.add(j))));
        _mm256_storeu_ps(
            o.add(j + 8),
            _mm256_fmadd_ps(_mm256_loadu_ps(w.add(j + 8)), s, _mm256_loadu_ps(o.add(j + 8))),
        );
        _mm256_storeu_ps(
            o.add(j + 16),
            _mm256_fmadd_ps(_mm256_loadu_ps(w.add(j + 16)), s, _mm256_loadu_ps(o.add(j + 16))),
        );
        _mm256_storeu_ps(
            o.add(j + 24),
            _mm256_fmadd_ps(_mm256_loadu_ps(w.add(j + 24)), s, _mm256_loadu_ps(o.add(j + 24))),
        );
        j += 32;
    }
    while j + 8 <= len {
        _mm256_storeu_ps(o.add(j), _mm256_fmadd_ps(_mm256_loadu_ps(w.add(j)), s, _mm256_loadu_ps(o.add(j))));
        j += 8;
    }
    while j < len {
        *o.add(j) = (*w.add(j)).mul_add(scale, *o.add(j));
        j += 1;
    }
}

/// NEON: lanes `4q..4q+4` live in `acc[q]` (so the AVX2 register `g` is
/// `acc[2g]`, `acc[2g+1]`).
#[cfg(target_arch = "aarch64")]
pub(crate) unsafe fn dot_neon(left: &[f32], right: &[f32]) -> f32 {
    use std::arch::aarch64::*;

    let len = left.len();
    let l = left.as_ptr();
    let r = right.as_ptr();
    let mut acc = [vdupq_n_f32(0.0); 8];
    let mut j = 0;
    while j + 32 <= len {
        for (q, acc) in acc.iter_mut().enumerate() {
            *acc = vfmaq_f32(*acc, vld1q_f32(l.add(j + 4 * q)), vld1q_f32(r.add(j + 4 * q)));
        }
        j += 32;
    }
    let mut group = 0;
    while j + 8 <= len {
        acc[2 * group] = vfmaq_f32(acc[2 * group], vld1q_f32(l.add(j)), vld1q_f32(r.add(j)));
        acc[2 * group + 1] = vfmaq_f32(
            acc[2 * group + 1],
            vld1q_f32(l.add(j + 4)),
            vld1q_f32(r.add(j + 4)),
        );
        group += 1;
        j += 8;
    }
    if j == len {
        let low = vaddq_f32(vaddq_f32(acc[0], acc[2]), vaddq_f32(acc[4], acc[6]));
        let high = vaddq_f32(vaddq_f32(acc[1], acc[3]), vaddq_f32(acc[5], acc[7]));
        let s = vaddq_f32(low, high);
        let t = vadd_f32(vget_low_f32(s), vget_high_f32(s));
        return vget_lane_f32::<0>(t) + vget_lane_f32::<1>(t);
    }
    let mut lanes = [0.0f32; DOT_LANES];
    for (q, acc) in acc.iter().enumerate() {
        vst1q_f32(lanes.as_mut_ptr().add(4 * q), *acc);
    }
    while j < len {
        let lane = &mut lanes[j % DOT_LANES];
        *lane = (*l.add(j)).mul_add(*r.add(j), *lane);
        j += 1;
    }
    reduce32(&lanes)
}

#[cfg(target_arch = "aarch64")]
pub(crate) unsafe fn axpy_neon(out: &mut [f32], weights: &[f32], scale: f32) {
    use std::arch::aarch64::*;

    let len = out.len();
    let o = out.as_mut_ptr();
    let w = weights.as_ptr();
    let s = vdupq_n_f32(scale);
    let mut j = 0;
    while j + 16 <= len {
        vst1q_f32(o.add(j), vfmaq_f32(vld1q_f32(o.add(j)), vld1q_f32(w.add(j)), s));
        vst1q_f32(o.add(j + 4), vfmaq_f32(vld1q_f32(o.add(j + 4)), vld1q_f32(w.add(j + 4)), s));
        vst1q_f32(o.add(j + 8), vfmaq_f32(vld1q_f32(o.add(j + 8)), vld1q_f32(w.add(j + 8)), s));
        vst1q_f32(
            o.add(j + 12),
            vfmaq_f32(vld1q_f32(o.add(j + 12)), vld1q_f32(w.add(j + 12)), s),
        );
        j += 16;
    }
    while j + 4 <= len {
        vst1q_f32(o.add(j), vfmaq_f32(vld1q_f32(o.add(j)), vld1q_f32(w.add(j)), s));
        j += 4;
    }
    while j < len {
        *o.add(j) = (*w.add(j)).mul_add(scale, *o.add(j));
        j += 1;
    }
}

// ---------------------------------------------------------------------------
// Transcendental functions (f64 internally, one rounding to f32)
// ---------------------------------------------------------------------------

// fdlibm's split of ln 2: `LN2_HI` has 32 trailing zero bits, so `k * LN2_HI`
// is exact for |k| < 2^20.
const LN2_HI: f64 = 6.931_471_803_691_238_164_90e-1;
const LN2_LO: f64 = 1.908_214_929_270_587_700_02e-10;
const INV_LN2: f64 = 1.442_695_040_888_963_387_00;
const SQRT2: f64 = std::f64::consts::SQRT_2;

/// `e^r - 1` for `|r| <= 0.35`: `r * P(r)`, `P(r) = sum r^n / (n+1)!`
/// (Taylor to `r^12 / 13!`, truncation < 2e-17 relative).
#[inline]
fn expm1_reduced(r: f64) -> f64 {
    const C: [f64; 13] = [
        1.0,
        1.0 / 2.0,
        1.0 / 6.0,
        1.0 / 24.0,
        1.0 / 120.0,
        1.0 / 720.0,
        1.0 / 5040.0,
        1.0 / 40320.0,
        1.0 / 362880.0,
        1.0 / 3628800.0,
        1.0 / 39916800.0,
        1.0 / 479001600.0,
        1.0 / 6227020800.0,
    ];
    let mut p = C[12];
    for c in C[..12].iter().rev() {
        p = p * r + c;
    }
    r * p
}

/// `e^x`. Exact range reduction `x = k ln2 + r`, `|r| <= ln2 / 2`.
pub(crate) fn exp_f64(x: f64) -> f64 {
    if x.is_nan() {
        return x;
    }
    if x > 709.0 {
        return f64::INFINITY;
    }
    if x < -708.0 {
        // Far below the smallest f32 (2^-149); callers round to f32.
        return 0.0;
    }
    let k = (x * INV_LN2).round();
    let r = (x - k * LN2_HI) - k * LN2_LO;
    let scale = f64::from_bits(((k as i64 + 1023) as u64) << 52);
    (1.0 + expm1_reduced(r)) * scale
}

/// `e^x - 1`, accurate near 0.
pub(crate) fn expm1_f64(x: f64) -> f64 {
    if x.abs() <= 0.34 {
        expm1_reduced(x)
    } else {
        exp_f64(x) - 1.0
    }
}

/// Natural logarithm: `x = m 2^e`, `m` in `(sqrt(1/2), sqrt(2)]`,
/// `ln m = 2 atanh(s)`, `s = (m - 1) / (m + 1)`, `|s| <= 0.1716`
/// (series to `s^19 / 19`, truncation < 3e-17 relative).
pub(crate) fn ln_f64(x: f64) -> f64 {
    if x.is_nan() || x < 0.0 {
        return f64::NAN;
    }
    if x == 0.0 {
        return f64::NEG_INFINITY;
    }
    if x.is_infinite() {
        return x;
    }
    let mut bits = x.to_bits();
    let mut exponent: i64 = 0;
    if bits < 1u64 << 52 {
        // Subnormal: scale by 2^54 (exact).
        bits = (x * f64::from_bits((1023u64 + 54) << 52)).to_bits();
        exponent = -54;
    }
    exponent += (bits >> 52) as i64 - 1023;
    let mut m = f64::from_bits((bits & ((1u64 << 52) - 1)) | (1023u64 << 52));
    if m > SQRT2 {
        m *= 0.5;
        exponent += 1;
    }
    let f = m - 1.0;
    let s = f / (2.0 + f);
    let z = s * s;
    const C: [f64; 10] = [
        1.0,
        1.0 / 3.0,
        1.0 / 5.0,
        1.0 / 7.0,
        1.0 / 9.0,
        1.0 / 11.0,
        1.0 / 13.0,
        1.0 / 15.0,
        1.0 / 17.0,
        1.0 / 19.0,
    ];
    let mut p = C[9];
    for c in C[..9].iter().rev() {
        p = p * z + c;
    }
    let ln_m = 2.0 * s * p;
    let e = exponent as f64;
    e * LN2_HI + (e * LN2_LO + ln_m)
}

/// `ln(1 + y)`, accurate near 0 (Goldberg: `ln(u) * y / (u - 1)`, `u = 1 + y`).
pub(crate) fn ln_1p_f64(y: f64) -> f64 {
    if y.is_nan() || y < -1.0 {
        return f64::NAN;
    }
    let u = 1.0 + y;
    if u == 1.0 {
        return y;
    }
    if u.is_infinite() {
        return u;
    }
    ln_f64(u) * (y / (u - 1.0))
}

/// `e^x`.
#[inline]
pub(crate) fn exp(x: f32) -> f32 {
    exp_f64(x as f64) as f32
}

/// `ln x`.
#[inline]
pub(crate) fn ln(x: f32) -> f32 {
    ln_f64(x as f64) as f32
}

/// `ln(1 + x)`.
#[inline]
pub(crate) fn ln_1p(x: f32) -> f32 {
    ln_1p_f64(x as f64) as f32
}

/// `tanh x = t / (t + 2)`, `t = e^(2|x|) - 1`.
pub(crate) fn tanh(x: f32) -> f32 {
    let a = (x as f64).abs();
    if a.is_nan() {
        return x;
    }
    if a > 20.0 {
        return 1.0f32.copysign(x);
    }
    let t = expm1_f64(2.0 * a);
    ((t / (t + 2.0)) as f32).copysign(x)
}

/// The logistic function `1 / (1 + e^-x)`.
#[inline]
pub(crate) fn sigmoid(x: f32) -> f32 {
    let x = x as f64;
    if x.is_nan() {
        return x as f32;
    }
    if x >= 0.0 {
        (1.0 / (1.0 + exp_f64(-x))) as f32
    } else {
        let e = exp_f64(x);
        (e / (1.0 + e)) as f32
    }
}

/// `base^exponent` for `base > 0`, as `e^(exponent ln base)`.
pub(crate) fn powf(base: f32, exponent: f32) -> f32 {
    exp_f64(exponent as f64 * ln_f64(base as f64)) as f32
}

// fdlibm's three-part pi/2: `PIO2_1` has 33 significant bits, so `n * PIO2_1`
// is exact for |n| < 2^20.
const PIO2_1: f64 = 1.570_796_326_734_125_614_17;
const PIO2_1T: f64 = 6.077_100_506_506_192_249_32e-11;
const INV_PIO2: f64 = 6.366_197_723_675_813_824_33e-1;

/// `x = n pi/2 + r`, `|r| <= pi/4` (accurate for |x| < 2^19; inputs here are
/// phases below 2 pi).
#[inline]
fn reduce_pio2(x: f64) -> (i64, f64) {
    let n = (x * INV_PIO2).round();
    (n as i64, (x - n * PIO2_1) - n * PIO2_1T)
}

/// `sin r` for `|r| <= pi/4` (Taylor to `r^17 / 17!`).
fn sin_reduced(r: f64) -> f64 {
    const C: [f64; 9] = [
        1.0,
        -1.0 / 6.0,
        1.0 / 120.0,
        -1.0 / 5040.0,
        1.0 / 362880.0,
        -1.0 / 39916800.0,
        1.0 / 6227020800.0,
        -1.0 / 1307674368000.0,
        1.0 / 355687428096000.0,
    ];
    let z = r * r;
    let mut p = C[8];
    for c in C[..8].iter().rev() {
        p = p * z + c;
    }
    r * p
}

/// `cos r` for `|r| <= pi/4` (Taylor to `r^18 / 18!`).
fn cos_reduced(r: f64) -> f64 {
    const C: [f64; 10] = [
        1.0,
        -1.0 / 2.0,
        1.0 / 24.0,
        -1.0 / 720.0,
        1.0 / 40320.0,
        -1.0 / 3628800.0,
        1.0 / 479001600.0,
        -1.0 / 87178291200.0,
        1.0 / 20922789888000.0,
        -1.0 / 6402373705728000.0,
    ];
    let z = r * r;
    let mut p = C[9];
    for c in C[..9].iter().rev() {
        p = p * z + c;
    }
    p
}

/// `sin x`.
pub(crate) fn sin(x: f32) -> f32 {
    let x = x as f64;
    if !x.is_finite() {
        return f32::NAN;
    }
    let (n, r) = reduce_pio2(x);
    (match n.rem_euclid(4) {
        0 => sin_reduced(r),
        1 => cos_reduced(r),
        2 => -sin_reduced(r),
        _ => -cos_reduced(r),
    }) as f32
}

/// `cos x`.
pub(crate) fn cos(x: f32) -> f32 {
    let x = x as f64;
    if !x.is_finite() {
        return f32::NAN;
    }
    let (n, r) = reduce_pio2(x);
    (match n.rem_euclid(4) {
        0 => cos_reduced(r),
        1 => -sin_reduced(r),
        2 => -cos_reduced(r),
        _ => sin_reduced(r),
    }) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tiny xorshift for reproducible random inputs.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }

        /// Random f32 bit patterns over the whole range (finite only).
        fn any_f32(&mut self) -> f32 {
            loop {
                let value = f32::from_bits(self.next() as u32);
                if value.is_finite() {
                    return value;
                }
            }
        }

        /// Uniform-ish in [-scale, scale].
        fn uniform(&mut self, scale: f32) -> f32 {
            ((self.next() >> 40) as f32 / (1u64 << 24) as f32 * 2.0 - 1.0) * scale
        }
    }

    /// The software FMA equals the hardware one (x86 FMA / aarch64 fmadd) on
    /// random operands, near-cancellation, halfway and subnormal cases.
    #[test]
    fn soft_fma_matches_hardware() {
        #[cfg(target_arch = "x86_64")]
        if !x86_avx2_fma_available() {
            eprintln!("no FMA on this CPU; skipping the hardware comparison");
            return;
        }
        let hardware = |a: f32, b: f32, c: f32| fma(a, b, c);
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        let check = |a: f32, b: f32, c: f32| {
            let soft = soft_fma(a, b, c);
            let hard = hardware(a, b, c);
            assert!(
                soft.to_bits() == hard.to_bits() || (soft.is_nan() && hard.is_nan()),
                "fma({a:e}, {b:e}, {c:e}): soft {soft:e} vs hardware {hard:e}"
            );
        };
        for _ in 0..2_000_000 {
            let (a, b, c) = (rng.any_f32(), rng.any_f32(), rng.any_f32());
            check(a, b, c);
            // Near cancellation: c close to -a*b.
            let (a, b) = (rng.uniform(4.0), rng.uniform(4.0));
            let c = -(a * b) * (1.0 + rng.uniform(1e-6));
            check(a, b, c);
            // Mixed magnitudes (double-rounding territory).
            let c = rng.uniform(1.0) * f32::from_bits(((rng.next() % 60) as u32 + 100) << 23);
            check(a, b, c);
            // Subnormal results.
            let tiny = f32::from_bits((rng.next() as u32) & 0x00ff_ffff);
            check(tiny, rng.uniform(2.0), f32::from_bits((rng.next() as u32) & 0x807f_ffff));
            check(
                f32::from_bits(((rng.next() as u32) & 0x007f_ffff) | 0x0080_0000),
                f32::from_bits(((rng.next() as u32) & 0x007f_ffff) | 0x0080_0000) * 1e-30,
                rng.uniform(1e-38),
            );
        }
        // Halfway sums: 1 + 2^-24 (+/- a sliver).
        let half_ulp = f32::from_bits(0x3380_0000); // 2^-24
        for c in [half_ulp, -half_ulp, 3.0 * half_ulp] {
            for a in [1.0f32, 1.000_000_1, 0.999_999_94] {
                for b in [1.0f32, 1.0 + f32::EPSILON, 1.0 - f32::EPSILON / 2.0] {
                    check(a, b, c);
                    check(-a, b, -c);
                }
            }
        }
        check(f32::MAX, 1.0 + f32::EPSILON, 0.0);
        check(f32::MAX, 1.0, f32::MAX / 2f32.powi(24));
        check(0.0, -1.0, 0.0);
        check(-0.0, 1.0, -0.0);
        check(f32::INFINITY, 0.0, 1.0);
    }

    /// The vector dot product and axpy follow the canonical order bit for
    /// bit, for every length (all tail shapes) and random data.
    #[test]
    fn vector_kernels_match_the_reference_order() {
        let mut rng = Rng(0x1234_5678_9abc_def1);
        for len in 0..300 {
            for _ in 0..20 {
                let left: Vec<f32> = (0..len).map(|_| rng.uniform(3.0)).collect();
                let right: Vec<f32> = (0..len).map(|_| rng.uniform(3.0)).collect();
                let expected = dot_reference(&left, &right, soft_fma);
                let got = dot(&left, &right);
                assert_eq!(got.to_bits(), expected.to_bits(), "dot, len {len}");
                let scale = rng.uniform(2.0);
                let mut expected = right.clone();
                axpy_reference(&mut expected, &left, scale, soft_fma);
                let mut got = right.clone();
                axpy(&mut got, &left, scale);
                let same = got.iter().zip(&expected).all(|(a, b)| a.to_bits() == b.to_bits());
                assert!(same, "axpy, len {len}");
            }
        }
    }

    fn max_ulps(f: impl Fn(f32) -> f32, reference: impl Fn(f64) -> f64, inputs: &[f32]) -> u32 {
        inputs
            .iter()
            .map(|&x| {
                let got = f(x);
                let want = reference(x as f64) as f32;
                if got.to_bits() == want.to_bits() || (got.is_nan() && want.is_nan()) {
                    0
                } else {
                    assert!(got.is_finite() && want.is_finite(), "f({x:e}) = {got:e}, want {want:e}");
                    (got.to_bits() as i64 - want.to_bits() as i64).unsigned_abs() as u32
                }
            })
            .max()
            .unwrap_or(0)
    }

    /// Against the platform's f64 libm (only a yardstick, rounded to f32):
    /// at most 1 ulp anywhere, which is the inevitable near-halfway case.
    #[test]
    fn transcendentals_are_accurate() {
        let mut rng = Rng(42);
        let wide: Vec<f32> = (0..400_000).map(|_| rng.uniform(90.0)).collect();
        let small: Vec<f32> = (0..200_000).map(|_| rng.uniform(1e-3)).collect();
        let positive: Vec<f32> = (0..400_000)
            .map(|_| f32::from_bits((rng.next() as u32) & 0x7f7f_ffff))
            .filter(|v| *v > 0.0)
            .collect();
        let phases: Vec<f32> = (0..200_000).map(|_| rng.uniform(7.0)).collect();
        let near_one: Vec<f32> = (0..200_000).map(|_| 1.0 + rng.uniform(1e-3)).collect();
        for inputs in [&wide, &small] {
            assert!(max_ulps(exp, f64::exp, inputs) <= 1);
            assert!(max_ulps(tanh, f64::tanh, inputs) <= 1);
            assert!(max_ulps(sigmoid, |x| 1.0 / (1.0 + (-x).exp()), inputs) <= 1);
        }
        for inputs in [&positive, &near_one] {
            assert!(max_ulps(ln, f64::ln, inputs) <= 1);
            assert!(max_ulps(ln_1p, f64::ln_1p, inputs) <= 1);
        }
        assert!(max_ulps(ln_1p, f64::ln_1p, &small) <= 1);
        assert!(max_ulps(sin, f64::sin, &phases) <= 1);
        assert!(max_ulps(cos, f64::cos, &phases) <= 1);
        let exponents: Vec<f32> = (0..200_000).map(|_| rng.uniform(500.0)).collect();
        assert!(max_ulps(|e| powf(0.9, e), |e| (0.9f32 as f64).powf(e), &exponents) <= 1);
        // Special values.
        assert_eq!(exp(0.0), 1.0);
        assert_eq!(exp(-200.0), 0.0);
        assert_eq!(exp(100.0), f32::INFINITY);
        assert_eq!(ln(1.0), 0.0);
        assert_eq!(ln(0.0), f32::NEG_INFINITY);
        assert!(ln(-1.0).is_nan());
        assert_eq!(ln_1p(0.0), 0.0);
        assert_eq!(tanh(0.0), 0.0);
        assert_eq!(tanh(30.0), 1.0);
        assert_eq!(tanh(-30.0), -1.0);
        assert_eq!(sigmoid(0.0), 0.5);
        assert_eq!(sin(0.0), 0.0);
        assert_eq!(cos(0.0), 1.0);
    }
}
