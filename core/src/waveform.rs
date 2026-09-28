//! Display-resolution waveform envelope.

/// Min/max per bucket over the time range [t0_s, t1_s], for drawing a
/// waveform at `n_buckets` horizontal pixels. Buckets that fall outside
/// the signal (or contain no samples) yield (0.0, 0.0).
pub fn min_max_envelope(
    samples: &[f64],
    sample_rate: u32,
    t0_s: f64,
    t1_s: f64,
    n_buckets: usize,
) -> (Vec<f32>, Vec<f32>) {
    let sr = sample_rate as f64;
    let mut mins = vec![0.0f32; n_buckets];
    let mut maxs = vec![0.0f32; n_buckets];
    if n_buckets == 0 || t1_s <= t0_s || samples.is_empty() {
        return (mins, maxs);
    }
    let bucket_dur = (t1_s - t0_s) / n_buckets as f64;
    for b in 0..n_buckets {
        let start = ((t0_s + b as f64 * bucket_dur) * sr).ceil().max(0.0) as usize;
        let end = (((t0_s + (b + 1) as f64 * bucket_dur) * sr).ceil() as usize).min(samples.len());
        if start >= end {
            continue;
        }
        let mut lo = f64::INFINITY;
        let mut hi = f64::NEG_INFINITY;
        for &v in &samples[start..end] {
            lo = lo.min(v);
            hi = hi.max(v);
        }
        mins[b] = lo as f32;
        maxs[b] = hi as f32;
    }
    (mins, maxs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ramp_buckets_are_exact() {
        // samples[i] = i / 100: 100 samples over 1 s at sr 100.
        let s: Vec<f64> = (0..100).map(|i| i as f64 / 100.0).collect();
        let (mins, maxs) = min_max_envelope(&s, 100, 0.0, 1.0, 4);
        // Bucket 0 covers samples 0..25 -> min 0.00, max 0.24.
        assert!((mins[0] - 0.00).abs() < 1e-6);
        assert!((maxs[0] - 0.24).abs() < 1e-6);
        assert!((mins[3] - 0.75).abs() < 1e-6);
        assert!((maxs[3] - 0.99).abs() < 1e-6);
    }

    #[test]
    fn sine_envelope_spans_amplitude() {
        let s: Vec<f64> = (0..4410)
            .map(|i| 0.8 * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / 44100.0).sin())
            .collect();
        let (mins, maxs) = min_max_envelope(&s, 44100, 0.0, 0.1, 10);
        for b in 0..10 {
            assert!(mins[b] < -0.79, "bucket {b} min {}", mins[b]);
            assert!(maxs[b] > 0.79, "bucket {b} max {}", maxs[b]);
        }
    }

    #[test]
    fn out_of_range_buckets_are_zero() {
        let s = vec![0.5f64; 100];
        // Range extends beyond the 1 s signal (sr 100).
        let (mins, maxs) = min_max_envelope(&s, 100, 0.5, 2.5, 4);
        assert!((maxs[0] - 0.5).abs() < 1e-6); // 0.5..1.0 s inside
        assert_eq!(maxs[2], 0.0); // 1.5..2.0 s outside
        assert_eq!(mins[3], 0.0);
    }

    #[test]
    fn negative_start_is_clamped() {
        let s = vec![0.25f64; 100];
        let (mins, maxs) = min_max_envelope(&s, 100, -1.0, 1.0, 2);
        assert_eq!(maxs[0], 0.0); // -1.0..0.0 s: no samples
        assert!((mins[1] - 0.25).abs() < 1e-6);
    }
}
