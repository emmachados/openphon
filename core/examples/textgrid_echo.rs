//! Validation helper: parse a TextGrid and rewrite it.
//!
//! Usage: textgrid_echo <in.TextGrid> <out.TextGrid>
//! Exits non-zero on parse failure; used by validation/textgrid_roundtrip.py
//! to prove that Praat-authored files survive a parse+write cycle and that
//! Praat can read what we write.

use openphon_core::textgrid;

fn main() {
    let mut args = std::env::args().skip(1);
    let input = args.next().expect("usage: textgrid_echo <in> <out>");
    let output = args.next().expect("usage: textgrid_echo <in> <out>");
    let grid = textgrid::parse_file(&input).unwrap();
    textgrid::write_file(&output, &grid).unwrap();
    println!(
        "{} tiers, {:.6}..{:.6} s",
        grid.tiers.len(),
        grid.xmin,
        grid.xmax
    );
}
