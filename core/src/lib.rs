//! openphon_core: DSP algorithms and TextGrid I/O for the openphon app.
//!
//! Clean-room implementation. No Praat source code is used or ported; only
//! published algorithm descriptions and documented default parameters.

pub mod formant;
pub mod intensity;
pub mod pitch;
pub mod pitch_edits;
pub mod quality;
pub mod spectral;
pub mod voice_quality;
pub mod spectrogram;
pub mod textgrid;
pub mod wav;
pub mod waveform;

/// Crate version reported to the app over the FFI bridge.
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Toolchain proof function for the flutter_rust_bridge integration.
pub fn echo(input: String) -> String {
    input
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn echo_returns_input() {
        assert_eq!(echo("hola".to_string()), "hola");
    }

    #[test]
    fn version_matches_manifest() {
        assert_eq!(core_version(), "0.1.0");
    }

    /// End-to-end: synthesize a WAV in memory, parse it, run every analysis.
    #[test]
    fn wav_to_analyses_pipeline() {
        let sr = 44100u32;
        let samples: Vec<i16> = (0..sr as usize)
            .map(|i| {
                let phase = 2.0 * std::f64::consts::PI * 220.0 * i as f64 / sr as f64;
                (phase.sin() * 0.5 * 32767.0) as i16
            })
            .collect();
        let bytes = wav::test_support::wav_bytes(sr, 1, &samples);
        let w = wav::WavData::parse(&bytes).unwrap();
        assert!((w.duration_s() - 1.0).abs() < 0.001);

        let f0 = pitch::track_f0(&w.samples, w.sample_rate, &Default::default());
        let voiced: Vec<f64> = f0.f0_hz.iter().copied().filter(|&f| f > 0.0).collect();
        assert!(!voiced.is_empty());
        assert!((voiced[voiced.len() / 2] - 220.0).abs() < 0.5);

        let int = intensity::compute(&w.samples, w.sample_rate, &Default::default());
        // 0.5 amplitude sine -> 20 log10(0.3536/2e-5) ≈ 84.95 dB.
        assert!((int.db[int.db.len() / 2] - 84.95).abs() < 0.3);

        let sg = spectrogram::compute(&w.samples, w.sample_rate, &Default::default());
        assert!(sg.n_frames > 0 && sg.n_bins > 0);
    }
}
