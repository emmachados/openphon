//! Emit a voice-quality report as CSV for the validation harness:
//! `metric,value` for mean HNR (dB), jitter (local), shimmer (local),
//! and period count. Usage: voice_report <file.wav>
use openphon_core::{voice_quality, wav};

fn main() {
    let path = std::env::args().nth(1).expect("usage: voice_report <file.wav>");
    let w = wav::WavData::from_file(&path).expect("read wav");
    let r = voice_quality::analyze(&w.samples, w.sample_rate, &Default::default());
    println!("metric,value");
    println!("hnr_db,{}", r.mean_hnr_db.map_or(String::from("nan"), |v| format!("{v:.4}")));
    println!("jitter_local,{}", r.jitter_local.map_or(String::from("nan"), |v| format!("{v:.6}")));
    println!("shimmer_local,{}", r.shimmer_local.map_or(String::from("nan"), |v| format!("{v:.6}")));
    println!("median_f0_hz,{}", r.median_f0_hz.map_or(String::from("nan"), |v| format!("{v:.4}")));
    println!("mean_f0_hz,{}", r.mean_f0_hz.map_or(String::from("nan"), |v| format!("{v:.4}")));
    println!("sd_f0_hz,{}", r.sd_f0_hz.map_or(String::from("nan"), |v| format!("{v:.4}")));
    println!("n_periods,{}", r.n_periods);
}
