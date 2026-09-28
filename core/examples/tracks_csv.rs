//! Emit openphon-core analysis tracks as CSV for the validation harness.
//!
//! Usage: tracks_csv <file.wav> <out_dir> [raw]
//! Writes <stem>.pitch.csv (time_s,f0_hz; 0 = unvoiced) and
//! <stem>.formant.csv (time_s,f1_hz..f5_hz; 0 = missing), matching
//! the column layout of validation/generate_references.py.
//!
//! `raw` disables the bandwidth-based candidate filter so the output is
//! label-compatible with Praat's To Formant (burg), which reports every
//! pole in band. The app default keeps the filter; the validation gate
//! must compare like-for-like.
//!
//! `OPENPHON_UNVOICED_COST` overrides the pitch tracker's unvoiced
//! candidate cost (CMNDF units). It exists so `validation/sweep.py` can
//! sweep the tracker's one consequential free parameter without seven
//! edit-and-rebuild cycles; unset, the shipped default applies.

use openphon_core::{formant, pitch, wav};
use std::fmt::Write as _;
use std::path::Path;

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: tracks_csv <file.wav> <out_dir>");
    // `--params` reports the operating point this binary will actually use,
    // so an artefact can record which one produced it. The validation
    // artefacts used to record `"unvoiced_cost": null` whenever the sweep
    // did not override it, which left nothing in the chain stating the
    // value the published figures were computed at.
    if path == "--params" {
        let mut p = pitch::F0Params::default();
        let mut overridden = false;
        if let Ok(v) = std::env::var("OPENPHON_UNVOICED_COST") {
            p.unvoiced_cost = v
                .parse()
                .unwrap_or_else(|_| panic!("OPENPHON_UNVOICED_COST is not a number: {v:?}"));
            overridden = true;
        }
        let f = formant::FormantParams::default();
        println!(
            "{{\"unvoiced_cost\":{},\"unvoiced_cost_overridden\":{},\
             \"f0_min_hz\":{},\"f0_max_hz\":{},\"time_step_s\":{},\
             \"threshold\":{},\
             \"formant_max_bandwidth_hz\":{},\"crate_version\":\"{}\"}}",
            p.unvoiced_cost,
            overridden,
            p.f0_min_hz,
            p.f0_max_hz,
            p.time_step_s,
            p.threshold,
            f.max_bandwidth_hz,
            env!("CARGO_PKG_VERSION")
        );
        return;
    }
    let out_dir = args.next().expect("usage: tracks_csv <file.wav> <out_dir>");
    let stem = Path::new(&path)
        .file_stem()
        .expect("input must be a file")
        .to_string_lossy()
        .to_string();
    let w = wav::WavData::from_file(&path).unwrap();

    let mut pparams = pitch::F0Params::default();
    if let Ok(v) = std::env::var("OPENPHON_UNVOICED_COST") {
        pparams.unvoiced_cost = v
            .parse()
            .unwrap_or_else(|_| panic!("OPENPHON_UNVOICED_COST is not a number: {v:?}"));
    }
    let t = pitch::track_f0(&w.samples, w.sample_rate, &pparams);
    let mut csv = String::from("time_s,f0_hz\n");
    for (time, f0) in t.times_s.iter().zip(&t.f0_hz) {
        writeln!(csv, "{time:.6},{f0:.3}").unwrap();
    }
    std::fs::write(format!("{out_dir}/{stem}.pitch.csv"), csv).unwrap();

    let raw = args.next().as_deref() == Some("raw");
    let fparams = formant::FormantParams {
        max_bandwidth_hz: if raw { f64::INFINITY } else { 400.0 },
        ..Default::default()
    };
    let ft = formant::track_formants(&w.samples, w.sample_rate, &fparams);
    // Five columns, not three. Scoring a formant track against known
    // synthesis poles needs every pole the tracker found: an LPC fit asked
    // for five formants in band places a pole where the signal has none,
    // and that pole takes a label from the ones below it, so a labelled F3
    // can be a spurious pole while the real F3 sits in the F4 column.
    let n_cols = 5;
    let mut csv = String::from("time_s");
    for i in 1..=n_cols {
        write!(csv, ",f{i}_hz").unwrap();
    }
    csv.push('\n');
    for fr in &ft.frames {
        let get = |i: usize| fr.formants_hz.get(i).copied().unwrap_or(0.0);
        write!(csv, "{:.6}", fr.time_s).unwrap();
        for i in 0..n_cols {
            write!(csv, ",{:.3}", get(i)).unwrap();
        }
        csv.push('\n');
    }
    std::fs::write(format!("{out_dir}/{stem}.formant.csv"), csv).unwrap();
}
