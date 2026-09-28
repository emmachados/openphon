//! Property-based round-trip tests for TextGrid I/O: any structurally
//! valid grid must survive write -> parse exactly.

use openphon_core::textgrid::{
    Interval, IntervalTier, Point, PointTier, TextGrid, Tier, parse, write_bytes,
};
use proptest::prelude::*;

/// Labels: printable unicode plus quotes and embedded newlines, but no
/// carriage returns (line endings are normalized on read, so a literal
/// `\r` inside a label is out of contract).
fn label() -> impl Strategy<Value = String> {
    proptest::string::string_regex("[a-zA-Zñáéíóü0-9 \"'*!\\[\\]=<>:\\n-]{0,24}").unwrap()
}

/// Contiguous interval boundaries over [0, xmax], as Praat tiers are.
fn interval_tier(xmax: f64) -> impl Strategy<Value = Tier> {
    (proptest::collection::vec(0.001..1.0f64, 1..8), label()).prop_map(move |(fractions, name)| {
        let total: f64 = fractions.iter().sum();
        let mut intervals = Vec::new();
        let mut t = 0.0;
        for f in &fractions {
            let next = (t + f / total * xmax).min(xmax);
            intervals.push(Interval {
                xmin: t,
                xmax: next,
                text: name.clone(),
            });
            t = next;
        }
        if let Some(last) = intervals.last_mut() {
            last.xmax = xmax;
        }
        Tier::Interval(IntervalTier {
            name,
            xmin: 0.0,
            xmax,
            intervals,
        })
    })
}

fn point_tier(xmax: f64) -> impl Strategy<Value = Tier> {
    (
        proptest::collection::vec(0.0..1.0f64, 0..8),
        label(),
        label(),
    )
        .prop_map(move |(mut times, name, mark)| {
            times.sort_by(|a, b| a.partial_cmp(b).unwrap());
            times.dedup();
            Tier::Point(PointTier {
                name,
                xmin: 0.0,
                xmax,
                points: times
                    .into_iter()
                    .map(|f| Point {
                        time: f * xmax,
                        mark: mark.clone(),
                    })
                    .collect(),
            })
        })
}

fn text_grid() -> impl Strategy<Value = TextGrid> {
    (0.5..100.0f64)
        .prop_flat_map(|xmax| {
            (
                Just(xmax),
                proptest::collection::vec(prop_oneof![interval_tier(xmax), point_tier(xmax)], 0..5),
            )
        })
        .prop_map(|(xmax, tiers)| TextGrid {
            xmin: 0.0,
            xmax,
            tiers,
        })
}

proptest! {
    #[test]
    fn write_parse_round_trip(grid in text_grid()) {
        let parsed = parse(&write_bytes(&grid)).unwrap();
        prop_assert_eq!(parsed, grid);
    }

    #[test]
    fn write_is_idempotent_through_parse(grid in text_grid()) {
        let once = parse(&write_bytes(&grid)).unwrap();
        let twice = parse(&write_bytes(&once)).unwrap();
        prop_assert_eq!(once, twice);
    }
}
