//! Praat TextGrid reading and writing.
//!
//! Clean-room implementation from the published file-format description
//! in the Praat manual. Both text forms are read (long `ooTextFile` with
//! decorated `key = value` lines, and the short form with bare values);
//! the writer emits the long form. Supported encodings on input: UTF-8
//! with or without BOM, UTF-16 LE and BE (Praat's default for non-ASCII
//! content). Output is UTF-8 with BOM, which desktop Praat reads.
//!
//! Both forms carry the same value sequence; only the decoration
//! differs. The parser abstracts that behind [`ValueSource`], with one
//! implementation per form.

#[derive(Debug, Clone, PartialEq)]
pub struct TextGrid {
    pub xmin: f64,
    pub xmax: f64,
    pub tiers: Vec<Tier>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Tier {
    Interval(IntervalTier),
    Point(PointTier),
}

impl Tier {
    pub fn name(&self) -> &str {
        match self {
            Tier::Interval(t) => &t.name,
            Tier::Point(t) => &t.name,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct IntervalTier {
    pub name: String,
    pub xmin: f64,
    pub xmax: f64,
    pub intervals: Vec<Interval>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Interval {
    pub xmin: f64,
    pub xmax: f64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PointTier {
    pub name: String,
    pub xmin: f64,
    pub xmax: f64,
    pub points: Vec<Point>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Point {
    pub time: f64,
    pub mark: String,
}

#[derive(Debug)]
pub struct ParseError {
    pub message: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TextGrid parse error: {}", self.message)
    }
}

impl std::error::Error for ParseError {}

fn err<T>(message: impl Into<String>) -> Result<T, ParseError> {
    Err(ParseError {
        message: message.into(),
    })
}

// ---------------------------------------------------------------------------
// Decoding

/// Decode raw file bytes according to the BOM (UTF-16 LE/BE, UTF-8).
pub fn decode(bytes: &[u8]) -> Result<String, ParseError> {
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        return String::from_utf16(&units).map_err(|_| ParseError {
            message: "invalid UTF-16LE".into(),
        });
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_be_bytes([c[0], c[1]]))
            .collect();
        return String::from_utf16(&units).map_err(|_| ParseError {
            message: "invalid UTF-16BE".into(),
        });
    }
    let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    match std::str::from_utf8(body) {
        Ok(s) => Ok(s.to_string()),
        // Legacy files may be in a single-byte encoding; map bytes 1:1
        // (ISO-8859-1) rather than failing outright.
        Err(_) => Ok(body.iter().map(|&b| b as char).collect()),
    }
}

// ---------------------------------------------------------------------------
// Value sources

/// The ordered scalar values of a TextGrid, independent of decoration.
trait ValueSource {
    fn next_number(&mut self) -> Result<f64, ParseError>;
    fn next_string(&mut self) -> Result<String, ParseError>;
    /// The `<exists>` / `<absent>` tiers flag.
    fn next_flag(&mut self) -> Result<bool, ParseError>;
}

/// Splits into lines once; both readers walk this.
struct Lines {
    lines: Vec<String>,
    pos: usize,
}

impl Lines {
    fn new(text: &str) -> Lines {
        Lines {
            lines: text
                .split('\n')
                .map(|l| l.trim_end_matches('\r').to_string())
                .collect(),
            pos: 0,
        }
    }

    fn next_raw(&mut self) -> Option<String> {
        if self.pos >= self.lines.len() {
            return None;
        }
        let l = self.lines[self.pos].clone();
        self.pos += 1;
        Some(l)
    }

    fn next_nonempty(&mut self) -> Option<String> {
        while let Some(l) = self.next_raw() {
            if !l.trim().is_empty() {
                return Some(l);
            }
        }
        None
    }
}

/// Reads a Praat quoted string whose opening quote is at the start of
/// `segment` (after trimming); consumes further raw lines when the string
/// contains newlines. `""` inside is an escaped quote.
fn read_quoted(segment: &str, lines: &mut Lines) -> Result<String, ParseError> {
    let seg = segment.trim_start();
    let mut chars: Vec<char> = seg.chars().collect();
    if chars.first() != Some(&'"') {
        return err(format!("expected quoted string, found: {seg}"));
    }
    chars.remove(0);
    let mut out = String::new();
    loop {
        let mut i = 0;
        while i < chars.len() {
            if chars[i] == '"' {
                if chars.get(i + 1) == Some(&'"') {
                    out.push('"');
                    i += 2;
                } else {
                    // Closing quote; trailing decoration on the line is ignored.
                    return Ok(out);
                }
            } else {
                out.push(chars[i]);
                i += 1;
            }
        }
        // String continues on the next line.
        match lines.next_raw() {
            Some(l) => {
                out.push('\n');
                chars = l.chars().collect();
            }
            None => return err("unterminated string"),
        }
    }
}

/// Long form: values live after `=` on decorated lines; index lines like
/// `item [1]:` and header lines like `intervals [1]:` carry no `=` and are
/// skipped.
struct LongSource {
    lines: Lines,
}

impl LongSource {
    fn value_line(&mut self) -> Result<String, ParseError> {
        while let Some(l) = self.lines.next_nonempty() {
            if let Some(eq) = l.find('=') {
                // Only trim the start: a trailing space may be string
                // content when a quoted label continues on the next line.
                return Ok(l[eq + 1..].trim_start().to_string());
            }
            // `item [n]:` / `intervals [n]:` / `points [n]:` decoration.
        }
        err("unexpected end of file")
    }
}

impl ValueSource for LongSource {
    fn next_number(&mut self) -> Result<f64, ParseError> {
        let v = self.value_line()?;
        v.split_whitespace()
            .next()
            .and_then(|t| t.parse().ok())
            .ok_or(ParseError {
                message: format!("expected number, found: {v}"),
            })
    }

    fn next_string(&mut self) -> Result<String, ParseError> {
        let v = self.value_line()?;
        read_quoted(&v, &mut self.lines)
    }

    fn next_flag(&mut self) -> Result<bool, ParseError> {
        while let Some(l) = self.lines.next_nonempty() {
            if l.contains("<exists>") {
                return Ok(true);
            }
            if l.contains("<absent>") {
                return Ok(false);
            }
        }
        err("missing tiers flag")
    }
}

/// Short form: each non-empty line is one bare value.
struct ShortSource {
    lines: Lines,
}

impl ValueSource for ShortSource {
    fn next_number(&mut self) -> Result<f64, ParseError> {
        let l = self.lines.next_nonempty().ok_or(ParseError {
            message: "unexpected end of file".into(),
        })?;
        l.trim().parse().map_err(|_| ParseError {
            message: format!("expected number, found: {l}"),
        })
    }

    fn next_string(&mut self) -> Result<String, ParseError> {
        let l = self.lines.next_nonempty().ok_or(ParseError {
            message: "unexpected end of file".into(),
        })?;
        read_quoted(&l, &mut self.lines)
    }

    fn next_flag(&mut self) -> Result<bool, ParseError> {
        let l = self.lines.next_nonempty().ok_or(ParseError {
            message: "missing tiers flag".into(),
        })?;
        match l.trim() {
            "<exists>" => Ok(true),
            "<absent>" => Ok(false),
            other => err(format!("expected tiers flag, found: {other}")),
        }
    }
}

// ---------------------------------------------------------------------------
// Parsing

pub fn parse(bytes: &[u8]) -> Result<TextGrid, ParseError> {
    let text = decode(bytes)?;
    let mut header = Lines::new(&text);
    let file_type = header.next_nonempty().unwrap_or_default();
    let object_class = header.next_nonempty().unwrap_or_default();
    if !file_type.contains("ooTextFile") {
        return err("not an ooTextFile");
    }
    if !object_class.contains("TextGrid") {
        return err("not a TextGrid object");
    }
    // Long form if the next value-bearing line is decorated (`xmin = 0`).
    let probe = header.next_nonempty().ok_or(ParseError {
        message: "truncated file".into(),
    })?;
    header.pos -= 1; // put the probe line back
    let long_form = probe.contains('=');
    let mut source: Box<dyn ValueSource> = if long_form {
        Box::new(LongSource { lines: header })
    } else {
        Box::new(ShortSource { lines: header })
    };
    parse_values(source.as_mut())
}

fn parse_values(src: &mut dyn ValueSource) -> Result<TextGrid, ParseError> {
    let xmin = src.next_number()?;
    let xmax = src.next_number()?;
    let has_tiers = src.next_flag()?;
    let mut grid = TextGrid {
        xmin,
        xmax,
        tiers: Vec::new(),
    };
    if !has_tiers {
        return Ok(grid);
    }
    let n_tiers = src.next_number()? as usize;
    if n_tiers > 10_000 {
        return err("implausible tier count");
    }
    for _ in 0..n_tiers {
        let class = src.next_string()?;
        let name = src.next_string()?;
        let t_xmin = src.next_number()?;
        let t_xmax = src.next_number()?;
        let count = src.next_number()? as usize;
        if count > 10_000_000 {
            return err("implausible entry count");
        }
        match class.as_str() {
            "IntervalTier" => {
                let mut intervals = Vec::with_capacity(count);
                for _ in 0..count {
                    let i_xmin = src.next_number()?;
                    let i_xmax = src.next_number()?;
                    let text = src.next_string()?;
                    intervals.push(Interval {
                        xmin: i_xmin,
                        xmax: i_xmax,
                        text,
                    });
                }
                grid.tiers.push(Tier::Interval(IntervalTier {
                    name,
                    xmin: t_xmin,
                    xmax: t_xmax,
                    intervals,
                }));
            }
            "TextTier" => {
                let mut points = Vec::with_capacity(count);
                for _ in 0..count {
                    let time = src.next_number()?;
                    let mark = src.next_string()?;
                    points.push(Point { time, mark });
                }
                grid.tiers.push(Tier::Point(PointTier {
                    name,
                    xmin: t_xmin,
                    xmax: t_xmax,
                    points,
                }));
            }
            other => return err(format!("unknown tier class: {other}")),
        }
    }
    Ok(grid)
}

pub fn parse_file(path: &str) -> Result<TextGrid, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    parse(&bytes).map_err(|e| format!("{path}: {e}"))
}

// ---------------------------------------------------------------------------
// Writing

fn quote(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// Serialize as long-form ooTextFile text (without encoding).
pub fn write_long(grid: &TextGrid) -> String {
    let mut o = String::new();
    o.push_str("File type = \"ooTextFile\"\n");
    o.push_str("Object class = \"TextGrid\"\n\n");
    o.push_str(&format!("xmin = {}\n", grid.xmin));
    o.push_str(&format!("xmax = {}\n", grid.xmax));
    if grid.tiers.is_empty() {
        o.push_str("tiers? <absent>\n");
        return o;
    }
    o.push_str("tiers? <exists>\n");
    o.push_str(&format!("size = {}\n", grid.tiers.len()));
    o.push_str("item []:\n");
    for (ti, tier) in grid.tiers.iter().enumerate() {
        o.push_str(&format!("    item [{}]:\n", ti + 1));
        match tier {
            Tier::Interval(t) => {
                o.push_str("        class = \"IntervalTier\"\n");
                o.push_str(&format!("        name = {}\n", quote(&t.name)));
                o.push_str(&format!("        xmin = {}\n", t.xmin));
                o.push_str(&format!("        xmax = {}\n", t.xmax));
                o.push_str(&format!(
                    "        intervals: size = {}\n",
                    t.intervals.len()
                ));
                for (i, iv) in t.intervals.iter().enumerate() {
                    o.push_str(&format!("        intervals [{}]:\n", i + 1));
                    o.push_str(&format!("            xmin = {}\n", iv.xmin));
                    o.push_str(&format!("            xmax = {}\n", iv.xmax));
                    o.push_str(&format!("            text = {}\n", quote(&iv.text)));
                }
            }
            Tier::Point(t) => {
                o.push_str("        class = \"TextTier\"\n");
                o.push_str(&format!("        name = {}\n", quote(&t.name)));
                o.push_str(&format!("        xmin = {}\n", t.xmin));
                o.push_str(&format!("        xmax = {}\n", t.xmax));
                o.push_str(&format!("        points: size = {}\n", t.points.len()));
                for (i, pt) in t.points.iter().enumerate() {
                    o.push_str(&format!("        points [{}]:\n", i + 1));
                    o.push_str(&format!("            number = {}\n", pt.time));
                    o.push_str(&format!("            mark = {}\n", quote(&pt.mark)));
                }
            }
        }
    }
    o
}

/// Serialize to bytes: UTF-8 with BOM (read by desktop Praat).
pub fn write_bytes(grid: &TextGrid) -> Vec<u8> {
    let mut bytes = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(write_long(grid).as_bytes());
    bytes
}

pub fn write_file(path: &str, grid: &TextGrid) -> Result<(), String> {
    std::fs::write(path, write_bytes(grid)).map_err(|e| format!("{path}: {e}"))
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> TextGrid {
        TextGrid {
            xmin: 0.0,
            xmax: 2.5,
            tiers: vec![
                Tier::Interval(IntervalTier {
                    name: "words".into(),
                    xmin: 0.0,
                    xmax: 2.5,
                    intervals: vec![
                        Interval {
                            xmin: 0.0,
                            xmax: 1.0,
                            text: "hola".into(),
                        },
                        Interval {
                            xmin: 1.0,
                            xmax: 2.5,
                            text: "señal \"rara\"".into(),
                        },
                    ],
                }),
                Tier::Point(PointTier {
                    name: "peaks".into(),
                    xmin: 0.0,
                    xmax: 2.5,
                    points: vec![Point {
                        time: 1.25,
                        mark: "H*".into(),
                    }],
                }),
            ],
        }
    }

    #[test]
    fn round_trips_long_form() {
        let g = sample();
        let parsed = parse(&write_bytes(&g)).unwrap();
        assert_eq!(parsed, g);
    }

    #[test]
    fn parses_short_form() {
        let short = "File type = \"ooTextFile\"\nObject class = \"TextGrid\"\n\n\
0\n2.5\n<exists>\n1\n\"IntervalTier\"\n\"words\"\n0\n2.5\n2\n\
0\n1\n\"first\"\n1\n2.5\n\"second \"\"quoted\"\"\"\n";
        let g = parse(short.as_bytes()).unwrap();
        assert_eq!(g.xmax, 2.5);
        assert_eq!(g.tiers.len(), 1);
        match &g.tiers[0] {
            Tier::Interval(t) => {
                assert_eq!(t.intervals.len(), 2);
                assert_eq!(t.intervals[1].text, "second \"quoted\"");
            }
            Tier::Point(_) => panic!("wrong tier class"),
        }
    }

    #[test]
    fn parses_utf16le_and_be() {
        let text = write_long(&sample());
        for (bom, to_bytes) in [
            (
                vec![0xFFu8, 0xFE],
                Box::new(|u: u16| u.to_le_bytes()) as Box<dyn Fn(u16) -> [u8; 2]>,
            ),
            (vec![0xFE, 0xFF], Box::new(|u: u16| u.to_be_bytes())),
        ] {
            let mut bytes = bom;
            for unit in text.encode_utf16() {
                bytes.extend_from_slice(&to_bytes(unit));
            }
            let parsed = parse(&bytes).unwrap();
            assert_eq!(parsed, sample());
        }
    }

    #[test]
    fn empty_grid_absent_tiers() {
        let g = TextGrid {
            xmin: 0.0,
            xmax: 1.0,
            tiers: vec![],
        };
        let parsed = parse(&write_bytes(&g)).unwrap();
        assert_eq!(parsed, g);
    }

    #[test]
    fn multiline_label_survives() {
        let mut g = sample();
        if let Tier::Interval(t) = &mut g.tiers[0] {
            t.intervals[0].text = "line one\nline two".into();
        }
        let parsed = parse(&write_bytes(&g)).unwrap();
        assert_eq!(parsed, g);
    }

    #[test]
    fn rejects_non_textgrid() {
        assert!(parse(b"File type = \"ooTextFile\"\nObject class = \"Sound\"\n\n0\n1\n").is_err());
        assert!(parse(b"garbage").is_err());
    }

    #[test]
    fn crlf_and_trailing_space_tolerated() {
        let text = write_long(&sample()).replace('\n', " \r\n");
        let g = parse(text.as_bytes()).unwrap();
        assert_eq!(g, sample());
    }
}
