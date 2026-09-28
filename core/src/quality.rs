//! Recording-quality indicators: clipping and a signal-to-noise estimate.
//!
//! These are field-work aids, not measurements: the SNR figure is a
//! percentile ratio of short-term levels (loud frames vs. quiet frames),
//! which approximates speech-over-floor only when the recording contains
//! both speech and pauses. It is reported as an estimate and never enters
//! any analysis.

/// One 16-bit step below full scale: samples at or beyond this magnitude
/// are counted as clipped (converters and DSP chains rarely produce the
/// exact rail, so the last step is the practical clip level).
const CLIP_LEVEL: f64 = 32766.0 / 32768.0;

/// Frame length for the level distribution (10 ms hop, no overlap).
const FRAME_S: f64 = 0.01;

/// Display floor for the peak level of an all-zero file.
const PEAK_FLOOR_DBFS: f64 = -120.0;

/// Cap for the SNR estimate: beyond this the "noise" percentile is
/// digital silence and the ratio is meaningless precision.
const SNR_CAP_DB: f64 = 96.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QualityReport {
    /// Highest sample magnitude, in dB re full scale (<= 0).
    pub peak_dbfs: f64,
    /// Percentage of samples at or above the clip level.
    pub clipped_pct: f64,
    /// Estimated signal-to-noise ratio in dB: the ratio of the 90th to
    /// the 10th percentile of 10 ms RMS levels. `None` when the file is
    /// too short to frame or is entirely silent.
    pub est_snr_db: Option<f64>,
}

pub fn assess(samples: &[f64], sample_rate: u32) -> QualityReport {
    let peak = samples.iter().fold(0.0f64, |m, &s| m.max(s.abs()));
    let peak_dbfs = if peak > 0.0 {
        (20.0 * peak.log10()).max(PEAK_FLOOR_DBFS)
    } else {
        PEAK_FLOOR_DBFS
    };
    let clipped = samples.iter().filter(|s| s.abs() >= CLIP_LEVEL).count();
    let clipped_pct = if samples.is_empty() {
        0.0
    } else {
        100.0 * clipped as f64 / samples.len() as f64
    };

    QualityReport {
        peak_dbfs,
        clipped_pct,
        est_snr_db: estimate_snr(samples, sample_rate),
    }
}

fn estimate_snr(samples: &[f64], sample_rate: u32) -> Option<f64> {
    let frame = ((sample_rate as f64 * FRAME_S) as usize).max(1);
    let mut rms: Vec<f64> = samples
        .chunks_exact(frame)
        .map(|c| (c.iter().map(|s| s * s).sum::<f64>() / c.len() as f64).sqrt())
        .collect();
    // Need enough frames for the percentiles to mean anything.
    if rms.len() < 10 {
        return None;
    }
    rms.sort_by(|a, b| a.total_cmp(b));
    let p10 = rms[rms.len() / 10];
    let p90 = rms[rms.len() * 9 / 10];
    if p90 <= 0.0 {
        return None; // all silence
    }
    if p10 <= 0.0 {
        return Some(SNR_CAP_DB); // quietest frames are digital silence
    }
    Some((20.0 * (p90 / p10).log10()).min(SNR_CAP_DB))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: u32 = 16000;

    fn sine(freq: f64, amp: f64, dur_s: f64) -> Vec<f64> {
        (0..(SR as f64 * dur_s) as usize)
            .map(|i| amp * (2.0 * std::f64::consts::PI * freq * i as f64 / SR as f64).sin())
            .collect()
    }

    /// Deterministic uniform noise in [-amp, amp] (LCG; no rand dep).
    fn noise(amp: f64, n: usize) -> Vec<f64> {
        let mut state = 0x2545F491_4F6CDD1Du64;
        (0..n)
            .map(|_| {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                amp * ((state >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0)
            })
            .collect()
    }

    #[test]
    fn clean_sine_reports_no_clipping_and_true_peak() {
        let r = assess(&sine(220.0, 0.5, 1.0), SR);
        assert_eq!(r.clipped_pct, 0.0);
        assert!((r.peak_dbfs - 20.0 * 0.5f64.log10()).abs() < 0.1, "{}", r.peak_dbfs);
    }

    #[test]
    fn clamped_sine_reports_clipping() {
        let s: Vec<f64> = sine(220.0, 1.4, 1.0)
            .into_iter()
            .map(|v| v.clamp(-CLIP_LEVEL, CLIP_LEVEL))
            .collect();
        let r = assess(&s, SR);
        // A sine driven 1.4x past full scale spends a large fraction of
        // each cycle on the rails.
        assert!(r.clipped_pct > 20.0, "{}", r.clipped_pct);
        assert!(r.peak_dbfs > -0.01);
    }

    #[test]
    fn snr_estimate_tracks_known_speech_over_floor_ratio() {
        // 2 s: continuous floor noise, with a 0.8 s "speech" burst in the
        // middle. True level ratio: 20*log10(sine_rms / noise_rms).
        let n = 2 * SR as usize;
        let mut s = noise(0.01, n);
        let burst = sine(180.0, 0.5, 0.8);
        let at = SR as usize / 2;
        for (i, v) in burst.iter().enumerate() {
            s[at + i] += v;
        }
        let noise_rms = 0.01 / 3.0f64.sqrt();
        let true_db = 20.0 * ((0.5 / 2.0f64.sqrt()) / noise_rms).log10();
        let got = assess(&s, SR).est_snr_db.unwrap();
        assert!((got - true_db).abs() < 6.0, "got {got}, true {true_db}");
    }

    #[test]
    fn silence_yields_floor_peak_and_no_snr() {
        let r = assess(&vec![0.0; SR as usize], SR);
        assert_eq!(r.peak_dbfs, PEAK_FLOOR_DBFS);
        assert_eq!(r.clipped_pct, 0.0);
        assert_eq!(r.est_snr_db, None);
    }

    #[test]
    fn short_file_has_no_snr_estimate() {
        let r = assess(&sine(220.0, 0.5, 0.05), SR);
        assert_eq!(r.est_snr_db, None);
    }

    #[test]
    fn speech_with_silent_pauses_caps_the_estimate() {
        let mut s = vec![0.0; 2 * SR as usize];
        let burst = sine(180.0, 0.5, 0.8);
        for (i, v) in burst.iter().enumerate() {
            s[SR as usize / 2 + i] = *v;
        }
        assert_eq!(assess(&s, SR).est_snr_db, Some(SNR_CAP_DB));
    }
}
