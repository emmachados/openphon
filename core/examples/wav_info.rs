//! Debug utility: print parse results and analysis summaries for a WAV file.
//!
//! Usage: cargo run --release --example wav_info -- <file.wav>

use openphon_core::{intensity, pitch, spectrogram, wav};

fn main() {
    let path = std::env::args().nth(1).expect("usage: wav_info <file.wav>");
    let w = wav::WavData::from_file(&path).unwrap();
    println!(
        "{} Hz, {} ch, {} samples, {:.3} s",
        w.sample_rate,
        w.channels,
        w.samples.len(),
        w.duration_s()
    );
    let peak = w.samples.iter().fold(0.0f64, |m, s| m.max(s.abs()));
    println!("peak |sample| = {peak:.4}");

    let f0 = pitch::track_f0(&w.samples, w.sample_rate, &Default::default());
    let voiced: Vec<f64> = f0.f0_hz.iter().copied().filter(|&f| f > 0.0).collect();
    println!(
        "F0: {} frames, {} voiced ({:.0}%)",
        f0.f0_hz.len(),
        voiced.len(),
        100.0 * voiced.len() as f64 / f0.f0_hz.len().max(1) as f64
    );
    if !voiced.is_empty() {
        let mut v = voiced.clone();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("F0 median = {:.1} Hz", v[v.len() / 2]);
    }

    let int = intensity::compute(&w.samples, w.sample_rate, &Default::default());
    let max_db = int.db.iter().fold(f64::NEG_INFINITY, |m, &d| m.max(d));
    println!("intensity: {} frames, max {max_db:.1} dB", int.db.len());

    let sg = spectrogram::compute(&w.samples, w.sample_rate, &Default::default());
    println!(
        "spectrogram: {} frames x {} bins, {:.1} Hz/bin",
        sg.n_frames, sg.n_bins, sg.freq_step_hz
    );
}
