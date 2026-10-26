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
    /// Heuristic bandwidth ceiling for candidate selection. Surviving poles
    /// are sorted and compacted; rejection can change their numbered slots.
    /// A narrow bandwidth alone does not establish resonance identity.
    pub max_bandwidth_hz: f64,
    /// Place frames as Praat does: exact time step, grid centred in the
    /// signal, each frame taken around its centre time. Off by default: the
    /// default grid starts at the first sample, with the hop rounded to whole
    /// samples of the resampled signal.
    pub praat_grid: bool,
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
            praat_grid: false,
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

/// Windowed-sinc kernel coefficient at offset `x` (input samples).
fn resample_kernel(x: f64, cutoff: f64, half_taps: i64) -> f64 {
    let sinc = if x.abs() < 1e-12 {
        cutoff
    } else {
        (std::f64::consts::PI * cutoff * x).sin() / (std::f64::consts::PI * x)
    };
    // Hann taper over the tap span.
    let w = 0.5 + 0.5 * (std::f64::consts::PI * x / half_taps as f64).cos();
    sinc * w
}

/// Windowed-sinc resampling (anti-aliased for downsampling).
///
/// Integer sample rates take a polyphase fast path: the fractional output
/// positions repeat with period `sr_out / gcd`, so each phase's kernel
/// coefficients are computed once instead of two transcendentals per tap
/// per output sample (the naive form dominated formant tracking).
/// When downsampling, the sinc and its Hann window both expand by
/// `sr_in / sr_out`. Keeping a fixed number of input taps would shorten
/// the low-pass filter at higher input rates and admit aliased energy.
/// This is the rate scaling in Smith, *Physical Audio Signal Processing*,
/// https://www.dsprelated.com/freebooks/pasp/Windowed_Sinc_Interpolation.html.
pub fn resample(samples: &[f64], sr_in: f64, sr_out: f64) -> Vec<f64> {
    if (sr_in - sr_out).abs() < 1e-9 {
        return samples.to_vec();
    }
    // Cutoff relative to the input rate, leaving a little transition band.
    let cutoff = (sr_out / sr_in).min(1.0) * 0.95;
    let half_taps = (HALF_TAPS as f64 / (sr_out / sr_in).min(1.0)).ceil() as i64;
    let taps = (2 * half_taps) as usize;
    let n_out = ((samples.len() as f64) * sr_out / sr_in).floor() as usize;
    let (si, so) = (sr_in.round(), sr_out.round());
    if (sr_in - si).abs() < 1e-9 && (sr_out - so).abs() < 1e-9 && si >= 1.0 && so >= 1.0 {
        let g = gcd(si as u64, so as u64);
        let p = (so as u64 / g) as usize;
        let q = (si as u64 / g) as usize;
        // Degenerate ratios would need an enormous coefficient table; the
        // generic path handles them (never hit by real sample rates).
        if p <= 65536 && p.checked_mul(taps).is_some_and(|n| n <= 1_048_576) {
            return resample_polyphase(samples, p, q, cutoff, half_taps, n_out);
        }
    }
    resample_generic(samples, sr_in, sr_out, cutoff, half_taps, n_out)
}

fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

fn resample_polyphase(
    samples: &[f64],
    p: usize,
    q: usize,
    cutoff: f64,
    half_taps: i64,
    n_out: usize,
) -> Vec<f64> {
    // Output index k sits at input position t = k*q/p = a*q + b*q/p with
    // a = k/p, b = k%p: the fractional part depends only on the phase b.
    let n_taps = (2 * half_taps) as usize;
    let mut taps = vec![0.0f64; p * n_taps];
    let mut base = vec![0i64; p];
    for b in 0..p {
        let t = (b * q) as f64 / p as f64;
        let j0 = t.floor();
        base[b] = j0 as i64;
        for i in 0..n_taps {
            let m = i as i64 - half_taps + 1; // j = j0 + m
            taps[b * n_taps + i] = resample_kernel(t - (j0 + m as f64), cutoff, half_taps);
        }
        let row = &mut taps[b * n_taps..(b + 1) * n_taps];
        let gain = row.iter().sum::<f64>();
        for tap in row {
            *tap /= gain;
        }
    }
    let n = samples.len() as i64;
    let mut out = Vec::with_capacity(n_out);
    for k in 0..n_out {
        let (a, b) = (k / p, k % p);
        let start = (a * q) as i64 + base[b] - half_taps + 1;
        let row = &taps[b * n_taps..(b + 1) * n_taps];
        let mut acc = 0.0;
        if start >= 0 && start + n_taps as i64 <= n {
            let seg = &samples[start as usize..start as usize + n_taps];
            // With unity DC gain, y = anchor + sum(w * (x - anchor)).
            // Summing differences makes a constant segment exact across
            // phases. Otherwise roundoff survives frame centering and
            // scale-invariant Burg analysis can fit poles to a silent gap.
            // This fixed arithmetic identity has no tuned parameter; see
            // validation/release_resampling_calibration.json for its checks.
            let anchor = seg[0];
            for i in 0..n_taps {
                acc += (seg[i] - anchor) * row[i];
            }
            acc += anchor;
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
    half_taps: i64,
    n_out: usize,
) -> Vec<f64> {
    let mut out = Vec::with_capacity(n_out);
    for k in 0..n_out {
        let t = k as f64 * sr_in / sr_out; // position in input samples
        let j0 = t.floor() as i64;
        let mut acc = 0.0;
        let mut gain = 0.0;
        // Apply the same constant-preserving identity before normalization.
        // At file boundaries keep the original zero-padding calculation.
        let in_bounds = j0 - half_taps + 1 >= 0 && j0 + half_taps < samples.len() as i64;
        let anchor = if in_bounds { samples[j0 as usize] } else { 0.0 };
        for j in (j0 - half_taps + 1)..=(j0 + half_taps) {
            let weight = resample_kernel(t - j as f64, cutoff, half_taps);
            gain += weight;
            if j < 0 || j >= samples.len() as i64 {
                continue;
            }
            acc += (samples[j as usize] - anchor) * weight;
        }
        out.push(if in_bounds {
            anchor + acc / gain
        } else {
            acc / gain
        });
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

/// Numerical checks on a complete root set. Small backward error alone does
/// not establish small root error when the polynomial is ill-conditioned.
#[derive(Debug, Clone, Default)]
pub struct RootDiagnostics {
    pub iterations: usize,
    pub max_relative_step: Option<f64>,
    pub max_relative_residual: Option<f64>,
    pub max_conjugate_mismatch: Option<f64>,
    pub unpaired_nonreal_roots: usize,
    pub coefficient_backward_error: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootFailureReason {
    NonFiniteCoefficients,
    SingularIteration,
    NonFiniteIteration,
    DidNotConverge,
    NonFiniteValidation,
    ResidualTooLarge,
    UnpairedConjugates,
    InconsistentPolynomial,
}

#[derive(Debug)]
pub struct RootFailure {
    pub reason: RootFailureReason,
    pub diagnostics: RootDiagnostics,
}

#[derive(Debug)]
pub struct RootSolution {
    pub roots: Vec<Complex64>,
    pub diagnostics: RootDiagnostics,
}

// Retain the original iteration budget and step tolerance. The other checks
// use degree-scaled floating-point allowances, not acoustic error thresholds.
const ROOT_ITERATIONS: usize = 200;
const ROOT_STEP_TOLERANCE: f64 = 1e-12;
const ROOT_CONJUGATE_TOLERANCE: f64 = 8.0 * ROOT_STEP_TOLERANCE;

fn complex_is_finite(z: Complex64) -> bool {
    z.re.is_finite() && z.im.is_finite() && z.norm().is_finite()
}

fn polynomial_value(coeffs: &[f64], z: Complex64) -> Complex64 {
    coeffs.iter().fold(Complex64::new(1.0, 0.0), |v, c| {
        v * z + Complex64::new(*c, 0.0)
    })
}

fn inspect_roots(coeffs: &[f64], roots: &[Complex64], diagnostics: &mut RootDiagnostics) {
    let mut residual = 0.0f64;
    for &root in roots {
        let scale = coeffs.iter().fold(1.0, |v, c| v * root.norm() + c.abs());
        let value = polynomial_value(coeffs, root).norm();
        let relative = if scale == 0.0 && value == 0.0 {
            0.0
        } else {
            value / scale
        };
        if !scale.is_finite() || !relative.is_finite() {
            diagnostics.max_relative_residual = Some(f64::INFINITY);
            return;
        }
        residual = residual.max(relative);
    }
    diagnostics.max_relative_residual = Some(residual);

    // A real polynomial's nonreal roots must occur in conjugate pairs. Match
    // each root once; a nearest-neighbour check without ownership can reuse a
    // partner and accept the wrong number of upper-half-plane roots.
    let mut used = vec![false; roots.len()];
    let mut conjugate_error = 0.0f64;
    for (i, root) in roots.iter().enumerate() {
        if used[i] {
            continue;
        }
        used[i] = true;
        if root.im.abs() <= ROOT_CONJUGATE_TOLERANCE * root.norm().max(1.0) {
            continue;
        }
        let partner = roots
            .iter()
            .enumerate()
            .filter(|(j, other)| !used[*j] && root.im.signum() != other.im.signum())
            .map(|(j, other)| {
                (
                    j,
                    (root.conj() - other).norm() / root.norm().max(other.norm()).max(1.0),
                )
            })
            .min_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((j, error)) = partner {
            used[j] = true;
            conjugate_error = conjugate_error.max(error);
        } else {
            diagnostics.unpaired_nonreal_roots += 1;
        }
    }
    diagnostics.max_conjugate_mismatch = Some(conjugate_error);

    // Check the complete multiset, not just individual residuals: duplicate
    // copies of one exact root also have zero residual. Reconstruct prod(z-r)
    // and compare all coefficients in the infinity norm. See the definition
    // of polynomial backward error in De Teran, Dopico and Perez (2014), sec. 3:
    // https://eprints.maths.manchester.ac.uk/2162/1/berr_rootfiedlers-mims.pdf
    let mut reconstructed = vec![Complex64::new(1.0, 0.0)];
    for root in roots {
        reconstructed.push(Complex64::new(0.0, 0.0));
        for i in (1..reconstructed.len()).rev() {
            let product = root * reconstructed[i - 1];
            reconstructed[i] -= product;
        }
    }
    let scale = coeffs.iter().fold(1.0f64, |v, c| v.max(c.abs()));
    let mut error = 0.0f64;
    for (got, expected) in reconstructed[1..].iter().zip(coeffs) {
        let difference = (got - Complex64::new(*expected, 0.0)).norm();
        if !difference.is_finite() {
            error = f64::INFINITY;
            break;
        }
        error = error.max(difference / scale);
    }
    diagnostics.coefficient_backward_error = Some(error);
}

fn root_validation_failure(
    degree: usize,
    diagnostics: &RootDiagnostics,
) -> Option<RootFailureReason> {
    let (Some(residual), Some(conjugate_mismatch), Some(coefficient_error)) = (
        diagnostics.max_relative_residual,
        diagnostics.max_conjugate_mismatch,
        diagnostics.coefficient_backward_error,
    ) else {
        return Some(RootFailureReason::NonFiniteValidation);
    };
    if !residual.is_finite() {
        return Some(RootFailureReason::NonFiniteValidation);
    }
    // Horner evaluation is linear in degree; reconstruction uses quadratic
    // work. These generous roundoff allowances do not certify forward error.
    let n = degree.max(1) as f64;
    if residual > 64.0 * n * f64::EPSILON {
        return Some(RootFailureReason::ResidualTooLarge);
    }
    if diagnostics.unpaired_nonreal_roots != 0
        || !conjugate_mismatch.is_finite()
        || conjugate_mismatch > ROOT_CONJUGATE_TOLERANCE
    {
        return Some(RootFailureReason::UnpairedConjugates);
    }
    if !coefficient_error.is_finite() {
        return Some(RootFailureReason::NonFiniteValidation);
    }
    if coefficient_error > 64.0 * n * n * f64::EPSILON {
        return Some(RootFailureReason::InconsistentPolynomial);
    }
    None
}

/// Checked Durand–Kerner roots of z^p + c[0] z^(p-1) + ... + c[p-1].
/// A complete finite, converged root set must pass residual, real-polynomial
/// conjugacy and coefficient-reconstruction checks. Unresolved sets are errors;
/// the returned diagnostics do not claim a bound on individual root error.
pub fn checked_poly_roots(coeffs: &[f64]) -> Result<RootSolution, RootFailure> {
    let p = coeffs.len();
    let mut diagnostics = RootDiagnostics::default();
    if coeffs.iter().any(|c| !c.is_finite()) {
        return Err(RootFailure {
            reason: RootFailureReason::NonFiniteCoefficients,
            diagnostics,
        });
    }
    if p == 0 {
        return Ok(RootSolution {
            roots: Vec::new(),
            diagnostics,
        });
    }
    // Standard initialization: powers of a non-real seed of modulus ≈ 1.
    let seed = Complex64::new(0.4, 0.9);
    let mut roots: Vec<Complex64> = (0..p).map(|k| seed.powu(k as u32 + 1)).collect();
    let mut converged = false;
    for iteration in 1..=ROOT_ITERATIONS {
        diagnostics.iterations = iteration;
        let mut max_step = 0.0f64;
        for i in 0..p {
            let mut denom = Complex64::new(1.0, 0.0);
            for j in 0..p {
                if i != j {
                    denom *= roots[i] - roots[j];
                }
            }
            if !complex_is_finite(denom) {
                return Err(RootFailure {
                    reason: RootFailureReason::NonFiniteIteration,
                    diagnostics,
                });
            }
            if denom.norm() < 1e-30 {
                return Err(RootFailure {
                    reason: RootFailureReason::SingularIteration,
                    diagnostics,
                });
            }
            let step = polynomial_value(coeffs, roots[i]) / denom;
            roots[i] -= step;
            if !complex_is_finite(step) || !complex_is_finite(roots[i]) {
                return Err(RootFailure {
                    reason: RootFailureReason::NonFiniteIteration,
                    diagnostics,
                });
            }
            max_step = max_step.max(step.norm() / roots[i].norm().max(1.0));
        }
        diagnostics.max_relative_step = Some(max_step);
        if max_step < ROOT_STEP_TOLERANCE {
            converged = true;
            break;
        }
    }
    inspect_roots(coeffs, &roots, &mut diagnostics);
    let reason = if !converged {
        Some(RootFailureReason::DidNotConverge)
    } else {
        root_validation_failure(p, &diagnostics)
    };
    if let Some(reason) = reason {
        Err(RootFailure {
            reason,
            diagnostics,
        })
    } else {
        Ok(RootSolution { roots, diagnostics })
    }
}

/// Roots of a real monic polynomial, or an empty vector if the numerical solve
/// is unresolved. Use `checked_poly_roots` for the failure reason. Rejecting the
/// entire set prevents unverified roots from becoming displayed formants.
pub fn poly_roots(coeffs: &[f64]) -> Vec<Complex64> {
    checked_poly_roots(coeffs)
        .map(|solution| solution.roots)
        .unwrap_or_default()
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

/// Convert a pole to frequency and bandwidth. Reflecting an exterior pole to
/// 1/conj(z) preserves its angle and replaces its radius with its reciprocal:
/// B = -(sample_rate/pi) ln(min(r, 1/r)) = (sample_rate/pi) abs(ln(r)).
/// See the published LPC conversion description (not implementation source):
/// https://www.fon.hum.uva.nl/praat/manual/LPC__To_Formant.html
fn formant_from_root(root: Complex64, sample_rate: f64) -> (f64, f64) {
    let frequency = root.arg() * sample_rate / (2.0 * std::f64::consts::PI);
    let bandwidth = (sample_rate / std::f64::consts::PI) * root.norm().ln().abs();
    (frequency, bandwidth)
}

/// Start, length and centre time of each frame on the resampled signal.
fn frame_spans(
    n_in: usize,
    sr_in: u32,
    n_work: usize,
    sr_work: f64,
    win_n: usize,
    hop: usize,
    min_len: usize,
    params: &FormantParams,
) -> Vec<(usize, usize, f64)> {
    if !params.praat_grid {
        let mut spans = Vec::new();
        let mut start = 0usize;
        while start + win_n <= n_work {
            spans.push((start, win_n, (start + win_n / 2) as f64 / sr_work));
            start += hop;
        }
        return spans;
    }
    // Praat's Sampled_shortTermAnalysis on the resampled sound: frames counted
    // over its duration, grid centred on the original signal. The resampler
    // aligns output sample 0 with input sample 0.
    let dx = 1.0 / sr_work;
    let original = n_in as f64 / sr_in as f64;
    let x1 = 0.5 / sr_in as f64;
    let duration = (original * sr_work).round() * dx;
    let physical = 2.0 * params.window_s;
    if duration < physical {
        return Vec::new();
    }
    let n_frames = ((duration - physical) / params.time_step_s).floor() as usize + 1;
    let first = 0.5 * original - 0.5 * (n_frames as f64 * params.time_step_s) + 0.5 * params.time_step_s;
    (0..n_frames)
        .filter_map(|i| {
            let t = first + i as f64 * params.time_step_s;
            let left = ((t - x1) / dx).floor() as isize;
            let start = (left + 1 - (win_n / 2) as isize).max(0);
            let end = (left + 1 + (win_n / 2) as isize).min(n_work as isize);
            (end - start > min_len as isize).then(|| (start as usize, (end - start) as usize, t))
        })
        .collect()
}

pub fn track_formants(samples: &[f64], sample_rate: u32, params: &FormantParams) -> FormantTrack {
    let sr_work = 2.0 * params.ceiling_hz;
    // Remove overall constant level before resampling. Anchored subtraction
    // makes whole-file constant input exactly zero; the resampler also
    // preserves constant intervals within otherwise varying recordings.
    let anchor = samples.first().copied().unwrap_or(0.0);
    let mut centered: Vec<f64> = samples.iter().map(|s| s - anchor).collect();
    if !centered.is_empty() {
        let mean = centered.iter().sum::<f64>() / centered.len() as f64;
        for s in &mut centered {
            *s -= mean;
        }
    }
    let work = resample(&centered, sample_rate as f64, sr_work);
    let mut source = work;
    crate::spectrogram::pre_emphasize(&mut source, sr_work, params.pre_emphasis_hz);

    // Physical window is twice the effective length (Gaussian-like window).
    let win_n = ((2.0 * params.window_s * sr_work).round() as usize).max(4);
    let hop = ((params.time_step_s * sr_work).round() as usize).max(1);
    let order = 2 * params.max_formants;
    let window = gaussian_window(win_n);

    let spans = frame_spans(samples.len(), sample_rate, source.len(), sr_work, win_n, hop, order, params);
    let mut frames = Vec::new();
    for (start, len, time_s) in spans {
        // Center before windowing: windowing a constant creates a nonconstant
        // signal. Subtract an anchor first so constant frames become exactly
        // zero even when summing their original level would accumulate error.
        let anchor = source[start];
        let mut frame: Vec<f64> = source[start..start + len]
            .iter()
            .map(|s| s - anchor)
            .collect();
        let mean = frame.iter().sum::<f64>() / frame.len() as f64;
        for (v, w) in frame.iter_mut().zip(&window) {
            *v = (*v - mean) * w;
        }

        let energy: f64 = frame.iter().map(|v| v * v).sum();
        if energy <= 0.0 {
            frames.push(FormantFrame {
                time_s,
                formants_hz: Vec::new(),
                bandwidths_hz: Vec::new(),
            });
            continue;
        }

        let a = burg(&frame, order);
        let roots = poly_roots(&a);
        let mut cands: Vec<(f64, f64)> = roots
            .iter()
            .filter(|z| z.im > 0.0)
            .map(|z| formant_from_root(*z, sr_work))
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
        let half_taps = (HALF_TAPS as f64 / (sr_out / sr_in)).ceil() as i64;
        let slow = resample_generic(&s, sr_in, sr_out, cutoff, half_taps, n_out);
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
    fn downsampling_preserves_passband_and_rejects_aliases_across_input_rates() {
        for sr in [16000, 44100, 48000, 96000, 192000] {
            for (frequency, wanted_rms, tolerance) in [
                (4500.0, std::f64::consts::FRAC_1_SQRT_2, 0.005),
                (5700.0, 0.0, 0.005),
            ] {
                let s: Vec<f64> = (0..sr / 4)
                    .map(|i| (2.0 * std::f64::consts::PI * frequency * i as f64 / sr as f64).sin())
                    .collect();
                let out = resample(&s, sr as f64, 11000.0);
                let interior = &out[200..out.len() - 200];
                let rms =
                    (interior.iter().map(|v| v * v).sum::<f64>() / interior.len() as f64).sqrt();
                assert!(
                    (rms - wanted_rms).abs() < tolerance,
                    "{frequency} Hz at {sr} samples/s: RMS {rms}"
                );
            }
        }
    }

    #[test]
    fn resampling_preserves_constant_interiors_exactly_across_phases() {
        // 44,101 Hz exceeds the polyphase table-size limit, exercising the
        // generic path; 8 kHz also covers interpolation rather than decimation.
        for sr in [8000, 11000, 16000, 44100, 44101, 48000, 96000, 192000] {
            for level in [0.375, 0.1, -0.12345678, 1e-12] {
                let out = resample(&vec![level; sr / 10], sr as f64, 11000.0);
                assert!(
                    out[100..out.len() - 100].iter().all(|v| *v == level),
                    "constant {level} at {sr} samples/s acquired variation"
                );
            }
        }
    }

    #[test]
    fn resampling_boundaries_retain_zero_padding() {
        for sr in [16000, 44100, 44101] {
            let signal = vec![0.375; sr / 50];
            let original = resample(&signal, sr as f64, 11000.0);
            // A one-second input shift maps to exactly 11,000 output samples.
            // Explicit zero padding must reproduce the implicit boundary rule.
            let mut padded = vec![0.0; sr];
            padded.extend_from_slice(&signal);
            padded.resize(padded.len() + sr, 0.0);
            let reference = resample(&padded, sr as f64, 11000.0);
            for (a, b) in original.iter().zip(&reference[11000..]) {
                assert!((a - b).abs() < 1e-10, "boundary at {sr}: {a} vs {b}");
            }
            assert!(
                original[0] < signal[0],
                "boundary must not extend the constant level"
            );
        }
    }

    #[test]
    fn silent_interval_after_nonzero_audio_has_no_formant_candidates() {
        let params = FormantParams {
            max_bandwidth_hz: f64::INFINITY,
            ..Default::default()
        };
        for sr in [11000, 16000, 44100, 44101, 48000, 96000, 192000] {
            let mut signal = vec![0.0; sr as usize / 2];
            signal[sr as usize / 10..sr as usize / 5].fill(0.25);
            let track = track_formants(&signal, sr, &params);
            // These frames are wholly in exact zero input, beyond the 25 ms
            // half-window and less than 3 ms of resampling support. The last
            // 60 ms of the file are excluded to avoid zero-padding transients.
            let interior: Vec<_> = track
                .frames
                .iter()
                .filter(|frame| (0.30..=0.44).contains(&frame.time_s))
                .collect();
            assert!(!interior.is_empty());
            assert!(
                interior.iter().all(|frame| frame.formants_hz.is_empty()),
                "silent interval at {sr} samples/s produced candidates"
            );
        }
    }

    #[test]
    fn dc_input_does_not_turn_resampling_roundoff_into_formants() {
        for sr in [16000, 44100, 48000, 96000, 192000] {
            let track = track_formants(&vec![0.1; sr as usize / 5], sr, &Default::default());
            assert!(!track.frames.is_empty());
            assert!(
                track
                    .frames
                    .iter()
                    .all(|frame| frame.formants_hz.is_empty()),
                "constant signal at {sr} samples/s produced formants"
            );
        }
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

    fn polynomial_from_resonances(
        frequencies: &[f64],
        bandwidth: f64,
    ) -> (Vec<f64>, Vec<Complex64>) {
        let radius = (-std::f64::consts::PI * bandwidth / 11000.0).exp();
        let mut coefficients = vec![1.0];
        let mut roots = Vec::new();
        for &frequency in frequencies {
            let root =
                Complex64::from_polar(radius, 2.0 * std::f64::consts::PI * frequency / 11000.0);
            roots.extend([root, root.conj()]);
            let quadratic = [1.0, -2.0 * root.re, radius * radius];
            let mut product = vec![0.0; coefficients.len() + 2];
            for (i, a) in coefficients.iter().enumerate() {
                for (j, b) in quadratic.iter().enumerate() {
                    product[i + j] += a * b;
                }
            }
            coefficients = product;
        }
        (coefficients[1..].to_vec(), roots)
    }

    #[test]
    fn checked_roots_recover_separated_and_close_resonance_controls() {
        for (frequencies, bandwidth) in [
            ([500.0, 1500.0, 2500.0, 3500.0, 4500.0], 100.0),
            ([500.0, 510.0, 2500.0, 2510.0, 4500.0], 20.0),
        ] {
            let (coefficients, expected) = polynomial_from_resonances(&frequencies, bandwidth);
            let result = checked_poly_roots(&coefficients).unwrap();
            assert_eq!(result.roots.len(), 10);
            assert_eq!(result.roots.iter().filter(|z| z.im > 0.0).count(), 5);
            for root in expected {
                let distance = result
                    .roots
                    .iter()
                    .map(|got| (got - root).norm())
                    .fold(f64::INFINITY, f64::min);
                assert!(distance < 1e-10, "root distance {distance}");
            }
            assert_eq!(result.diagnostics.unpaired_nonreal_roots, 0);
            assert!(result.diagnostics.iterations < ROOT_ITERATIONS);
        }
    }

    #[test]
    fn unresolved_low_frequency_cluster_is_rejected() {
        let (coefficients, _) = polynomial_from_resonances(&[50.0, 70.0, 90.0, 110.0, 130.0], 10.0);
        let failure = checked_poly_roots(&coefficients).unwrap_err();
        assert_eq!(failure.reason, RootFailureReason::DidNotConverge);
        assert_eq!(failure.diagnostics.iterations, ROOT_ITERATIONS);
        assert!(failure.diagnostics.max_relative_step.unwrap() > ROOT_STEP_TOLERANCE);
        // Tiny individual residuals cannot rescue an unresolved complete set.
        assert!(failure.diagnostics.max_relative_residual.unwrap() < 1e-10);
        assert!(poly_roots(&coefficients).is_empty());
    }

    #[test]
    fn checked_roots_reject_nonfinite_coefficients() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let failure = checked_poly_roots(&[value, 1.0]).unwrap_err();
            assert_eq!(failure.reason, RootFailureReason::NonFiniteCoefficients);
            assert_eq!(failure.diagnostics.iterations, 0);
            assert!(poly_roots(&[value, 1.0]).is_empty());
        }
    }

    #[test]
    fn finite_coefficients_that_overflow_iteration_are_rejected() {
        let failure = checked_poly_roots(&[f64::MAX, f64::MAX]).unwrap_err();
        assert_eq!(failure.reason, RootFailureReason::NonFiniteIteration);
        assert!(poly_roots(&[f64::MAX, f64::MAX]).is_empty());
    }

    #[test]
    fn checked_roots_handle_constant_and_linear_polynomials() {
        assert!(checked_poly_roots(&[]).unwrap().roots.is_empty());
        assert_eq!(
            checked_poly_roots(&[0.0]).unwrap().roots,
            [Complex64::new(0.0, 0.0)]
        );
        assert_eq!(
            checked_poly_roots(&[-2.0]).unwrap().roots,
            [Complex64::new(2.0, 0.0)]
        );
    }

    #[test]
    fn zero_residual_duplicate_roots_do_not_represent_the_polynomial() {
        let mut diagnostics = RootDiagnostics::default();
        inspect_roots(
            &[0.0, -1.0],
            &[Complex64::new(1.0, 0.0); 2],
            &mut diagnostics,
        );
        assert_eq!(diagnostics.max_relative_residual, Some(0.0));
        assert_eq!(diagnostics.max_conjugate_mismatch, Some(0.0));
        assert_eq!(
            root_validation_failure(2, &diagnostics),
            Some(RootFailureReason::InconsistentPolynomial)
        );
    }

    #[test]
    fn conjugate_matching_cannot_reuse_a_partner() {
        let i = Complex64::new(0.0, 1.0);
        let mut diagnostics = RootDiagnostics::default();
        inspect_roots(&[0.0, 2.0, 0.0, 1.0], &[i, i, i, -i], &mut diagnostics);
        assert_eq!(diagnostics.max_relative_residual, Some(0.0));
        assert_eq!(diagnostics.unpaired_nonreal_roots, 2);
        assert_eq!(
            root_validation_failure(4, &diagnostics),
            Some(RootFailureReason::UnpairedConjugates)
        );
    }

    #[test]
    fn residual_check_rejects_inexact_roots() {
        let mut diagnostics = RootDiagnostics::default();
        inspect_roots(
            &[0.0, -1.0],
            &[Complex64::new(1.01, 0.0), Complex64::new(-1.01, 0.0)],
            &mut diagnostics,
        );
        assert_eq!(
            root_validation_failure(2, &diagnostics),
            Some(RootFailureReason::ResidualTooLarge)
        );
        assert_eq!(
            root_validation_failure(2, &RootDiagnostics::default()),
            Some(RootFailureReason::NonFiniteValidation)
        );
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

    #[test]
    fn constant_nonzero_signal_yields_empty_interior_frames() {
        // Work at the analysis rate to isolate frame centering from resampling.
        // Pre-emphasis retains the first sample, so exclude its startup frame.
        for level in [-0.375, 0.1, 0.5] {
            let t = track_formants(&vec![level; 11000], 11000, &Default::default());
            assert!(t.frames.len() > 1);
            assert!(
                t.frames.iter().skip(1).all(|f| f.formants_hz.is_empty()),
                "constant level {level} produced formants"
            );
        }
    }

    #[test]
    fn constant_nonzero_signal_without_preemphasis_yields_empty_frames() {
        let params = FormantParams {
            pre_emphasis_hz: 0.0,
            ..Default::default()
        };
        let t = track_formants(&vec![0.1; 11000], 11000, &params);
        assert!(!t.frames.is_empty());
        assert!(t.frames.iter().all(|f| f.formants_hz.is_empty()));
    }

    #[test]
    fn formants_are_invariant_to_constant_offset_after_startup() {
        let truth = [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)];
        let signal = synth_vowel(120.0, &truth, 11000.0, 0.5);
        let shifted: Vec<f64> = signal.iter().map(|v| v + 0.375).collect();
        let original = track_formants(&signal, 11000, &Default::default());
        let offset = track_formants(&shifted, 11000, &Default::default());
        assert_eq!(original.frames.len(), offset.frames.len());
        for (a, b) in original.frames.iter().zip(&offset.frames).skip(1) {
            assert_eq!(a.time_s, b.time_s);
            assert_eq!(a.formants_hz.len(), b.formants_hz.len());
            assert!(!a.formants_hz.is_empty());
            for (x, y) in a.formants_hz.iter().zip(&b.formants_hz) {
                assert!((x - y).abs() < 1e-5, "frequency {x} vs {y}");
            }
            for (x, y) in a.bandwidths_hz.iter().zip(&b.bandwidths_hz) {
                assert!((x - y).abs() < 1e-5, "bandwidth {x} vs {y}");
            }
        }
    }

    #[test]
    fn very_quiet_vowel_retains_formant_candidates() {
        let truth = [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)];
        let params = FormantParams {
            max_bandwidth_hz: f64::INFINITY,
            ..Default::default()
        };
        for sr in [44100, 44101] {
            let signal = synth_vowel(120.0, &truth, sr as f64, 0.5);
            let quiet: Vec<f64> = signal.iter().map(|value| value * 1e-12).collect();
            let original = track_formants(&signal, sr, &params);
            let attenuated = track_formants(&quiet, sr, &params);
            assert_eq!(original.frames.len(), attenuated.frames.len());
            let mut compared = 0;
            for (a, b) in original.frames.iter().zip(&attenuated.frames) {
                if !(0.1..=0.4).contains(&a.time_s) {
                    continue;
                }
                compared += 1;
                assert!(a.formants_hz.len() >= 3);
                assert_eq!(a.formants_hz.len(), b.formants_hz.len());
                for (x, y) in a.formants_hz.iter().zip(&b.formants_hz) {
                    assert!((x - y).abs() < 1e-6, "frequency {x} vs {y} at {sr}");
                }
                for (x, y) in a.bandwidths_hz.iter().zip(&b.bandwidths_hz) {
                    assert!((x - y).abs() < 1e-6, "bandwidth {x} vs {y} at {sr}");
                }
            }
            assert!(compared >= 25);
        }
    }

    #[test]
    fn reciprocal_pole_radii_have_equal_positive_bandwidths() {
        let sample_rate = 11000.0;
        let frequency = 1700.0;
        let bandwidth = 250.0;
        let angle = 2.0 * std::f64::consts::PI * frequency / sample_rate;
        let radius = (-std::f64::consts::PI * bandwidth / sample_rate).exp();
        for r in [radius, 1.0 / radius] {
            let (f, b) = formant_from_root(Complex64::from_polar(r, angle), sample_rate);
            assert!((f - frequency).abs() < 1e-9, "frequency {f}");
            assert!((b - bandwidth).abs() < 1e-9, "bandwidth {b}");
            assert!(b > 0.0);
        }
    }

    #[test]
    fn unit_circle_pole_has_zero_bandwidth() {
        let (frequency, bandwidth) = formant_from_root(Complex64::new(0.0, 1.0), 11000.0);
        assert!((frequency - 2750.0).abs() < 1e-9);
        assert_eq!(bandwidth, 0.0);
    }

    #[test]
    fn praat_grid_matches_praat_frame_placement() {
        // Frame count and first time from Praat 6.1.38 (Parselmouth 0.4.7),
        // To Formant (burg) with a 6.25 ms step, 25 ms window, 5500 Hz ceiling.
        let params = FormantParams {
            time_step_s: 0.00625,
            praat_grid: true,
            ..Default::default()
        };
        for (n, sr, frames, first) in [
            (192000, 48000, 632, 0.028125),
            (22050, 44100, 72, 0.028125),
            (59259, 48000, 190, 0.02665625),
            (48000, 16000, 473, 0.025),
        ] {
            let signal: Vec<f64> = (0..n).map(|i| ((i * 7919) % 1013) as f64 / 1013.0 - 0.5).collect();
            let track = track_formants(&signal, sr, &params);
            assert_eq!(track.frames.len(), frames, "{n} samples at {sr} Hz");
            for (i, frame) in track.frames.iter().enumerate() {
                assert!((frame.time_s - (first + i as f64 * 0.00625)).abs() < 1e-9);
            }
        }
    }

    #[test]
    fn default_grid_is_unchanged() {
        // Hop rounded to 69 samples at 11 kHz; first centre half a 50 ms window in.
        let params = FormantParams {
            time_step_s: 0.00625,
            ..Default::default()
        };
        let signal: Vec<f64> = (0..192000).map(|i| ((i * 7919) % 1013) as f64 / 1013.0 - 0.5).collect();
        let track = track_formants(&signal, 48000, &params);
        assert_eq!(track.frames.len(), 630);
        assert!((track.frames[0].time_s - 0.025).abs() < 1e-12);
        assert!((track.frames[1].time_s - track.frames[0].time_s - 69.0 / 11000.0).abs() < 1e-12);
    }
}
