//! Prints `metric,value` spectral moments (CoG, SD, skewness, excess
//! kurtosis) for a WAV file. Driven by validation/spectral_check.py.

use openphon_core::{spectral, wav};

fn main() {
    let path = std::env::args().nth(1).expect("usage: spectral_moments <wav>");
    let w = wav::WavData::from_file(&path).expect("read wav");
    let m = spectral::moments(&w.samples, w.sample_rate);
    println!("metric,value");
    match m {
        Some(m) => {
            println!("cog_hz,{:.6}", m.cog_hz);
            println!("sd_hz,{:.6}", m.sd_hz);
            println!("skewness,{:.6}", m.skewness);
            println!("kurtosis,{:.6}", m.kurtosis);
        }
        None => {
            for k in ["cog_hz", "sd_hz", "skewness", "kurtosis"] {
                println!("{k},nan");
            }
        }
    }
}
