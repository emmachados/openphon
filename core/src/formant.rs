//! Formant tracking: Burg LPC + polynomial roots, after Praat's published
//! algorithm description (To Formant (burg)): resample to twice the formant
//! ceiling, pre-emphasize above 50 Hz, Gaussian window, Burg's method,
//! roots of the prediction polynomial, keep poles inside the frequency
//! band. Clean-room: implemented from the manual and standard DSP texts,
//! no Praat source consulted.

use rustfft::num_complex::Complex64;

#[derive(Debug, Clone, Copy)]
pub struct FormantParams {
    /// Hop between frames in seconds.
    pub time_step_s: f64,
    /// Maximum number of formants returned per frame (LPC order is twice this).
    pub max_formants: usize,
    /// Formant ceiling: analysis band is [50, ceiling] Hz. Praat defaults:
    /// 5500 for female voices, 5000 for male.
    pub ceiling_hz: f64,
    /// Effective analysis window length in seconds.
    pub window_s: f64,
    /// 6 dB/oct pre-emphasis above this frequency.
    pub pre_emphasis_hz: f64,
    /// Candidates broader than this are discarded as spurious poles
    /// (spectral-tilt and filler poles typically have bandwidths of
    /// several hundred Hz; real formants rarely exceed ~300 Hz).
    pub max_bandwidth_hz: f64,
}

impl Default for FormantParams {
    fn default() -> Self {
        FormantParams {
            time_step_s: 0.01,
            max_formants: 5,
            ceiling_hz: 5500.0,
            window_s: 0.025,
            pre_emphasis_hz: 50.0,
            max_bandwidth_hz: 400.0,
        }
    }
}

#[derive(Debug)]
pub struct FormantFrame {
    pub time_s: f64,
    /// Ascending formant frequencies, at most `max_formants` of them.
    pub formants_hz: Vec<f64>,
    /// Bandwidths matching `formants_hz` one-to-one.
    pub bandwidths_hz: Vec<f64>,
}

#[derive(Debug)]
pub struct FormantTrack {
    pub frames: Vec<FormantFrame>,
}

const HALF_TAPS: i64 = 32;
const TAPS: usize = 2 * HALF_TAPS as usize;

/// Windowed-sinc kernel coefficient at offset `x` (input samples).
fn resample_kernel(x: f64, cutoff: f64) -> f64 {
    let sinc = if x.abs() < 1e-12 {
        cutoff
    } else {
        (std::f64::consts::PI * cutoff * x).sin() / (std::f64::consts::PI * x)
    };
    // Hann taper over the tap span.
    let w = 0.5 + 0.5 * (std::f64::consts::PI * x / HALF_TAPS as f64).cos();
    sinc * w
}

/// Windowed-sinc resampling (anti-aliased for downsampling).
///
/// Integer sample rates take a polyphase fast path: the fractional output
/// positions repeat with period `sr_out / gcd`, so each phase's 64 kernel
/// coefficients are computed once instead of two transcendentals per tap
/// per output sample (the naive form dominated formant tracking).
pub fn resample(samples: &[f64], sr_in: f64, sr_out: f64) -> Vec<f64> {
    if (sr_in - sr_out).abs() < 1e-9 {
        return samples.to_vec();
    }
    // Cutoff relative to the input rate, leaving a little transition band.
    let cutoff = (sr_out / sr_in).min(1.0) * 0.95;
    let n_out = ((samples.len() as f64) * sr_out / sr_in).floor() as usize;
    let (si, so) = (sr_in.round(), sr_out.round());
    if (sr_in - si).abs() < 1e-9 && (sr_out - so).abs() < 1e-9 && si >= 1.0 && so >= 1.0 {
        let g = gcd(si as u64, so as u64);
        let p = (so as u64 / g) as usize;
        let q = (si as u64 / g) as usize;
        // Degenerate ratios would need an enormous coefficient table; the
        // generic path handles them (never hit by real sample rates).
        if p <= 65536 {
            return resample_polyphase(samples, p, q, cutoff, n_out);
        }
    }
    resample_generic(samples, sr_in, sr_out, cutoff, n_out)
}

fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

fn resample_polyphase(samples: &[f64], p: usize, q: usize, cutoff: f64, n_out: usize) -> Vec<f64> {
    // Output index k sits at input position t = k*q/p = a*q + b*q/p with
    // a = k/p, b = k%p: the fractional part depends only on the phase b.
    let mut taps = vec![0.0f64; p * TAPS];
    let mut base = vec![0i64; p];
    for b in 0..p {
        let t = (b * q) as f64 / p as f64;
        let j0 = t.floor();
        base[b] = j0 as i64;
        for i in 0..TAPS {
            let m = i as i64 - HALF_TAPS + 1; // j = j0 + m
            taps[b * TAPS + i] = resample_kernel(t - (j0 + m as f64), cutoff);
        }
    }
    let n = samples.len() as i64;
    let mut out = Vec::with_capacity(n_out);
    for k in 0..n_out {
        let (a, b) = (k / p, k % p);
        let start = (a * q) as i64 + base[b] - HALF_TAPS + 1;
        let row = &taps[b * TAPS..(b + 1) * TAPS];
        let mut acc = 0.0;
        if start >= 0 && start + TAPS as i64 <= n {
            let seg = &samples[start as usize..start as usize + TAPS];
            for i in 0..TAPS {
                acc += seg[i] * row[i];
            }
        } else {
            // Frame straddles the signal edge: skip out-of-range taps,
            // matching the generic path.
            for (i, c) in row.iter().enumerate() {
                let j = start + i as i64;
                if j >= 0 && j < n {
                    acc += samples[j as usize] * c;
                }
            }
        }
        out.push(acc);
    }
    out
}

fn resample_generic(
    samples: &[f64],
    sr_in: f64,
    sr_out: f64,
    cutoff: f64,
    n_out: usize,
) -> Vec<f64> {
    let mut out = Vec::with_capacity(n_out);
    for k in 0..n_out {
        let t = k as f64 * sr_in / sr_out; // position in input samples
        let j0 = t.floor() as i64;
        let mut acc = 0.0;
        for j in (j0 - HALF_TAPS + 1)..=(j0 + HALF_TAPS) {
            if j < 0 || j >= samples.len() as i64 {
                continue;
            }
            acc += samples[j as usize] * resample_kernel(t - j as f64, cutoff);
        }
        out.push(acc);
    }
    out
}

/// Burg's method. Returns prediction coefficients a[1..=order] of
/// A(z) = 1 + a1 z^-1 + ... + a_p z^-p (error-minimizing sign convention).
pub fn burg(x: &[f64], order: usize) -> Vec<f64> {
    let n = x.len();
    assert!(order < n, "Burg order must be below the frame length");
    let mut a = vec![0.0f64; order + 1];
    a[0] = 1.0;
    let mut f = x.to_vec(); // forward errors
    let mut b = x.to_vec(); // backward errors
    for m in 0..order {
        let mut num = 0.0;
        let mut den = 0.0;
        for i in (m + 1)..n {
            num += f[i] * b[i - 1];
            den += f[i] * f[i] + b[i - 1] * b[i - 1];
        }
        let k = if den > 0.0 { -2.0 * num / den } else { 0.0 };
        // Levinson update of the coefficients.
        let prev = a.clone();
        for i in 1..=(m + 1) {
            a[i] = prev[i] + k * prev[m + 1 - i];
        }
        // Update error sequences (backwards over i so b[i-1] is pre-update).
        for i in ((m + 1)..n).rev() {
            let fi = f[i];
            f[i] = fi + k * b[i - 1];
            b[i] = b[i - 1] + k * fi;
        }
    }
    a[1..].to_vec()
}

/// Durand–Kerner root finding for a real monic polynomial
/// z^p + c[0] z^(p-1) + ... + c[p-1].
pub fn poly_roots(coeffs: &[f64]) -> Vec<Complex64> {
    let p = coeffs.len();
    if p == 0 {
        return Vec::new();
    }
    let eval = |z: Complex64| -> Complex64 {
        let mut v = Complex64::new(1.0, 0.0);
        for &c in coeffs {
            v = v * z + Complex64::new(c, 0.0);
        }
        v
    };
    // Standard initialization: powers of a non-real seed of modulus ≈ 1.
    let seed = Complex64::new(0.4, 0.9);
    let mut roots: Vec<Complex64> = (0..p).map(|k| seed.powu(k as u32 + 1)).collect();
    for _ in 0..200 {
        let mut max_step = 0.0f64;
        for i in 0..p {
            let mut denom = Complex64::new(1.0, 0.0);
            for j in 0..p {
                if i != j {
                    denom *= roots[i] - roots[j];
                }
            }
            if denom.norm() < 1e-30 {
                continue;
            }
            let step = eval(roots[i]) / denom;
            roots[i] -= step;
            max_step = max_step.max(step.norm());
        }
        if max_step < 1e-12 {
            break;
        }
    }
    roots
}

fn gaussian_window(n: usize) -> Vec<f64> {
    let edge = (-12.0f64).exp();
    (0..n)
        .map(|i| {
            let x = 2.0 * i as f64 / (n - 1) as f64 - 1.0;
            ((-12.0 * x * x).exp() - edge) / (1.0 - edge)
        })
        .collect()
}

pub fn track_formants(samples: &[f64], sample_rate: u32, params: &FormantParams) -> FormantTrack {
    let sr_work = 2.0 * params.ceiling_hz;
    let work = resample(samples, sample_rate as f64, sr_work);
    let mut source = work;
    crate::spectrogram::pre_emphasize(&mut source, sr_work, params.pre_emphasis_hz);

    // Physical window is twice the effective length (Gaussian-like window).
    let win_n = ((2.0 * params.window_s * sr_work).round() as usize).max(4);
    let hop = ((params.time_step_s * sr_work).round() as usize).max(1);
    let order = 2 * params.max_formants;
    let window = gaussian_window(win_n);

    let mut frames = Vec::new();
    let mut start = 0usize;
    while start + win_n <= source.len() {
        let mut frame: Vec<f64> = source[start..start + win_n]
            .iter()
            .zip(&window)
            .map(|(s, w)| s * w)
            .collect();
        // Remove DC so a constant offset does not consume a pole.
        let mean = frame.iter().sum::<f64>() / frame.len() as f64;
        for v in &mut frame {
            *v -= mean;
        }

        let time_s = (start + win_n / 2) as f64 / sr_work;
        let energy: f64 = frame.iter().map(|v| v * v).sum();
        if energy <= 0.0 {
            frames.push(FormantFrame {
                time_s,
                formants_hz: Vec::new(),
                bandwidths_hz: Vec::new(),
            });
            start += hop;
            continue;
        }

        let a = burg(&frame, order);
        let roots = poly_roots(&a);
        let mut cands: Vec<(f64, f64)> = roots
            .iter()
            .filter(|z| z.im > 0.0)
            .map(|z| {
                let freq = z.arg() * sr_work / (2.0 * std::f64::consts::PI);
                let bw = -(sr_work / std::f64::consts::PI) * z.norm().ln().min(0.0);
                (freq, bw)
            })
            .filter(|(f, b)| {
                *f > 50.0 && *f < params.ceiling_hz - 50.0 && *b <= params.max_bandwidth_hz
            })
            .collect();
        cands.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        cands.truncate(params.max_formants);

        frames.push(FormantFrame {
            time_s,
            formants_hz: cands.iter().map(|c| c.0).collect(),
            bandwidths_hz: cands.iter().map(|c| c.1).collect(),
        });
        start += hop;
    }
    FormantTrack { frames }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn polyphase_matches_generic_resampler() {
        let sr_in = 44100.0;
        let sr_out = 11000.0;
        let s: Vec<f64> = (0..8000)
            .map(|i| {
                (2.0 * std::f64::consts::PI * 700.0 * i as f64 / sr_in).sin()
                    + 0.3 * (2.0 * std::f64::consts::PI * 3100.0 * i as f64 / sr_in).cos()
            })
            .collect();
        let cutoff = (sr_out / sr_in).min(1.0) * 0.95;
        let n_out = ((s.len() as f64) * sr_out / sr_in).floor() as usize;
        let fast = resample(&s, sr_in, sr_out);
        let slow = resample_generic(&s, sr_in, sr_out, cutoff, n_out);
        assert_eq!(fast.len(), slow.len());
        for (i, (a, b)) in fast.iter().zip(&slow).enumerate() {
            assert!((a - b).abs() < 1e-9, "sample {i}: {a} vs {b}");
        }
    }

    #[test]
    fn resample_preserves_in_band_sine() {
        let sr_in = 44100.0;
        let s: Vec<f64> = (0..44100)
            .map(|i| (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / sr_in).sin())
            .collect();
        let out = resample(&s, sr_in, 11000.0);
        assert!((out.len() as i64 - 11000).abs() <= 1);
        // Interior RMS should stay ~0.707 (amplitude preserved).
        let mid = &out[2000..9000];
        let rms = (mid.iter().map(|v| v * v).sum::<f64>() / mid.len() as f64).sqrt();
        assert!((rms - 0.7071).abs() < 0.02, "rms {rms}");
    }

    #[test]
    fn resample_removes_out_of_band_energy() {
        let sr_in = 44100.0;
        // 8 kHz sine is above the 5.5 kHz Nyquist of the target rate.
        let s: Vec<f64> = (0..44100)
            .map(|i| (2.0 * std::f64::consts::PI * 8000.0 * i as f64 / sr_in).sin())
            .collect();
        let out = resample(&s, sr_in, 11000.0);
        let mid = &out[2000..9000];
        let rms = (mid.iter().map(|v| v * v).sum::<f64>() / mid.len() as f64).sqrt();
        assert!(rms < 0.02, "rms {rms}");
    }

    #[test]
    fn burg_recovers_ar2_coefficients() {
        // AR(2): x[n] = 1.5 x[n-1] - 0.9 x[n-2] + e[n], e = unit impulse.
        let mut x = vec![0.0f64; 2048];
        x[2] = 1.0;
        for n in 3..x.len() {
            x[n] = 1.5 * x[n - 1] - 0.9 * x[n - 2];
        }
        let a = burg(&x, 2);
        // Prediction polynomial 1 + a1 z^-1 + a2 z^-2 should be 1 - 1.5 + 0.9.
        assert!((a[0] + 1.5).abs() < 0.01, "a1 = {}", a[0]);
        assert!((a[1] - 0.9).abs() < 0.01, "a2 = {}", a[1]);
    }

    #[test]
    fn poly_roots_solves_known_quartic() {
        // (z^2 + 1)(z - 2)(z + 3) = z^4 + z^3 - 5 z^2 + z - 6
        let roots = poly_roots(&[1.0, -5.0, 1.0, -6.0]);
        let mut mods: Vec<(f64, f64)> = roots.iter().map(|z| (z.re, z.im)).collect();
        mods.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        let near =
            |z: (f64, f64), re: f64, im: f64| (z.0 - re).abs() < 1e-6 && (z.1 - im).abs() < 1e-6;
        assert!(near(mods[0], -3.0, 0.0));
        assert!(near(mods[3], 2.0, 0.0));
        assert!(mods[1].1.abs() > 0.999 && mods[1].0.abs() < 1e-6);
    }

    /// Impulse train through second-order resonators = synthetic vowel with
    /// known formants; the tracker should recover them.
    fn synth_vowel(f0: f64, formants: &[(f64, f64)], sr: f64, dur_s: f64) -> Vec<f64> {
        let n = (sr * dur_s) as usize;
        let period = (sr / f0).round() as usize;
        let mut x: Vec<f64> = (0..n)
            .map(|i| if i % period == 0 { 1.0 } else { 0.0 })
            .collect();
        for &(freq, bw) in formants {
            let r = (-std::f64::consts::PI * bw / sr).exp();
            let theta = 2.0 * std::f64::consts::PI * freq / sr;
            let (b1, b2) = (2.0 * r * theta.cos(), -r * r);
            let mut y = vec![0.0f64; n];
            for i in 0..n {
                let mut v = x[i];
                if i >= 1 {
                    v += b1 * y[i - 1];
                }
                if i >= 2 {
                    v += b2 * y[i - 2];
                }
                y[i] = v;
            }
            x = y;
        }
        // Normalize to a speech-like level.
        let peak = x.iter().fold(0.0f64, |m, v| m.max(v.abs()));
        x.iter().map(|v| v / peak * 0.3).collect()
    }

    fn median(mut v: Vec<f64>) -> f64 {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[v.len() / 2]
    }

    #[test]
    fn recovers_formants_of_synthetic_vowel_a() {
        // /a/-like: F1 700, F2 1220, F3 2600 (male-ish, F0 120).
        let truth = [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)];
        let s = synth_vowel(120.0, &truth, 16000.0, 0.5);
        let t = track_formants(&s, 16000, &Default::default());
        assert!(t.frames.len() > 30);
        for (fi, &(truth_f, _)) in truth.iter().enumerate() {
            let got: Vec<f64> = t
                .frames
                .iter()
                .filter(|fr| fr.formants_hz.len() > fi)
                .map(|fr| fr.formants_hz[fi])
                .collect();
            assert!(got.len() > 30, "formant {} missing", fi + 1);
            let med = median(got);
            assert!(
                (med - truth_f).abs() < 50.0,
                "F{}: median {med}, truth {truth_f}",
                fi + 1
            );
        }
    }

    #[test]
    fn recovers_formants_of_synthetic_vowel_i_female() {
        // /i/-like female: F1 310, F2 2790, F3 3310 (F0 220).
        let truth = [(310.0, 60.0), (2790.0, 100.0), (3310.0, 140.0)];
        let s = synth_vowel(220.0, &truth, 44100.0, 0.5);
        let t = track_formants(&s, 44100, &Default::default());
        let mut ok = [0usize; 3];
        let mut total = 0usize;
        for fr in &t.frames {
            if fr.formants_hz.len() < 3 {
                continue;
            }
            total += 1;
            for (fi, &(truth_f, _)) in truth.iter().enumerate() {
                // F1 gets a wider tolerance: with F0 220 the harmonics are
                // 220 Hz apart and LPC pulls a low formant toward the
                // nearest harmonic — a known bias shared by Praat, which
                // the M3 validation harness measures against directly.
                let tol = if fi == 0 { 120.0 } else { 75.0 };
                if (fr.formants_hz[fi] - truth_f).abs() < tol {
                    ok[fi] += 1;
                }
            }
        }
        assert!(total > 30);
        for (fi, &n) in ok.iter().enumerate() {
            assert!(
                n as f64 / total as f64 > 0.8,
                "F{} within tolerance on only {n}/{total} frames",
                fi + 1
            );
        }
    }

    #[test]
    #[ignore]
    fn dump_candidates() {
        for (name, f0, truth, sr) in [
            (
                "a",
                120.0,
                [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)],
                16000.0,
            ),
            (
                "i",
                220.0,
                [(310.0, 60.0), (2790.0, 100.0), (3310.0, 140.0)],
                44100.0,
            ),
        ] {
            let s = synth_vowel(f0, &truth, sr, 0.5);
            let t = track_formants(&s, sr as u32, &Default::default());
            for fr in t.frames.iter().skip(20).take(3) {
                let pairs: Vec<String> = fr
                    .formants_hz
                    .iter()
                    .zip(&fr.bandwidths_hz)
                    .map(|(f, b)| format!("{f:.0}/{b:.0}"))
                    .collect();
                println!("{name}: t={:.3}: {}", fr.time_s, pairs.join("  "));
            }
        }
    }

    #[test]
    fn silence_yields_empty_frames() {
        let t = track_formants(&vec![0.0; 16000], 16000, &Default::default());
        assert!(!t.frames.is_empty());
        assert!(t.frames.iter().all(|f| f.formants_hz.is_empty()));
    }
}
