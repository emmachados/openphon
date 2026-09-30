//! Manual F0 corrections, stored beside a recording as
//! `<stem>.pitchedits.csv`.
//!
//! The file records the corrected value of each edited frame, not the
//! operation that produced it, so applying it needs no candidate list:
//!
//! ```text
//! # openphon pitch edits 1; time_step_s=0.01; f0_min_hz=75; f0_max_hz=600
//! time_s,f0_hz
//! 0.125000,210.000
//! 0.135000,0.000
//! ```
//!
//! `f0_hz` 0 marks a frame set to unvoiced. Edits are tied to the pitch
//! settings they were made at, because the frame grid and the candidates
//! depend on them; [`PitchEdits::matches`] tells a caller whether they
//! apply.

use crate::pitch::{F0Params, F0Track};

const MAGIC: &str = "# openphon pitch edits 1";
const HEADER: &str = "time_s,f0_hz";

#[derive(Debug, Clone, PartialEq)]
pub struct PitchEdits {
    pub time_step_s: f64,
    pub f0_min_hz: f64,
    pub f0_max_hz: f64,
    pub times_s: Vec<f64>,
    pub f0_hz: Vec<f64>,
}

/// `recording.wav` -> `recording.pitchedits.csv`.
pub fn sidecar_path(wav_path: &str) -> String {
    let p = std::path::Path::new(wav_path);
    p.with_extension("pitchedits.csv").to_string_lossy().into_owned()
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-9 * a.abs().max(b.abs()).max(1.0)
}

impl PitchEdits {
    pub fn matches(&self, p: &F0Params) -> bool {
        close(self.time_step_s, p.time_step_s)
            && close(self.f0_min_hz, p.f0_min_hz)
            && close(self.f0_max_hz, p.f0_max_hz)
    }

    pub fn parse(text: &str) -> Result<PitchEdits, String> {
        let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
        let first = lines.next().ok_or("empty pitch edits file")?;
        let rest = first
            .strip_prefix(MAGIC)
            .ok_or("not an openphon pitch edits file (version 1)")?;
        let (mut step, mut lo, mut hi) = (None, None, None);
        for field in rest.split(';').map(str::trim).filter(|f| !f.is_empty()) {
            let (k, v) = field
                .split_once('=')
                .ok_or(format!("malformed setting {field:?}"))?;
            let v: f64 = v
                .trim()
                .parse()
                .map_err(|_| format!("setting {k} is not a number"))?;
            match k.trim() {
                "time_step_s" => step = Some(v),
                "f0_min_hz" => lo = Some(v),
                "f0_max_hz" => hi = Some(v),
                _ => {}
            }
        }
        if lines.next() != Some(HEADER) {
            return Err(format!("expected the column header {HEADER}"));
        }
        let mut times_s = Vec::new();
        let mut f0_hz = Vec::new();
        for (n, line) in lines.enumerate() {
            let (t, f) = line
                .split_once(',')
                .ok_or(format!("row {}: expected two columns", n + 1))?;
            let t: f64 = t
                .trim()
                .parse()
                .map_err(|_| format!("row {}: bad time", n + 1))?;
            let f: f64 = f
                .trim()
                .parse()
                .map_err(|_| format!("row {}: bad F0", n + 1))?;
            if !t.is_finite() || !f.is_finite() || f < 0.0 {
                return Err(format!("row {}: out of range", n + 1));
            }
            times_s.push(t);
            f0_hz.push(f);
        }
        Ok(PitchEdits {
            time_step_s: step.ok_or("missing time_step_s")?,
            f0_min_hz: lo.ok_or("missing f0_min_hz")?,
            f0_max_hz: hi.ok_or("missing f0_max_hz")?,
            times_s,
            f0_hz,
        })
    }

    pub fn parse_file(path: &str) -> Result<PitchEdits, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
        PitchEdits::parse(&text).map_err(|e| format!("{path}: {e}"))
    }

    pub fn to_text(&self) -> String {
        let mut s = format!(
            "{MAGIC}; time_step_s={}; f0_min_hz={}; f0_max_hz={}\n{HEADER}\n",
            self.time_step_s, self.f0_min_hz, self.f0_max_hz
        );
        for (t, f) in self.times_s.iter().zip(&self.f0_hz) {
            s.push_str(&format!("{t:.6},{f:.3}\n"));
        }
        s
    }

    /// Overwrites the edited frames of `track`; returns a per-frame mask of
    /// the frames an edit landed on. An edit lands on the frame whose centre
    /// is within half a frame step of its time; edits outside the track are
    /// ignored.
    pub fn apply(&self, track: &mut F0Track) -> Vec<bool> {
        let n = track.times_s.len();
        let mut edited = vec![false; n];
        if n == 0 {
            return edited;
        }
        let step = if n > 1 {
            track.times_s[1] - track.times_s[0]
        } else {
            self.time_step_s
        };
        for (t, f) in self.times_s.iter().zip(&self.f0_hz) {
            let i = ((t - track.times_s[0]) / step).round();
            if i < 0.0 || i >= n as f64 {
                continue;
            }
            let i = i as usize;
            if (track.times_s[i] - t).abs() <= 0.5 * step + 1e-9 {
                track.f0_hz[i] = *f;
                edited[i] = true;
            }
        }
        edited
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> PitchEdits {
        PitchEdits {
            time_step_s: 0.01,
            f0_min_hz: 75.0,
            f0_max_hz: 600.0,
            times_s: vec![0.125, 0.135],
            f0_hz: vec![210.0, 0.0],
        }
    }

    #[test]
    fn text_round_trips() {
        let e = sample();
        let back = PitchEdits::parse(&e.to_text()).unwrap();
        assert_eq!(back, e);
        assert!(e.to_text().starts_with(
            "# openphon pitch edits 1; time_step_s=0.01; f0_min_hz=75; f0_max_hz=600\n\
             time_s,f0_hz\n0.125000,210.000\n"
        ));
    }

    #[test]
    fn rejects_foreign_and_malformed_files() {
        assert!(PitchEdits::parse("time_s,f0_hz\n0.1,100\n").is_err());
        assert!(PitchEdits::parse("# openphon pitch edits 1; time_step_s=0.01\ntime_s,f0_hz\n").is_err());
        let bad_row = "# openphon pitch edits 1; time_step_s=0.01; f0_min_hz=75; f0_max_hz=600\n\
                       time_s,f0_hz\n0.1,-3\n";
        assert!(PitchEdits::parse(bad_row).is_err());
    }

    #[test]
    fn matches_only_its_own_settings() {
        let e = sample();
        assert!(e.matches(&F0Params::default()));
        assert!(!e.matches(&F0Params {
            f0_max_hz: 500.0,
            ..Default::default()
        }));
    }

    #[test]
    fn apply_lands_on_the_nearest_frame_within_half_a_step() {
        let mut track = F0Track {
            times_s: vec![0.1034, 0.1134, 0.1234, 0.1334, 0.1434],
            f0_hz: vec![100.0, 100.0, 100.0, 100.0, 100.0],
        };
        let e = PitchEdits {
            times_s: vec![0.1234, 0.1334, 0.5],
            f0_hz: vec![200.0, 0.0, 300.0],
            ..sample()
        };
        let mask = e.apply(&mut track);
        assert_eq!(track.f0_hz, vec![100.0, 100.0, 200.0, 0.0, 100.0]);
        assert_eq!(mask, vec![false, false, true, true, false]);
    }

    #[test]
    fn sidecar_sits_beside_the_wav() {
        assert_eq!(sidecar_path("/a/b/take 1.wav"), "/a/b/take 1.pitchedits.csv");
    }
}
