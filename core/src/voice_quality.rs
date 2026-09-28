//! Voice-quality measures on sustained phonation: harmonics-to-noise
//! ratio, and period/amplitude perturbation (jitter, shimmer).
//!
//! Clean-room from the published descriptions:
//!   - HNR: Boersma (1993), "Accurate short-term analysis of the
//!     fundamental frequency and the harmonics-to-noise ratio of a
//!     sampled sound". Per frame, the normalized autocorrelation of the
//!     windowed signal is divided by the autocorrelation of the window
//!     itself; the height r of its first strong peak in the pitch range
//!     gives HNR = 10 log10(r / (1 - r)).
//!   - Jitter/shimmer: from a sequence of glottal-pulse times (a point
//!     process). Each period's pulse is the signal peak within a window
//!     around the F0-predicted location; jitter and shimmer are the
//!     classical period- and amplitude-perturbation ratios (Praat's
//!     "local" definitions).
//!
//! These are gated against Praat's Voice Report on sustained vowels
//! before release (validation/voice_quality tier); see VALIDATION.md.

use crate::pitch::{self, F0Params};

/// Only period pairs whose two periods differ by less than this factor
/// count toward jitter/shimmer, matching Praat's default 1.3 "maximum
/// period factor": a doubled/halved period is a tracking slip, not
/// cycle-to-cycle perturbation.
const MAX_PERIOD_FACTOR: f64 = 1.3;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VoiceReport {
    /// Mean harmonics-to-noise ratio over voiced frames, dB. `None` when
    /// no frame is voiced.
    pub mean_hnr_db: Option<f64>,
    /// Number of glottal periods detected (pulse count - 1).
    pub n_periods: usize,
    /// Jitter (local): mean absolute period difference over mean period.
    /// `None` with fewer than two usable period pairs.
    pub jitter_local: Option<f64>,
    /// Shimmer (local): mean absolute amplitude difference over mean
    /// amplitude, on consecutive pulses. `None` if too few pulses.
    pub shimmer_local: Option<f64>,
    /// Median F0 over voiced frames, Hz. `None` when no frame is voiced.
    pub median_f0_hz: Option<f64>,
    /// Mean F0 over voiced frames, Hz.
    pub mean_f0_hz: Option<f64>,
    /// Population standard deviation of F0 over voiced frames, Hz.
    /// `None` with fewer than two voiced frames.
    pub sd_f0_hz: Option<f64>,
}

/// Median / mean / population SD over the voiced frames of a track.
fn f0_summary(f0_hz: &[f64]) -> (Option<f64>, Option<f64>, Option<f64>) {
    let mut voiced: Vec<f64> = f0_hz.iter().copied().filter(|&f| f > 0.0).collect();
    if voiced.is_empty() {
        return (None, None, None);
    }
    voiced.sort_by(|a, b| a.total_cmp(b));
    let n = voiced.len();
    let median = if n % 2 == 1 {
        voiced[n / 2]
    } else {
        (voiced[n / 2 - 1] + voiced[n / 2]) / 2.0
    };
    let mean = voiced.iter().sum::<f64>() / n as f64;
    let sd = (n >= 2).then(|| {
        (voiced.iter().map(|f| (f - mean).powi(2)).sum::<f64>() / n as f64).sqrt()
    });
    (Some(median), Some(mean), sd)
}

/// One frame's harmonicity: the normalized-autocorrelation peak height in
/// [0,1), or `None` if the frame has no voiced peak.
fn frame_harmonicity(frame: &[f64], sr: f64, params: &F0Params) -> Option<f64> {
    let n = frame.len();
    // Hanning window and its own autocorrelation (Boersma's correction:
    // the windowed-signal autocorrelation is the true autocorrelation
    // times the window autocorrelation, so we divide it back out).
    let win: Vec<f64> = (0..n)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (n - 1) as f64).cos())
        .collect();
    let wx: Vec<f64> = frame.iter().zip(&win).map(|(x, w)| x * w).collect();

    let tau_min = (sr / params.f0_max_hz).floor() as usize;
    let tau_max = ((sr / params.f0_min_hz).ceil() as usize).min(n - 1);
    if tau_min < 1 || tau_max <= tau_min {
        return None;
    }

    let autocorr = |sig: &[f64], tau: usize| -> f64 {
        let mut acc = 0.0;
        for i in 0..(n - tau) {
            acc += sig[i] * sig[i + tau];
        }
        acc
    };
    let r_signal0 = autocorr(&wx, 0);
    let r_window0 = autocorr(&win, 0);
    if r_signal0 <= 0.0 || r_window0 <= 0.0 {
        return None;
    }

    // Corrected normalized autocorrelation across the lag range.
    let r_at = |tau: usize| -> f64 {
        let rw = autocorr(&win, tau) / r_window0;
        if rw.abs() < 1e-6 {
            return 0.0;
        }
        (autocorr(&wx, tau) / r_signal0) / rw
    };
    let mut best_tau = tau_min;
    let mut best = r_at(tau_min);
    for tau in (tau_min + 1)..=tau_max {
        let r = r_at(tau);
        if r > best {
            best = r;
            best_tau = tau;
        }
    }
    // Parabolic interpolation of the peak: the true maximum lies between
    // integer lags, and its height (not the integer-lag sample) is what
    // sets the harmonics-to-noise ratio. Without this HNR reads several dB
    // low on real periodicity (Boersma interpolates the peak for the same
    // reason).
    if best_tau > tau_min && best_tau < tau_max {
        let (a, b, c) = (r_at(best_tau - 1), best, r_at(best_tau + 1));
        let denom = a - 2.0 * b + c;
        if denom.abs() > 1e-12 {
            let off = 0.5 * (a - c) / denom;
            let vertex = b - 0.25 * (a - c) * off;
            if vertex > best {
                best = vertex;
            }
        }
    }
    // Clamp below 1: numerical overshoot on near-perfect periodicity would
    // send the dB ratio to +inf.
    (best > 0.0).then(|| best.min(0.999999))
}

/// Mean HNR in dB over frames whose harmonicity clears `voicing_floor`
/// (Praat's silence/voicing threshold on the peak height; 0.45 ~ its
/// default voicing threshold). `None` if no frame qualifies.
fn mean_hnr(samples: &[f64], sr: f64, params: &F0Params, voicing_floor: f64) -> Option<f64> {
    let win_s = 6.0 / params.f0_min_hz; // >= 6 periods, as Praat recommends
    let win_n = ((win_s * sr).round() as usize).max(2).min(samples.len());
    if win_n < 2 {
        return None;
    }
    let hop = ((params.time_step_s * sr).round() as usize).max(1);
    let mut sum = 0.0;
    let mut count = 0usize;
    let mut start = 0;
    while start + win_n <= samples.len() {
        if let Some(r) = frame_harmonicity(&samples[start..start + win_n], sr, params) {
            if r >= voicing_floor {
                sum += 10.0 * (r / (1.0 - r)).log10();
                count += 1;
            }
        }
        start += hop;
    }
    (count > 0).then(|| sum / count as f64)
}

/// Parabolic vertex of three samples around index `i` (the extremum): the
/// sub-sample offset in [-0.5, 0.5] from `i` and the interpolated
/// magnitude. Sub-sample precision matters: at 220 Hz an integer-sample
/// period is quantized to ~0.5%, which alone would masquerade as jitter.
fn parabolic_peak(samples: &[f64], i: usize) -> (f64, f64) {
    if i == 0 || i + 1 >= samples.len() {
        return (0.0, samples[i].abs());
    }
    let (a, b, c) = (samples[i - 1], samples[i], samples[i + 1]);
    let denom = a - 2.0 * b + c;
    if denom.abs() < 1e-12 {
        return (0.0, b.abs());
    }
    let offset = 0.5 * (a - c) / denom;
    let vertex = b - 0.25 * (a - c) * offset;
    (offset.clamp(-0.5, 0.5), vertex.abs())
}

/// Glottal-pulse times and their signal amplitudes, one per period. The
/// F0 track predicts each period's length; within a window around the
/// predicted next pulse the true pulse is the strongest peak of a fixed
/// polarity (glottal closure is a consistent-sign excursion — searching
/// `|x|` would alternate between the positive and negative lobes and
/// double the apparent jitter). Positions and amplitudes are parabolically
/// interpolated for sub-sample precision.
fn point_process(samples: &[f64], sr: f64, f0: &pitch::F0Track) -> (Vec<f64>, Vec<f64>) {
    let f0_at = |t: f64| -> f64 {
        if f0.times_s.is_empty() {
            return 0.0;
        }
        let mut best = 0usize;
        for i in 1..f0.times_s.len() {
            if (f0.times_s[i] - t).abs() < (f0.times_s[best] - t).abs() {
                best = i;
            }
        }
        f0.f0_hz[best]
    };

    // Peak of a chosen polarity in [center-half, center+half]. `positive`
    // picks the largest sample; otherwise the smallest (most negative).
    let peak_near = |center: usize, half: usize, positive: bool| -> Option<usize> {
        let lo = center.saturating_sub(half);
        let hi = (center + half).min(samples.len().saturating_sub(1));
        if lo >= hi {
            return None;
        }
        (lo..=hi).max_by(|&a, &b| {
            let (va, vb) = if positive {
                (samples[a], samples[b])
            } else {
                (-samples[a], -samples[b])
            };
            va.total_cmp(&vb)
        })
    };

    let mut times = Vec::new();
    let mut amps = Vec::new();

    let mut i = 0usize;
    while i < samples.len() && f0_at(i as f64 / sr) <= 0.0 {
        i += 1;
    }
    if i >= samples.len() {
        return (times, amps);
    }
    let seed_f0 = f0_at(i as f64 / sr);
    let seed_period = (sr / seed_f0).round() as usize;
    // Lock polarity to whichever lobe is larger over the seed period.
    let pos = peak_near(i + seed_period / 2, seed_period / 2, true);
    let neg = peak_near(i + seed_period / 2, seed_period / 2, false);
    let positive = match (pos, neg) {
        (Some(p), Some(n)) => samples[p] >= -samples[n],
        (Some(_), None) => true,
        _ => false,
    };
    let Some(mut cur) = peak_near(i + seed_period / 2, seed_period / 2, positive) else {
        return (times, amps);
    };
    let push = |times: &mut Vec<f64>, amps: &mut Vec<f64>, idx: usize| {
        let (off, amp) = parabolic_peak(samples, idx);
        times.push((idx as f64 + off) / sr);
        amps.push(amp);
    };
    push(&mut times, &mut amps, cur);

    loop {
        let t = cur as f64 / sr;
        let f = f0_at(t);
        if f <= 0.0 {
            break;
        }
        let period = (sr / f).round().max(1.0) as usize;
        let predicted = cur + period;
        if predicted >= samples.len() {
            break;
        }
        // Once locked, keep the window tight (±15% of the period) so a
        // strong formant lobe cannot pull the mark off the pulse.
        let half = (period as f64 * 0.15).round() as usize;
        let Some(next) = peak_near(predicted, half.max(1), positive) else {
            break;
        };
        if next <= cur {
            break;
        }
        push(&mut times, &mut amps, next);
        cur = next;
    }
    (times, amps)
}

/// Jitter (local): mean |T_i - T_{i-1}| over mean T_i, on period pairs
/// within the maximum-period-factor bound.
fn jitter_local(times: &[f64]) -> Option<f64> {
    if times.len() < 3 {
        return None;
    }
    let periods: Vec<f64> = times.windows(2).map(|w| w[1] - w[0]).collect();
    let mut abs_diff_sum = 0.0;
    let mut pair_count = 0usize;
    let mut period_sum = 0.0;
    let mut period_count = 0usize;
    for w in periods.windows(2) {
        let (a, b) = (w[0], w[1]);
        if a <= 0.0 || b <= 0.0 {
            continue;
        }
        let ratio = (a / b).max(b / a);
        if ratio > MAX_PERIOD_FACTOR {
            continue;
        }
        abs_diff_sum += (b - a).abs();
        pair_count += 1;
    }
    for &p in &periods {
        if p > 0.0 {
            period_sum += p;
            period_count += 1;
        }
    }
    if pair_count == 0 || period_count == 0 {
        return None;
    }
    let mean_abs_diff = abs_diff_sum / pair_count as f64;
    let mean_period = period_sum / period_count as f64;
    Some(mean_abs_diff / mean_period)
}

/// Shimmer (local): mean |A_i - A_{i-1}| over mean A_i, on consecutive
/// pulses whose periods are within the maximum-period-factor bound.
fn shimmer_local(times: &[f64], amps: &[f64]) -> Option<f64> {
    if amps.len() < 3 {
        return None;
    }
    let mut abs_diff_sum = 0.0;
    let mut pair_count = 0usize;
    for i in 1..amps.len() {
        // Guard with the same period-factor rule as jitter, using the
        // periods bracketing pulse i.
        if i >= 2 {
            let p_prev = times[i - 1] - times[i - 2];
            let p_cur = times[i] - times[i - 1];
            if p_prev > 0.0 && p_cur > 0.0 {
                let ratio = (p_prev / p_cur).max(p_cur / p_prev);
                if ratio > MAX_PERIOD_FACTOR {
                    continue;
                }
            }
        }
        abs_diff_sum += (amps[i] - amps[i - 1]).abs();
        pair_count += 1;
    }
    let mean_amp = amps.iter().sum::<f64>() / amps.len() as f64;
    if pair_count == 0 || mean_amp <= 0.0 {
        return None;
    }
    Some((abs_diff_sum / pair_count as f64) / mean_amp)
}

/// Full voice report over a (assumed sustained, voiced) signal.
pub fn analyze(samples: &[f64], sample_rate: u32, params: &F0Params) -> VoiceReport {
    let sr = sample_rate as f64;
    let f0 = pitch::track_f0(samples, sample_rate, params);
    let (times, amps) = point_process(samples, sr, &f0);
    let (median_f0_hz, mean_f0_hz, sd_f0_hz) = f0_summary(&f0.f0_hz);
    VoiceReport {
        mean_hnr_db: mean_hnr(samples, sr, params, 0.45),
        n_periods: times.len().saturating_sub(1),
        jitter_local: jitter_local(&times),
        shimmer_local: shimmer_local(&times, &amps),
        median_f0_hz,
        mean_f0_hz,
        sd_f0_hz,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: u32 = 44100;

    fn sine(freq: f64, amp: f64, dur_s: f64) -> Vec<f64> {
        (0..(SR as f64 * dur_s) as usize)
            .map(|i| amp * (2.0 * std::f64::consts::PI * freq * i as f64 / SR as f64).sin())
            .collect()
    }

    #[test]
    fn pure_tone_has_very_high_hnr_and_near_zero_perturbation() {
        let r = analyze(&sine(150.0, 0.5, 0.7), SR, &Default::default());
        // A pure sine is perfectly periodic: HNR should be very high and
        // jitter/shimmer negligible.
        assert!(r.mean_hnr_db.unwrap() > 40.0, "hnr {:?}", r.mean_hnr_db);
        assert!(r.n_periods > 80, "periods {}", r.n_periods);
        assert!(r.jitter_local.unwrap() < 0.01, "jitter {:?}", r.jitter_local);
        assert!(r.shimmer_local.unwrap() < 0.02, "shimmer {:?}", r.shimmer_local);
        // F0 summary: steady 150 Hz tone.
        assert!((r.median_f0_hz.unwrap() - 150.0).abs() < 1.0);
        assert!((r.mean_f0_hz.unwrap() - 150.0).abs() < 1.0);
        assert!(r.sd_f0_hz.unwrap() < 1.0, "sd {:?}", r.sd_f0_hz);
    }

    #[test]
    fn f0_summary_math() {
        assert_eq!(f0_summary(&[]), (None, None, None));
        assert_eq!(f0_summary(&[0.0, 0.0]), (None, None, None));
        // Single voiced frame: median = mean, no SD.
        assert_eq!(f0_summary(&[0.0, 200.0]), (Some(200.0), Some(200.0), None));
        // Even count: median averages the middle pair; unvoiced skipped.
        let (med, mean, sd) = f0_summary(&[100.0, 0.0, 300.0, 200.0, 400.0]);
        assert_eq!(med, Some(250.0));
        assert_eq!(mean, Some(250.0));
        assert!((sd.unwrap() - 111.803398875).abs() < 1e-6);
    }

    #[test]
    fn additive_noise_lowers_hnr() {
        // Deterministic noise added to a tone -> finite, lower HNR.
        let mut state = 0x1234_5678_9abc_def0u64;
        let mut s = sine(150.0, 0.5, 0.7);
        for v in &mut s {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let n = (state >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0;
            *v += 0.15 * n;
        }
        let hnr = analyze(&s, SR, &Default::default()).mean_hnr_db.unwrap();
        // ~10 dB expected for this signal/noise ratio; well below the tone.
        assert!(hnr > 3.0 && hnr < 25.0, "hnr {hnr}");
    }

    #[test]
    fn amplitude_modulation_raises_shimmer() {
        // 6% cycle-synchronous amplitude wobble via a slow modulator.
        let f0 = 150.0;
        let s: Vec<f64> = (0..(SR as f64 * 0.7) as usize)
            .map(|i| {
                let t = i as f64 / SR as f64;
                let am = 1.0 + 0.06 * (2.0 * std::f64::consts::PI * f0 * t).sin().signum()
                    * (i as f64 * 0.7).fract();
                0.5 * am * (2.0 * std::f64::consts::PI * f0 * t).sin()
            })
            .collect();
        let clean = analyze(&sine(f0, 0.5, 0.7), SR, &Default::default())
            .shimmer_local
            .unwrap();
        let wobbly = analyze(&s, SR, &Default::default()).shimmer_local.unwrap();
        assert!(wobbly > clean, "wobbly {wobbly} vs clean {clean}");
    }

    #[test]
    fn silence_reports_nothing() {
        let r = analyze(&vec![0.0; SR as usize / 2], SR, &Default::default());
        assert_eq!(r.mean_hnr_db, None);
        assert_eq!(r.jitter_local, None);
        assert_eq!(r.shimmer_local, None);
    }
}
