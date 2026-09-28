//! Spectral moments of a stretch of samples: centre of gravity, standard
//! deviation, skewness, and kurtosis of the power spectrum. The staple
//! measures of fricative/sibilant acoustics.
//!
//! Definitions (standard, matching Praat's Spectrum queries at their
//! default power weighting p = 2): with `w_k = |X_k|^2` over the
//! positive-frequency bins at `f_k`,
//!
//!   cog  = Σ w f / Σ w
//!   m_i  = Σ w (f - cog)^i / Σ w
//!   sd   = sqrt(m_2)
//!   skew = m_3 / m_2^(3/2)
//!   kurt = m_4 / m_2^2 - 3        (excess kurtosis)
//!
//! The FFT length is the next power of two (zero-padded); the bin width
//! cancels out of every normalized moment, so the padding scheme does
//! not need to mirror any other tool's. No window, no pre-emphasis: the
//! recipe measures the slice it is given (callers pick the slice, e.g.
//! the middle 50% of a labeled interval).

use rustfft::num_complex::Complex;
use rustfft::FftPlanner;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpectralMoments {
    pub cog_hz: f64,
    pub sd_hz: f64,
    pub skewness: f64,
    /// Excess kurtosis (0 for a Gaussian-shaped spectrum).
    pub kurtosis: f64,
}

/// Moments of the power spectrum of `samples`. `None` for slices too
/// short to carry a spectrum (< 8 samples) or with (near-)zero energy.
pub fn moments(samples: &[f64], sample_rate: u32) -> Option<SpectralMoments> {
    if samples.len() < 8 {
        return None;
    }
    let fft_n = samples.len().next_power_of_two();
    let mut buf: Vec<Complex<f64>> = samples
        .iter()
        .map(|&s| Complex::new(s, 0.0))
        .chain(std::iter::repeat(Complex::new(0.0, 0.0)))
        .take(fft_n)
        .collect();
    FftPlanner::new().plan_fft_forward(fft_n).process(&mut buf);

    let df = sample_rate as f64 / fft_n as f64;
    // Positive-frequency half; DC and Nyquist carry no direction and are
    // included with their natural (single) weight.
    let n_bins = fft_n / 2 + 1;
    let mut total = 0.0;
    let mut sum_f = 0.0;
    for (k, v) in buf.iter().take(n_bins).enumerate() {
        let w = v.norm_sqr();
        total += w;
        sum_f += w * k as f64 * df;
    }
    if total <= 0.0 || !total.is_finite() {
        return None;
    }
    let cog = sum_f / total;
    let (mut m2, mut m3, mut m4) = (0.0, 0.0, 0.0);
    for (k, v) in buf.iter().take(n_bins).enumerate() {
        let w = v.norm_sqr() / total;
        let d = k as f64 * df - cog;
        m2 += w * d * d;
        m3 += w * d * d * d;
        m4 += w * d * d * d * d;
    }
    if m2 <= 0.0 {
        return None;
    }
    Some(SpectralMoments {
        cog_hz: cog,
        sd_hz: m2.sqrt(),
        skewness: m3 / m2.powf(1.5),
        kurtosis: m4 / (m2 * m2) - 3.0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: u32 = 44100;

    fn sine(freq: f64, n: usize) -> Vec<f64> {
        (0..n)
            .map(|i| (2.0 * std::f64::consts::PI * freq * i as f64 / SR as f64).sin())
            .collect()
    }

    #[test]
    fn single_tone_centers_on_its_frequency() {
        let m = moments(&sine(3000.0, 8192), SR).unwrap();
        assert!((m.cog_hz - 3000.0).abs() < 15.0, "cog {}", m.cog_hz);
        // An off-bin tone leaks (no window by design), but the SD stays
        // small relative to the band.
        assert!(m.sd_hz < 200.0, "sd {}", m.sd_hz);
    }

    #[test]
    fn two_equal_tones_give_analytic_moments() {
        // Frequencies on exact FFT bins (8192 @ 44100: df ≈ 5.383 Hz) so
        // leakage is negligible: bins 372 and 744.
        let n = 8192;
        let df = SR as f64 / n as f64;
        let (f1, f2) = (372.0 * df, 744.0 * df);
        let s: Vec<f64> = (0..n)
            .map(|i| {
                let t = i as f64 / SR as f64;
                (2.0 * std::f64::consts::PI * f1 * t).sin()
                    + (2.0 * std::f64::consts::PI * f2 * t).sin()
            })
            .collect();
        let m = moments(&s, SR).unwrap();
        // Two equal point masses at f1, f2: cog is the midpoint, sd is
        // half the gap, skewness 0, excess kurtosis −2.
        assert!((m.cog_hz - (f1 + f2) / 2.0).abs() < 2.0, "cog {}", m.cog_hz);
        assert!((m.sd_hz - (f2 - f1) / 2.0).abs() < 5.0, "sd {}", m.sd_hz);
        assert!(m.skewness.abs() < 0.05, "skew {}", m.skewness);
        assert!((m.kurtosis + 2.0).abs() < 0.1, "kurt {}", m.kurtosis);
    }

    #[test]
    fn degenerate_input_is_none() {
        assert_eq!(moments(&[0.0; 4], SR), None); // too short
        assert_eq!(moments(&[0.0; 100], SR), None); // zero energy
    }
}
