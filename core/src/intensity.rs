//! RMS intensity contour in dB SPL.
//!
//! Samples are treated as sound pressure in Pascals with the standard
//! reference 2e-5 Pa (Praat's convention), so a full-scale sine reads
//! ~91 dB. Window length is tied to the lowest pitch to be smoothed over,
//! as in Praat's published description (effective duration 3.2 / min_pitch).

pub const DB_FLOOR: f64 = -300.0;

#[derive(Debug, Clone, Copy)]
pub struct IntensityParams {
    /// Lowest F0 whose periodicity ripple the window must smooth out.
    pub min_pitch_hz: f64,
    /// Hop between frames in seconds.
    pub time_step_s: f64,
}

impl Default for IntensityParams {
    fn default() -> Self {
        IntensityParams {
            min_pitch_hz: 100.0,
            time_step_s: 0.01,
        }
    }
}

#[derive(Debug)]
pub struct IntensityTrack {
    /// Frame centre times, seconds.
    pub times_s: Vec<f64>,
    /// dB SPL re 2e-5 Pa; `DB_FLOOR` for digital silence.
    pub db: Vec<f64>,
}

pub fn compute(samples: &[f64], sample_rate: u32, params: &IntensityParams) -> IntensityTrack {
    let sr = sample_rate as f64;
    let win_s = 3.2 / params.min_pitch_hz;
    let win_n = ((win_s * sr).round() as usize).max(2).min(samples.len());
    let hop = ((params.time_step_s * sr).round() as usize).max(1);

    // Hann weighting; normalized so a constant signal keeps its mean square.
    let weights: Vec<f64> = (0..win_n)
        .map(|i| {
            let x = i as f64 / (win_n - 1) as f64;
            0.5 - 0.5 * (2.0 * std::f64::consts::PI * x).cos()
        })
        .collect();
    let weight_sum: f64 = weights.iter().sum();

    let mut times_s = Vec::new();
    let mut db = Vec::new();
    let p_ref_sq = 2e-5f64 * 2e-5;
    let mut start = 0usize;
    while start + win_n <= samples.len() {
        let mean_sq: f64 = samples[start..start + win_n]
            .iter()
            .zip(&weights)
            .map(|(s, w)| s * s * w)
            .sum::<f64>()
            / weight_sum;
        times_s.push((start + win_n / 2) as f64 / sr);
        db.push(if mean_sq > 0.0 {
            (10.0 * (mean_sq / p_ref_sq).log10()).max(DB_FLOOR)
        } else {
            DB_FLOOR
        });
        start += hop;
    }
    IntensityTrack { times_s, db }
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
    fn full_scale_sine_reads_91_db() {
        // RMS of a unit sine = 1/sqrt(2) -> 20 log10(0.7071/2e-5) = 90.97 dB.
        let t = compute(&sine(220.0, 1.0, 44100.0, 0.5), 44100, &Default::default());
        let mid = t.db.len() / 2;
        assert!((t.db[mid] - 90.97).abs() < 0.2, "got {}", t.db[mid]);
    }

    #[test]
    fn amplitude_ratio_maps_to_db_difference() {
        let a = compute(&sine(220.0, 1.0, 44100.0, 0.5), 44100, &Default::default());
        let b = compute(&sine(220.0, 0.1, 44100.0, 0.5), 44100, &Default::default());
        let mid = a.db.len() / 2;
        assert!(((a.db[mid] - b.db[mid]) - 20.0).abs() < 0.1);
    }

    #[test]
    fn silence_is_floor() {
        let t = compute(&vec![0.0; 44100], 44100, &Default::default());
        assert!(t.db.iter().all(|&v| v == DB_FLOOR));
    }

    #[test]
    fn times_are_increasing_and_centered() {
        let t = compute(&vec![0.5; 44100], 44100, &Default::default());
        assert!(!t.times_s.is_empty());
        assert!(t.times_s.windows(2).all(|w| w[1] > w[0]));
        assert!((t.times_s[0] - 0.016).abs() < 0.001); // half of 32 ms window
    }
}
