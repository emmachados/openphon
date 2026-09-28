//! Short-time power spectrogram.
//!
//! Windowing (Gaussian or Hann), optional pre-emphasis, FFT via rustfft,
//! power in dB re 2e-5 (samples treated as Pascals, Praat's convention).
//! The Gaussian window follows the published description in the Praat
//! manual: physical window twice the effective length, edge value
//! subtracted so it reaches zero.

use rustfft::FftPlanner;
use rustfft::num_complex::Complex;

pub const DB_FLOOR: f32 = -200.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowShape {
    Gaussian,
    Hann,
}

#[derive(Debug, Clone, Copy)]
pub struct SpectrogramParams {
    /// Effective analysis window length in seconds (Praat default 0.005).
    pub window_s: f64,
    /// Hop between frames in seconds (Praat default 0.002).
    pub time_step_s: f64,
    /// Highest frequency of interest; clamped to Nyquist.
    pub max_freq_hz: f64,
    /// 6 dB/oct high-pass pre-emphasis above this frequency; 0 disables.
    pub pre_emphasis_hz: f64,
    pub window: WindowShape,
}

impl Default for SpectrogramParams {
    fn default() -> Self {
        SpectrogramParams {
            window_s: 0.005,
            time_step_s: 0.002,
            max_freq_hz: 5000.0,
            pre_emphasis_hz: 0.0,
            window: WindowShape::Gaussian,
        }
    }
}

#[derive(Debug)]
pub struct Spectrogram {
    pub n_frames: usize,
    pub n_bins: usize,
    /// Time of the first frame centre, seconds.
    pub first_time_s: f64,
    pub time_step_s: f64,
    /// Frequency spacing between bins, Hz (bin i is at i * freq_step_hz).
    pub freq_step_hz: f64,
    /// Power in dB, frame-major: `values_db[frame * n_bins + bin]`.
    pub values_db: Vec<f32>,
}

fn window_weights(shape: WindowShape, n: usize) -> Vec<f64> {
    match shape {
        WindowShape::Hann => (0..n)
            .map(|i| {
                let x = i as f64 / (n - 1) as f64;
                0.5 - 0.5 * (2.0 * std::f64::consts::PI * x).cos()
            })
            .collect(),
        WindowShape::Gaussian => {
            // exp(-12 x^2) over x in [-1, 1], edge value subtracted.
            let edge = (-12.0f64).exp();
            (0..n)
                .map(|i| {
                    let x = 2.0 * i as f64 / (n - 1) as f64 - 1.0;
                    ((-12.0 * x * x).exp() - edge) / (1.0 - edge)
                })
                .collect()
        }
    }
}

pub fn pre_emphasize(samples: &mut [f64], sample_rate: f64, from_hz: f64) {
    if from_hz <= 0.0 {
        return;
    }
    let a = (-2.0 * std::f64::consts::PI * from_hz / sample_rate).exp();
    for i in (1..samples.len()).rev() {
        samples[i] -= a * samples[i - 1];
    }
}

pub fn compute(samples: &[f64], sample_rate: u32, params: &SpectrogramParams) -> Spectrogram {
    let sr = sample_rate as f64;
    // Gaussian uses a physical window twice the effective length.
    let physical_s = match params.window {
        WindowShape::Gaussian => 2.0 * params.window_s,
        WindowShape::Hann => params.window_s,
    };
    let win_n = ((physical_s * sr).round() as usize).max(2);
    let fft_n = win_n.next_power_of_two();
    let hop = ((params.time_step_s * sr).round() as usize).max(1);

    let mut source = samples.to_vec();
    pre_emphasize(&mut source, sr, params.pre_emphasis_hz);

    let freq_step = sr / fft_n as f64;
    let max_freq = params.max_freq_hz.min(sr / 2.0);
    let n_bins = ((max_freq / freq_step).floor() as usize + 1).min(fft_n / 2 + 1);

    // Frame centres step through the signal; frames needing samples beyond
    // either end are dropped (no zero-padding of the signal itself).
    let half = win_n / 2;
    let mut frame_starts = Vec::new();
    let mut start = 0usize;
    while start + win_n <= source.len() {
        frame_starts.push(start);
        start += hop;
    }
    let n_frames = frame_starts.len();
    let values_db = process_frames(&source, &frame_starts, win_n, fft_n, n_bins, params.window);

    Spectrogram {
        n_frames,
        n_bins,
        first_time_s: half as f64 / sr,
        time_step_s: hop as f64 / sr,
        freq_step_hz: freq_step,
        values_db,
    }
}

/// Spectrogram restricted to frames whose centres fall in [t0_s, t1_s].
/// Frames stay on the same global grid as [`compute`] (starts at multiples
/// of the hop), so the output equals the corresponding slice of the
/// whole-file spectrogram; `first_time_s` is absolute. Per-call cost
/// scales with the requested range, not the file length.
pub fn compute_range(
    samples: &[f64],
    sample_rate: u32,
    params: &SpectrogramParams,
    t0_s: f64,
    t1_s: f64,
) -> Spectrogram {
    let sr = sample_rate as f64;
    let physical_s = match params.window {
        WindowShape::Gaussian => 2.0 * params.window_s,
        WindowShape::Hann => params.window_s,
    };
    let win_n = ((physical_s * sr).round() as usize).max(2);
    let fft_n = win_n.next_power_of_two();
    let hop = ((params.time_step_s * sr).round() as usize).max(1);
    let half = win_n / 2;

    let freq_step = sr / fft_n as f64;
    let max_freq = params.max_freq_hz.min(sr / 2.0);
    let n_bins = ((max_freq / freq_step).floor() as usize + 1).min(fft_n / 2 + 1);
    let time_step_s = hop as f64 / sr;

    let empty = |first_time_s: f64| Spectrogram {
        n_frames: 0,
        n_bins,
        first_time_s,
        time_step_s,
        freq_step_hz: freq_step,
        values_db: Vec::new(),
    };
    if samples.len() < win_n || t1_s < t0_s {
        return empty(half as f64 / sr);
    }
    // Global frame indices k (start = k * hop) whose centres lie in range.
    let k_last_global = (samples.len() - win_n) / hop;
    let k0 = (((t0_s * sr - half as f64) / hop as f64).ceil().max(0.0)) as usize;
    let k1_f = ((t1_s * sr - half as f64) / hop as f64).floor();
    if k1_f < k0 as f64 || k0 > k_last_global {
        return empty((k0 * hop + half) as f64 / sr);
    }
    let k1 = (k1_f as usize).min(k_last_global);

    // Slice with one extra history sample so pre-emphasis (a first-difference
    // filter) matches the whole-file computation exactly.
    let s_begin = k0 * hop;
    let s_end = k1 * hop + win_n;
    let hist = if params.pre_emphasis_hz > 0.0 && s_begin > 0 {
        1
    } else {
        0
    };
    let mut source = samples[s_begin - hist..s_end].to_vec();
    pre_emphasize(&mut source, sr, params.pre_emphasis_hz);
    let source = &source[hist..];

    let frame_starts: Vec<usize> = (0..=(k1 - k0)).map(|k| k * hop).collect();
    let values_db = process_frames(source, &frame_starts, win_n, fft_n, n_bins, params.window);

    Spectrogram {
        n_frames: frame_starts.len(),
        n_bins,
        first_time_s: (k0 * hop + half) as f64 / sr,
        time_step_s,
        freq_step_hz: freq_step,
        values_db,
    }
}

/// Shared FFT loop: windowed frames -> one-sided power in dB re 2e-5 Pa.
fn process_frames(
    source: &[f64],
    frame_starts: &[usize],
    win_n: usize,
    fft_n: usize,
    n_bins: usize,
    window: WindowShape,
) -> Vec<f32> {
    let weights = window_weights(window, win_n);
    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(fft_n);

    let mut values_db = vec![DB_FLOOR; frame_starts.len() * n_bins];
    let mut buf = vec![Complex::new(0.0, 0.0); fft_n];
    // Praat convention: sample values are sound pressure in Pascals,
    // reference 2e-5 Pa. Window power is compensated so a full-scale sine
    // reads the same regardless of window shape.
    let win_power: f64 = weights.iter().map(|w| w * w).sum::<f64>() / win_n as f64;
    let p_ref_sq = 2e-5f64 * 2e-5;

    for (fi, &s0) in frame_starts.iter().enumerate() {
        for i in 0..fft_n {
            let v = if i < win_n {
                source[s0 + i] * weights[i]
            } else {
                0.0
            };
            buf[i] = Complex::new(v, 0.0);
        }
        fft.process(&mut buf);
        for bi in 0..n_bins {
            // One-sided power spectral estimate, window-power compensated.
            let mag_sq = buf[bi].norm_sqr();
            let scale = if bi == 0 || bi == fft_n / 2 { 1.0 } else { 2.0 };
            let power = scale * mag_sq / (fft_n as f64 * win_n as f64 * win_power);
            let db = if power > 0.0 {
                (10.0 * (power / p_ref_sq).log10()) as f32
            } else {
                DB_FLOOR
            };
            values_db[fi * n_bins + bi] = db.max(DB_FLOOR);
        }
    }
    values_db
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f64, amp: f64, sr: f64, dur_s: f64) -> Vec<f64> {
        (0..(sr * dur_s) as usize)
            .map(|i| amp * (2.0 * std::f64::consts::PI * freq * i as f64 / sr).sin())
            .collect()
    }

    #[test]
    fn peak_bin_matches_sine_frequency() {
        let sr = 44100u32;
        let s = sine(1000.0, 0.5, sr as f64, 0.5);
        let sg = compute(&s, sr, &SpectrogramParams::default());
        assert!(sg.n_frames > 100);
        let mid = sg.n_frames / 2;
        let row = &sg.values_db[mid * sg.n_bins..(mid + 1) * sg.n_bins];
        let peak = row
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        let peak_hz = peak as f64 * sg.freq_step_hz;
        assert!(
            (peak_hz - 1000.0).abs() <= sg.freq_step_hz,
            "peak at {peak_hz} Hz"
        );
    }

    #[test]
    fn sine_level_is_correct_for_both_windows() {
        // 0.5-amplitude sine: RMS = 0.3536 Pa -> 20 log10(rms/2e-5) = 84.95 dB.
        let sr = 44100u32;
        let s = sine(1000.0, 0.5, sr as f64, 0.5);
        for shape in [WindowShape::Gaussian, WindowShape::Hann] {
            let sg = compute(
                &s,
                sr,
                &SpectrogramParams {
                    window: shape,
                    ..Default::default()
                },
            );
            let mid = sg.n_frames / 2;
            let row = &sg.values_db[mid * sg.n_bins..(mid + 1) * sg.n_bins];
            // Total power = sum over bins (linear), should equal signal power.
            let total: f64 = row
                .iter()
                .map(|&db| 4e-10 * 10f64.powf(db as f64 / 10.0))
                .sum();
            let total_db = 10.0 * (total / 4e-10).log10();
            assert!(
                (total_db - 84.95).abs() < 1.0,
                "{shape:?}: total {total_db} dB"
            );
        }
    }

    #[test]
    fn silence_stays_at_floor() {
        let sg = compute(&vec![0.0; 44100], 44100, &SpectrogramParams::default());
        assert!(sg.values_db.iter().all(|&v| v == DB_FLOOR));
    }

    #[test]
    fn pre_emphasis_tilts_spectrum_up() {
        let sr = 44100u32;
        // Equal-amplitude components at 200 Hz and 4000 Hz.
        let s: Vec<f64> = sine(200.0, 0.3, sr as f64, 0.5)
            .iter()
            .zip(sine(4000.0, 0.3, sr as f64, 0.5))
            .map(|(a, b)| a + b)
            .collect();
        let flat = compute(&s, sr, &SpectrogramParams::default());
        let tilted = compute(
            &s,
            sr,
            &SpectrogramParams {
                pre_emphasis_hz: 50.0,
                ..Default::default()
            },
        );
        let bin = |sg: &Spectrogram, hz: f64| (hz / sg.freq_step_hz).round() as usize;
        let mid = flat.n_frames / 2;
        let level = |sg: &Spectrogram, hz: f64| sg.values_db[mid * sg.n_bins + bin(sg, hz)];
        let flat_diff = level(&flat, 4000.0) - level(&flat, 200.0);
        let tilted_diff = level(&tilted, 4000.0) - level(&tilted, 200.0);
        // 6 dB/oct over log2(4000/200) = 4.32 octaves ≈ 26 dB of relative boost.
        assert!(
            tilted_diff - flat_diff > 20.0,
            "flat {flat_diff} dB, tilted {tilted_diff} dB"
        );
    }

    #[test]
    fn range_equals_whole_file_slice() {
        let sr = 44100u32;
        let s: Vec<f64> = sine(300.0, 0.4, sr as f64, 1.0)
            .iter()
            .zip(sine(1700.0, 0.2, sr as f64, 1.0))
            .map(|(a, b)| a + b)
            .collect();
        for pre_emph in [0.0, 50.0] {
            let params = SpectrogramParams {
                pre_emphasis_hz: pre_emph,
                ..Default::default()
            };
            let whole = compute(&s, sr, &params);
            let part = compute_range(&s, sr, &params, 0.3, 0.6);
            assert!(part.n_frames > 100);
            // Locate the matching frame offset in the whole-file grid.
            let offset =
                ((part.first_time_s - whole.first_time_s) / whole.time_step_s).round() as usize;
            for fi in 0..part.n_frames {
                for bi in 0..part.n_bins {
                    let a = part.values_db[fi * part.n_bins + bi];
                    let b = whole.values_db[(offset + fi) * whole.n_bins + bi];
                    assert!(
                        (a - b).abs() < 1e-4,
                        "pre_emph {pre_emph}, frame {fi}, bin {bi}: {a} vs {b}"
                    );
                }
            }
            // Frame centres really are inside the requested range.
            assert!(part.first_time_s >= 0.3 - 1e-9);
            let last = part.first_time_s + (part.n_frames - 1) as f64 * part.time_step_s;
            assert!(last <= 0.6 + 1e-9);
        }
    }

    #[test]
    fn range_clamps_and_empties_gracefully() {
        let sr = 44100u32;
        let s = sine(500.0, 0.5, sr as f64, 0.5);
        let params = SpectrogramParams::default();
        // Range past the end: empty.
        let past = compute_range(&s, sr, &params, 2.0, 3.0);
        assert_eq!(past.n_frames, 0);
        assert!(past.values_db.is_empty());
        // Range wider than the file: same as whole computation.
        let wide = compute_range(&s, sr, &params, -1.0, 10.0);
        let whole = compute(&s, sr, &params);
        assert_eq!(wide.n_frames, whole.n_frames);
        assert!((wide.first_time_s - whole.first_time_s).abs() < 1e-12);
        // Inverted range: empty.
        assert_eq!(compute_range(&s, sr, &params, 0.4, 0.2).n_frames, 0);
    }

    #[test]
    fn geometry_is_consistent() {
        let sg = compute(&vec![0.1; 44100], 44100, &SpectrogramParams::default());
        assert_eq!(sg.values_db.len(), sg.n_frames * sg.n_bins);
        assert!((sg.time_step_s - 0.002).abs() < 1e-4);
        let top = (sg.n_bins - 1) as f64 * sg.freq_step_hz;
        assert!(top <= 5000.0 && top > 4900.0);
    }
}
