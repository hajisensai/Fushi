//! 定长实信号 FFT（radix-2，迭代版）：只给本模块的 STFT 用，长度固定（1024 / 2048），
//! 预先算好位反转表与旋转因子，逐帧复用。不引 rustfft：本 crate 的依赖许可登记与 iOS 伞形库
//! lockfile 都不必动，而这里的长度与吞吐（整首几万帧）用不着通用实现。

use std::f64::consts::PI;

/// 一个长度的 FFT 计划。
pub(crate) struct Fft {
    n: usize,
    rev: Vec<u32>,
    cos: Vec<f64>,
    sin: Vec<f64>,
    re: Vec<f64>,
    im: Vec<f64>,
}

impl Fft {
    /// `n` 必须是 2 的幂且 ≥ 2。
    pub(crate) fn new(n: usize) -> Self {
        assert!(n >= 2 && n.is_power_of_two(), "fft size {n}");
        let bits = n.trailing_zeros();
        let rev = (0..n as u32)
            .map(|i| i.reverse_bits() >> (32 - bits))
            .collect();
        let half = n / 2;
        let cos = (0..half)
            .map(|k| (2.0 * PI * k as f64 / n as f64).cos())
            .collect();
        let sin = (0..half)
            .map(|k| -(2.0 * PI * k as f64 / n as f64).sin())
            .collect();
        Self {
            n,
            rev,
            cos,
            sin,
            re: vec![0.0; n],
            im: vec![0.0; n],
        }
    }

    /// 实输入 `input`（长度 = n）→ 幅度谱的平方 `out[0..=n/2]`（|X_k|²，未归一）。
    pub(crate) fn power(&mut self, input: &[f64], out: &mut [f64]) {
        self.transform(input);
        for (k, slot) in out.iter_mut().enumerate().take(self.n / 2 + 1) {
            *slot = self.re[k] * self.re[k] + self.im[k] * self.im[k];
        }
    }

    fn transform(&mut self, input: &[f64]) {
        let n = self.n;
        debug_assert_eq!(input.len(), n);
        for i in 0..n {
            let j = self.rev[i] as usize;
            self.re[j] = input[i];
            self.im[j] = 0.0;
        }
        let mut size = 2;
        while size <= n {
            let half = size / 2;
            let step = n / size;
            let mut start = 0;
            while start < n {
                for k in 0..half {
                    let (wr, wi) = (self.cos[k * step], self.sin[k * step]);
                    let a = start + k;
                    let b = a + half;
                    let tr = self.re[b] * wr - self.im[b] * wi;
                    let ti = self.re[b] * wi + self.im[b] * wr;
                    self.re[b] = self.re[a] - tr;
                    self.im[b] = self.im[a] - ti;
                    self.re[a] += tr;
                    self.im[a] += ti;
                }
                start += size;
            }
            size *= 2;
        }
    }
}

/// 周期 Hann 窗（STFT 惯例：分母是 `n` 而不是 `n - 1`）。
pub(crate) fn hann(n: usize) -> Vec<f64> {
    (0..n)
        .map(|i| 0.5 * (1.0 - (2.0 * PI * i as f64 / n as f64).cos()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dft_power(x: &[f64]) -> Vec<f64> {
        let n = x.len();
        (0..=n / 2)
            .map(|k| {
                let (mut re, mut im) = (0.0, 0.0);
                for (t, v) in x.iter().enumerate() {
                    let a = -2.0 * PI * (k * t) as f64 / n as f64;
                    re += v * a.cos();
                    im += v * a.sin();
                }
                re * re + im * im
            })
            .collect()
    }

    #[test]
    fn matches_naive_dft() {
        let n = 64;
        let x: Vec<f64> = (0..n)
            .map(|i| ((i * 7919) % 97) as f64 / 97.0 - 0.5)
            .collect();
        let mut fft = Fft::new(n);
        let mut out = vec![0.0; n / 2 + 1];
        fft.power(&x, &mut out);
        for (a, b) in out.iter().zip(dft_power(&x)) {
            assert!((a - b).abs() < 1e-9 * (1.0 + b), "{a} vs {b}");
        }
    }

    #[test]
    fn pure_tone_lands_in_its_bin() {
        let n = 1024;
        let x: Vec<f64> = (0..n)
            .map(|i| (2.0 * PI * 37.0 * i as f64 / n as f64).sin())
            .collect();
        let mut fft = Fft::new(n);
        let mut out = vec![0.0; n / 2 + 1];
        fft.power(&x, &mut out);
        let peak = out
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .unwrap()
            .0;
        assert_eq!(peak, 37);
    }
}
