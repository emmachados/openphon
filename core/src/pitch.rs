//! F0 tracking with YIN (de Cheveigné & Kawahara, JASA 2002).
//!
//! Clean-room implementation from the published paper: difference function,
//! cumulative-mean-normalized difference (CMNDF), absolute threshold with
//! descent to the local minimum, and parabolic interpolation of the lag.
//!
//! On top of the per-frame YIN decision, [`track_f0`] selects the pitch
//! path with dynamic programming over per-frame CMNDF minima (the idea of
//! Boersma 1993's candidate transition costs, reimplemented for YIN):
//! voiced candidates cost their CMNDF depth plus a small octave bias, the
//! unvoiced candidate costs a fixed amount, and transitions pay for octave
//! jumps and voicing flips. Temporal continuity then rescues borderline
//! voiced frames inside voiced stretches and suppresses isolated false
//! voicings, without moving F0 on clean material. The plain per-frame rule
//! remains available as [`track_f0_per_frame`].
//!
//! The difference function is computed via FFT correlation:
//! `d(tau) = E1 + E2(tau) - 2 r(tau)` with `E1` the window energy, `E2` a
//! sliding energy from prefix sums, and `r` the linear cross-correlation of
//! the window against the frame (naive form is O(tau_max^2) per frame and
//! dominated whole-file tracking; the identity is exact, differences are
//! float rounding only).

use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};
use std::sync::Arc;

#[derive(Debug, Clone, Copy)]
pub struct F0Params {
    /// Hop between frames in seconds.
    pub time_step_s: f64,
    pub f0_min_hz: f64,
    pub f0_max_hz: f64,
    /// CMNDF absolute threshold (paper suggests ~0.1).
    pub threshold: f64,
    /// Local cost of the unvoiced candidate, in CMNDF units. See the
    /// discussion at [`DEFAULT_UNVOICED_COST`]; the field exists so the
    /// validation harness can sweep the value without a rebuild.
    pub unvoiced_cost: f64,
    /// Fraction of the recording's absolute peak below which a frame is
    /// probably silent; see [`DEFAULT_SILENCE_THRESHOLD`]. 0 disables the
    /// level term.
    pub silence_threshold: f64,
}

impl Default for F0Params {
    fn default() -> Self {
        F0Params {
            time_step_s: 0.01,
            f0_min_hz: 75.0,
            f0_max_hz: 600.0,
            threshold: 0.1,
            unvoiced_cost: DEFAULT_UNVOICED_COST,
            silence_threshold: DEFAULT_SILENCE_THRESHOLD,
        }
    }
}

#[derive(Debug)]
pub struct F0Track {
    /// Frame centre times, seconds.
    pub times_s: Vec<f64>,
    /// F0 in Hz; 0.0 marks an unvoiced frame.
    pub f0_hz: Vec<f64>,
}

/// Naive O(tau_max^2) difference function; retained as the reference the
/// FFT path is tested against.
#[cfg(test)]
fn difference_naive(frame: &[f64], tau_max: usize) -> Vec<f64> {
    let w = tau_max; // integration window equals the maximum lag
    let mut d = vec![0.0f64; tau_max + 1];
    for tau in 1..=tau_max {
        let mut acc = 0.0;
        for j in 0..w {
            let diff = frame[j] - frame[j + tau];
            acc += diff * diff;
        }
        d[tau] = acc;
    }
    d
}

/// Reusable FFT plan and buffers for the per-frame difference function.
struct DiffScratch {
    n: usize,
    fft: Arc<dyn Fft<f64>>,
    ifft: Arc<dyn Fft<f64>>,
    a: Vec<Complex<f64>>,
    b: Vec<Complex<f64>>,
    prefix_sq: Vec<f64>,
}

impl DiffScratch {
    fn new(frame_n: usize) -> Self {
        // Lags reach tau_max = frame_n/2; the window is frame_n/2 long, so
        // indices j + tau stay < frame_n. N >= frame_n avoids circular wrap.
        let n = frame_n.next_power_of_two();
        let mut planner = FftPlanner::new();
        DiffScratch {
            n,
            fft: planner.plan_fft_forward(n),
            ifft: planner.plan_fft_inverse(n),
            a: vec![Complex::default(); n],
            b: vec![Complex::default(); n],
            prefix_sq: vec![0.0; frame_n + 1],
        }
    }

    /// `d(tau)` for `tau in 0..=tau_max` over one frame of `2 * tau_max`
    /// samples.
    fn difference(&mut self, frame: &[f64], tau_max: usize) -> Vec<f64> {
        let w = tau_max;
        // Sliding energies via prefix sums of squares.
        self.prefix_sq[0] = 0.0;
        for (j, &x) in frame.iter().enumerate() {
            self.prefix_sq[j + 1] = self.prefix_sq[j] + x * x;
        }
        let e1 = self.prefix_sq[w];

        // r(tau) = sum_{j<w} frame[j] * frame[j+tau] via FFT correlation.
        for i in 0..self.n {
            self.a[i] = Complex::new(frame.get(i).copied().unwrap_or(0.0), 0.0);
            self.b[i] = Complex::new(if i < w { frame[i] } else { 0.0 }, 0.0);
        }
        self.fft.process(&mut self.a);
        self.fft.process(&mut self.b);
        for i in 0..self.n {
            self.a[i] *= self.b[i].conj();
        }
        self.ifft.process(&mut self.a);

        let scale = 1.0 / self.n as f64;
        let mut d = vec![0.0f64; tau_max + 1];
        for (tau, out) in d.iter_mut().enumerate().skip(1) {
            let e2 = self.prefix_sq[tau + w] - self.prefix_sq[tau];
            let r = self.a[tau].re * scale;
            // The identity is exact; clamp the float dust below zero.
            *out = (e1 + e2 - 2.0 * r).max(0.0);
        }
        d
    }
}

/// CMNDF from the raw difference function.
fn cmndf_from_difference(d: &[f64]) -> Vec<f64> {
    let tau_max = d.len() - 1;
    let mut out = vec![1.0f64; tau_max + 1];
    let mut running = 0.0f64;
    for tau in 1..=tau_max {
        running += d[tau];
        // Digital silence gives running == 0; keep 1.0 (maximally aperiodic).
        if running > 0.0 {
            out[tau] = d[tau] * tau as f64 / running;
        }
    }
    out
}

/// Parabolic interpolation of the minimum around integer lag `tau`.
fn refine_lag(dp: &[f64], tau: usize) -> f64 {
    if tau == 0 || tau + 1 >= dp.len() {
        return tau as f64;
    }
    let (a, b, c) = (dp[tau - 1], dp[tau], dp[tau + 1]);
    let denom = a - 2.0 * b + c;
    if denom.abs() < 1e-12 {
        return tau as f64;
    }
    let shift = 0.5 * (a - c) / denom;
    tau as f64 + shift.clamp(-1.0, 1.0)
}

/// Per-frame YIN decision (paper's absolute-threshold rule). Retained for
/// comparison with the path-selected tracker; not used by the app.
pub fn track_f0_per_frame(samples: &[f64], sample_rate: u32, params: &F0Params) -> F0Track {
    let sr = sample_rate as f64;
    let tau_max = (sr / params.f0_min_hz).ceil() as usize;
    let tau_min = ((sr / params.f0_max_hz).floor() as usize).max(2);
    let frame_n = 2 * tau_max;
    let hop = ((params.time_step_s * sr).round() as usize).max(1);

    let mut times_s = Vec::new();
    let mut f0_hz = Vec::new();
    let mut scratch = DiffScratch::new(frame_n);
    let mut start = 0usize;
    while start + frame_n <= samples.len() {
        let frame = &samples[start..start + frame_n];
        let dp = cmndf_from_difference(&scratch.difference(frame, tau_max));

        // First lag below threshold, then descend while still decreasing.
        let mut best: Option<usize> = None;
        let mut tau = tau_min;
        while tau <= tau_max {
            if dp[tau] < params.threshold {
                while tau + 1 <= tau_max && dp[tau + 1] < dp[tau] {
                    tau += 1;
                }
                best = Some(tau);
                break;
            }
            tau += 1;
        }
        // No dip under the threshold: unvoiced.
        let f0 = match best {
            Some(tau) => sr / refine_lag(&dp, tau),
            None => 0.0,
        };
        times_s.push((start + frame_n / 2) as f64 / sr);
        f0_hz.push(if f0 >= params.f0_min_hz && f0 <= params.f0_max_hz {
            f0
        } else {
            0.0
        });
        start += hop;
    }
    F0Track { times_s, f0_hz }
}

/// Path-selection tuning. Costs are in CMNDF units (0 = perfectly
/// periodic, ~1 = aperiodic); transition costs are per 10 ms step and
/// scaled by the actual time step like Praat's.
const MAX_CANDIDATES: usize = 4;
/// Per-octave bias toward shorter lags; breaks ties against subharmonics.
const OCTAVE_COST: f64 = 0.01;
/// Cost per octave jumped between consecutive voiced frames.
const OCTAVE_JUMP_COST: f64 = 0.35;
/// Cost of a voiced <-> unvoiced flip.
const VOICED_UNVOICED_COST: f64 = 0.14;
/// Default local cost of the unvoiced candidate, in CMNDF units, before the
/// level term of [`DEFAULT_SILENCE_THRESHOLD`] lowers it for faint frames.
/// Above the YIN threshold (0.1) the path tracker voices frames the
/// per-frame rule rejects, provided their neighbours support them.
/// Calibrated on the calibration subset of the public tier with the level
/// term in place (`validation/voicing_diagnosis.py --subset calib`):
/// agreement with Praat is 94.01 / 94.34 / 94.43 / 93.97% at 0.45 / 0.475 /
/// 0.50 / 0.55. The whispered synthetic vowel bounds the value from above:
/// its false voicing is 2.2% up to 0.50, then 3.4 / 7.9 / 20.2% at 0.51 /
/// 0.53 / 0.55. The value is the point of the 0.475..0.50 plateau farthest
/// from that cliff, the same rule that chose the previous 0.40, which was
/// calibrated without the level term.
pub const DEFAULT_UNVOICED_COST: f64 = 0.475;

/// Default silence threshold, as a fraction of the recording's absolute
/// peak. Boersma (1993, IFA Proceedings 17, eq. 23) lowers the cost of the
/// unvoiced candidate as a frame's local peak falls relative to the global
/// peak, so that periodic but faint material (hum, reverberation tails,
/// breath) is not voiced. Without that term the tracker voiced 3,787 frames
/// of the public evaluation subset more than 30 dB below the loudest frame,
/// where Praat voices almost none (`validation/voicing_diagnosis.py`). The
/// value is the published default, not a calibrated one.
pub const DEFAULT_SILENCE_THRESHOLD: f64 = 0.03;

/// Reduction of the unvoiced candidate's cost for a frame whose absolute
/// peak is `local_peak`. Boersma's unvoiced strength is
/// `v + max(0, 2 - (local/global) / (s / (1 + v)))` with `v` the voicing
/// threshold; in cost units (1 - strength) the level term is subtracted
/// from the unvoiced cost, and `v` is the voicing threshold implied by it.
fn silence_discount(local_peak: f64, global_peak: f64, params: &F0Params) -> f64 {
    if params.silence_threshold <= 0.0 || global_peak <= 0.0 {
        return 0.0;
    }
    let v = 1.0 - params.unvoiced_cost;
    let ratio = local_peak / global_peak;
    (2.0 - ratio / (params.silence_threshold / (1.0 + v))).max(0.0)
}

/// One frame's pitch hypothesis: `f0 == 0.0` is the unvoiced candidate.
#[derive(Clone, Copy)]
struct Candidate {
    f0: f64,
    cost: f64,
}

/// Local minima of the CMNDF in the search range, refined and cost-biased,
/// cheapest first; the unvoiced candidate is always last.
fn frame_candidates(
    dp: &[f64],
    tau_min: usize,
    tau_max: usize,
    sr: f64,
    params: &F0Params,
    unvoiced_cost: f64,
) -> Vec<Candidate> {
    // Rank by octave-biased cost, not raw depth: on perfectly periodic
    // frames every subharmonic dip is as deep as the true one (to float
    // dust), and ranking by depth alone can crowd the true candidate out
    // of the shortlist. The bias rewards shorter lags (its log2 term is
    // negative above the floor), exactly as it does in the path costs.
    let mut out: Vec<Candidate> = Vec::new();
    for tau in tau_min..=tau_max {
        let left = dp[tau - 1];
        let right = if tau < tau_max { dp[tau + 1] } else { f64::MAX };
        if dp[tau] < left && dp[tau] <= right {
            let lag = refine_lag(dp, tau);
            let f0 = sr / lag;
            if f0 < params.f0_min_hz || f0 > params.f0_max_hz {
                continue;
            }
            let cost = dp[tau] + OCTAVE_COST * (params.f0_min_hz * lag / sr).log2();
            out.push(Candidate { f0, cost });
        }
    }
    out.sort_by(|a, b| a.cost.total_cmp(&b.cost));
    out.truncate(MAX_CANDIDATES);
    out.push(Candidate {
        f0: 0.0,
        cost: unvoiced_cost,
    });
    out
}

/// YIN with dynamic-programming path selection over per-frame candidates.
pub fn track_f0(samples: &[f64], sample_rate: u32, params: &F0Params) -> F0Track {
    let sr = sample_rate as f64;
    let tau_max = (sr / params.f0_min_hz).ceil() as usize;
    let tau_min = ((sr / params.f0_max_hz).floor() as usize).max(2);
    let frame_n = 2 * tau_max;
    let hop = ((params.time_step_s * sr).round() as usize).max(1);

    let global_peak = samples.iter().fold(0.0f64, |m, x| m.max(x.abs()));
    let mut times_s = Vec::new();
    let mut frames: Vec<Vec<Candidate>> = Vec::new();
    let mut scratch = DiffScratch::new(frame_n);
    let mut start = 0usize;
    while start + frame_n <= samples.len() {
        let frame = &samples[start..start + frame_n];
        let dp = cmndf_from_difference(&scratch.difference(frame, tau_max));
        let local_peak = frame.iter().fold(0.0f64, |m, x| m.max(x.abs()));
        let unvoiced = params.unvoiced_cost - silence_discount(local_peak, global_peak, params);
        times_s.push((start + frame_n / 2) as f64 / sr);
        frames.push(frame_candidates(&dp, tau_min, tau_max, sr, params, unvoiced));
        start += hop;
    }
    if frames.is_empty() {
        return F0Track {
            times_s,
            f0_hz: Vec::new(),
        };
    }

    // Transition costs are calibrated for a 10 ms step; a larger step makes
    // real change likelier, so the penalty shrinks proportionally.
    let step_scale = 0.01 / params.time_step_s.max(1e-6);
    let transition = |a: &Candidate, b: &Candidate| -> f64 {
        let cost = match (a.f0 > 0.0, b.f0 > 0.0) {
            (true, true) => OCTAVE_JUMP_COST * (b.f0 / a.f0).log2().abs(),
            (false, false) => 0.0,
            _ => VOICED_UNVOICED_COST,
        };
        cost * step_scale
    };

    // Viterbi: cheapest cumulative cost per candidate, with backpointers.
    let mut cum: Vec<f64> = frames[0].iter().map(|c| c.cost).collect();
    let mut back: Vec<Vec<usize>> = Vec::with_capacity(frames.len());
    back.push(vec![0; frames[0].len()]);
    for i in 1..frames.len() {
        let (prev, cur) = (&frames[i - 1], &frames[i]);
        let mut next_cum = vec![f64::MAX; cur.len()];
        let mut next_back = vec![0usize; cur.len()];
        for (k, cand) in cur.iter().enumerate() {
            for (j, p) in prev.iter().enumerate() {
                let c = cum[j] + transition(p, cand);
                if c < next_cum[k] {
                    next_cum[k] = c;
                    next_back[k] = j;
                }
            }
            next_cum[k] += cand.cost;
        }
        cum = next_cum;
        back.push(next_back);
    }

    let mut idx = (0..cum.len())
        .min_by(|&a, &b| cum[a].total_cmp(&cum[b]))
        .unwrap_or(0);
    let mut f0_hz = vec![0.0f64; frames.len()];
    for i in (0..frames.len()).rev() {
        f0_hz[i] = frames[i][idx].f0;
        idx = back[i][idx];
    }
    F0Track { times_s, f0_hz }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f64, amp: f64, sr: f64, dur_s: f64) -> Vec<f64> {
        (0..(sr * dur_s) as usize)
            .map(|i| amp * (2.0 * std::f64::consts::PI * freq * i as f64 / sr).sin())
            .collect()
    }

    fn sawtooth(freq: f64, amp: f64, sr: f64, dur_s: f64) -> Vec<f64> {
        (0..(sr * dur_s) as usize)
            .map(|i| {
                let phase = (freq * i as f64 / sr).fract();
                amp * (2.0 * phase - 1.0)
            })
            .collect()
    }

    fn voiced(track: &F0Track) -> Vec<f64> {
        track.f0_hz.iter().copied().filter(|&f| f > 0.0).collect()
    }

    #[test]
    fn sine_220_is_tracked_within_half_hz() {
        let t = track_f0(&sine(220.0, 0.5, 44100.0, 1.0), 44100, &Default::default());
        let v = voiced(&t);
        assert!(v.len() as f64 / t.f0_hz.len() as f64 > 0.95);
        for f in &v {
            assert!((f - 220.0).abs() < 0.5, "got {f}");
        }
    }

    #[test]
    fn sawtooth_110_is_tracked() {
        let t = track_f0(
            &sawtooth(110.0, 0.5, 44100.0, 1.0),
            44100,
            &Default::default(),
        );
        let v = voiced(&t);
        assert!(v.len() as f64 / t.f0_hz.len() as f64 > 0.95);
        for f in &v {
            assert!((f - 110.0).abs() < 1.0, "got {f}");
        }
    }

    #[test]
    fn low_pitch_edge_of_range() {
        let t = track_f0(&sine(80.0, 0.5, 44100.0, 1.0), 44100, &Default::default());
        let v = voiced(&t);
        assert!(!v.is_empty());
        for f in &v {
            assert!((f - 80.0).abs() < 1.0, "got {f}");
        }
    }

    #[test]
    fn white_noise_is_mostly_unvoiced() {
        // Deterministic LCG noise; no periodicity for YIN to latch onto.
        let mut state = 0x12345678u64;
        let noise: Vec<f64> = (0..44100)
            .map(|_| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                (state >> 33) as f64 / (1u64 << 31) as f64 - 1.0
            })
            .collect();
        let t = track_f0(&noise, 44100, &Default::default());
        let voiced_ratio = voiced(&t).len() as f64 / t.f0_hz.len() as f64;
        assert!(voiced_ratio < 0.2, "voiced ratio {voiced_ratio}");
    }

    #[test]
    fn silence_is_unvoiced() {
        let t = track_f0(&vec![0.0; 44100], 44100, &Default::default());
        assert!(t.f0_hz.iter().all(|&f| f == 0.0));
    }

    #[test]
    fn pitch_step_is_followed() {
        // 0.5 s at 150 Hz then 0.5 s at 300 Hz.
        let mut s = sine(150.0, 0.5, 44100.0, 0.5);
        s.extend(sine(300.0, 0.5, 44100.0, 0.5));
        let t = track_f0(&s, 44100, &Default::default());
        // Sample well inside each half, away from the discontinuity.
        for (i, &time) in t.times_s.iter().enumerate() {
            let f = t.f0_hz[i];
            if time > 0.1 && time < 0.4 {
                assert!((f - 150.0).abs() < 1.0, "at {time}: {f}");
            }
            if time > 0.6 && time < 0.9 {
                assert!((f - 300.0).abs() < 1.0, "at {time}: {f}");
            }
        }
    }

    #[test]
    fn fft_difference_matches_naive() {
        // Mixed harmonic + noise signal; both paths must agree to float
        // rounding across every lag.
        let sr = 44100.0;
        let mut state = 0xdeadbeefu64;
        let frame: Vec<f64> = (0..1176)
            .map(|i| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let noise = (state >> 33) as f64 / (1u64 << 31) as f64 - 1.0;
                0.6 * (2.0 * std::f64::consts::PI * 173.0 * i as f64 / sr).sin() + 0.05 * noise
            })
            .collect();
        let tau_max = frame.len() / 2;
        let naive = difference_naive(&frame, tau_max);
        let fft = DiffScratch::new(frame.len()).difference(&frame, tau_max);
        for tau in 1..=tau_max {
            let tol = 1e-9 * naive[tau].max(1.0);
            assert!(
                (naive[tau] - fft[tau]).abs() < tol,
                "tau {tau}: naive {} vs fft {}",
                naive[tau],
                fft[tau]
            );
        }
    }

    /// Deterministic pulse train; `jitter` perturbs each period length via
    /// an LCG, approximating creaky/pressed cycle irregularity.
    fn pulse_train(freq: f64, sr: f64, dur_s: f64, jitter: f64) -> Vec<f64> {
        let n = (sr * dur_s) as usize;
        let mut x = vec![0.0f64; n];
        let mut state = 0x2545f4914f6cdd1du64;
        let mut phase = 0.0f64;
        let mut factor = 1.0f64;
        for (i, s) in x.iter_mut().enumerate() {
            let _ = i;
            phase += freq * factor / sr;
            if phase >= 1.0 {
                phase -= 1.0;
                *s = 1.0;
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let u = (state >> 33) as f64 / (1u64 << 31) as f64 - 1.0;
                factor = (1.0 + jitter * u).max(0.5);
            }
        }
        x
    }

    #[test]
    fn per_frame_rule_remains_available() {
        let t = track_f0_per_frame(&sine(220.0, 0.5, 44100.0, 1.0), 44100, &Default::default());
        let v = voiced(&t);
        assert!(v.len() as f64 / t.f0_hz.len() as f64 > 0.95);
        for f in &v {
            assert!((f - 220.0).abs() < 0.5, "got {f}");
        }
    }

    #[test]
    fn periodic_pulses_do_not_octave_drop() {
        // A perfect pulse train has equally deep CMNDF dips at every
        // multiple of the true period; the candidate shortlist must keep
        // the true one (regression: depth-ranked truncation once kept only
        // subharmonics on such frames).
        let t = track_f0(
            &pulse_train(450.0, 44100.0, 1.0, 0.0),
            44100,
            &Default::default(),
        );
        let v = voiced(&t);
        assert!(v.len() as f64 / t.f0_hz.len() as f64 > 0.9);
        for f in &v {
            assert!((f - 450.0).abs() < 5.0, "got {f}");
        }
    }

    #[test]
    fn path_selection_beats_per_frame_on_jittered_pulses() {
        // 2% cycle jitter near the pitch floor: the per-frame rule drops
        // many genuinely voiced frames; temporal continuity must recover a
        // solid majority of them without gross F0 errors.
        let x = pulse_train(80.0, 44100.0, 1.5, 0.02);
        let params = F0Params::default();
        let dp = track_f0(&x, 44100, &params);
        let pf = track_f0_per_frame(&x, 44100, &params);
        let dp_voiced = voiced(&dp).len();
        let pf_voiced = voiced(&pf).len();
        assert!(
            dp_voiced >= pf_voiced,
            "path {dp_voiced} < per-frame {pf_voiced}"
        );
        assert!(
            dp_voiced as f64 / dp.f0_hz.len() as f64 > 0.8,
            "voiced only {dp_voiced}/{}",
            dp.f0_hz.len()
        );
        for f in voiced(&dp) {
            assert!((f - 80.0).abs() < 8.0, "gross error: {f}");
        }
    }

    #[test]
    fn respects_search_range() {
        // 50 Hz sine is below f0_min: must come out unvoiced, not octave-folded.
        let t = track_f0(&sine(50.0, 0.5, 44100.0, 1.0), 44100, &Default::default());
        for &f in &t.f0_hz {
            assert!(f == 0.0 || (f - 100.0).abs() < 2.0, "got {f}");
        }
    }
}
