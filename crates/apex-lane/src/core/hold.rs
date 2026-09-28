use crate::core::lock;
use crate::core::text;
use crate::core::utc::UtcSecond;

pub const DEFAULT_REASON: &str = "the build failed (no reason recorded)";
pub const STOCK_REASON: &str = "the owner chose Fedora's build";
const SECURITY_HOLD_LIMIT_HOURS: i64 = 72;
const HOLD_LIMIT_DAYS: i64 = 14;

/// The variant order matters: the verdict over several builds is the highest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Security {
    No,
    Unknown,
    Yes,
}

impl Security {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::No => "0",
            Self::Unknown => "?",
            Self::Yes => "1",
        }
    }

    pub fn of_types(types: &str) -> Self {
        if format!(" {types} ").contains(" security ") {
            Self::Yes
        } else if types.is_empty() {
            Self::Unknown
        } else {
            Self::No
        }
    }

    pub fn limit(self, since: UtcSecond) -> UtcSecond {
        if self == Self::No {
            since.add_days(HOLD_LIMIT_DAYS)
        } else {
            since.add_hours(SECURITY_HOLD_LIMIT_HOURS)
        }
    }
}

/// `[.updates[]?.type] | join(" ")` of a Bodhi `/updates/?builds=` answer; empty for
/// anything jq would fail on.
pub fn bodhi_types(json: &[u8]) -> String {
    use serde_json::Value;
    let Ok(doc) = serde_json::from_slice::<Value>(json) else {
        return String::new();
    };
    let updates: Vec<&Value> = match doc.get("updates") {
        Some(Value::Array(items)) => items.iter().collect(),
        Some(Value::Object(map)) => map.values().collect(),
        _ => Vec::new(),
    };
    let mut types = Vec::new();
    for update in updates {
        let t = match update {
            Value::Object(map) => map.get("type").unwrap_or(&Value::Null),
            Value::Null => &Value::Null,
            _ => return String::new(),
        };
        types.push(match t {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            Value::Bool(_) | Value::Number(_) => t.to_string(),
            Value::Array(_) | Value::Object(_) => return String::new(),
        });
    }
    let joined = types.join(" ");
    joined.trim_end_matches('\n').to_owned()
}

pub fn reason_of(failed_txt: Option<&[u8]>) -> Vec<u8> {
    let first: Vec<u8> = failed_txt
        .map(|t| {
            let line = t.split(|&b| b == b'\n').next().unwrap_or_default();
            line.iter().copied().filter(|&b| b != 0).collect()
        })
        .unwrap_or_default();
    let first = if first.is_empty() {
        DEFAULT_REASON.as_bytes().to_vec()
    } else {
        first
    };
    first
        .into_iter()
        .map(|b| if (0x20..=0x7e).contains(&b) { b } else { b' ' })
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FailureRoute {
    Degrade { line: Vec<u8> },
    StayStock,
    Hold,
}

pub fn route_failure(
    degrade: bool,
    next_current: &[u8],
    reason: &[u8],
    now: UtcSecond,
) -> FailureRoute {
    if degrade {
        let mut line = format!("degraded - since={now} reason=").into_bytes();
        line.extend_from_slice(reason);
        FailureRoute::Degrade { line }
    } else if next_current.starts_with(b"stock ") {
        FailureRoute::StayStock
    } else {
        FailureRoute::Hold
    }
}

pub fn good_key(good: &[u8]) -> Option<String> {
    let rest = good
        .strip_prefix(b"built ")
        .or_else(|| good.strip_prefix(b"held "))?;
    let len = rest.iter().take_while(|&&b| b != b' ').count();
    (len > 0).then(|| text::lossy(&rest[..len]))
}

pub fn newer(attempt: &[u8], good_stock: &[u8], good_pin: &[u8]) -> Vec<String> {
    text::newline_terminated_lines(attempt)
        .into_iter()
        .filter_map(|line| {
            let f = text::read_fields(line, 2);
            let differs = match f[0] {
                b"stock" => f[1] != good_stock,
                b"pin" => f[1] != good_pin,
                _ => false,
            };
            differs.then(|| text::lossy(f[1]))
        })
        .collect()
}

pub fn since(next_current: &[u8], newer_csv: &str, now: UtcSecond) -> Vec<u8> {
    if next_current.starts_with(b"held ")
        && lock::attr(next_current, "newer") == newer_csv.as_bytes()
    {
        let since = lock::attr(next_current, "since");
        if !since.is_empty() {
            return since;
        }
    }
    now.to_string().into_bytes()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timer {
    pub limit: UtcSecond,
    pub security: Security,
}

pub fn held_line(
    good_key: &str,
    since: &[u8],
    newer_csv: &str,
    timer: Option<&Timer>,
    reason: &[u8],
) -> Vec<u8> {
    let mut line = format!("held {good_key} since=").into_bytes();
    line.extend_from_slice(since);
    if let Some(t) = timer {
        line.extend_from_slice(
            format!(
                " limit={} newer={newer_csv} security={}",
                t.limit,
                t.security.as_str()
            )
            .as_bytes(),
        );
    }
    line.extend_from_slice(b" reason=");
    line.extend_from_slice(reason);
    line
}

pub fn summary_degraded(pkg: &str, family: &str, reason: &[u8]) -> Vec<String> {
    vec![
        format!("### {pkg}: degraded"),
        String::new(),
        text::lossy(reason),
        String::new(),
        format!("The next image takes Fedora's {family}."),
    ]
}

pub fn summary_stays_stock(pkg: &str, family: &str, reason: &[u8]) -> Vec<String> {
    vec![
        format!("### {pkg}: failed, stays stock"),
        String::new(),
        text::lossy(reason),
        String::new(),
        format!("The owner chose Fedora's build of the {family} family; the next image keeps it."),
    ]
}

pub fn summary_held(
    pkg: &str,
    reason: &[u8],
    good_key: &str,
    since: &[u8],
    newer: &[String],
    timer: Option<&Timer>,
    now: UtcSecond,
) -> Vec<String> {
    let note = match timer {
        None => "No newer Fedora build is waiting: the Apex inputs themselves fail, so there is no limit.".to_owned(),
        Some(t) => {
            let mut note = format!(
                "Newer Fedora builds: {} (security: {}). Limit: {}.",
                newer.join(", "),
                t.security.as_str(),
                t.limit
            );
            if now >= t.limit {
                note = format!(
                    "{note} LIMIT REACHED: rebase the series (just pkg-rebase {pkg} NVR), or ship Fedora's build (just pkg-stock {pkg})."
                );
            }
            note
        }
    };
    vec![
        format!("### {pkg}: held"),
        String::new(),
        text::lossy(reason),
        String::new(),
        format!(
            "The next image keeps the last good build, {good_key}, held since {}. {note}",
            text::lossy(since)
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn security_order_and_limits() {
        assert!(Security::No < Security::Unknown && Security::Unknown < Security::Yes);
        assert_eq!(Security::of_types("bugfix security"), Security::Yes);
        assert_eq!(Security::of_types("securityx"), Security::No);
        assert_eq!(Security::of_types(""), Security::Unknown);
        let since = UtcSecond::parse(b"2026-10-12T04:10:00Z").unwrap();
        assert_eq!(
            Security::Unknown.limit(since).to_string(),
            "2026-10-15T04:10:00Z"
        );
        assert_eq!(
            Security::No.limit(since).to_string(),
            "2026-10-26T04:10:00Z"
        );
    }

    #[test]
    fn bodhi_answers() {
        assert_eq!(
            bodhi_types(br#"{"updates":[{"type":"security"}]}"#),
            "security"
        );
        assert_eq!(
            bodhi_types(br#"{"updates":[{"type":"bugfix"},{"type":"security"}]}"#),
            "bugfix security"
        );
        assert_eq!(bodhi_types(br#"{"updates":[]}"#), "");
        assert_eq!(bodhi_types(br#"{"total":0}"#), "");
        assert_eq!(bodhi_types(b"not json"), "");
        assert_eq!(bodhi_types(br#"{"updates":["x"]}"#), "");
        assert_eq!(
            bodhi_types(br#"{"updates":[{"type":null},{"type":"bugfix"}]}"#),
            " bugfix"
        );
    }

    #[test]
    fn reasons() {
        assert_eq!(reason_of(None), DEFAULT_REASON.as_bytes());
        assert_eq!(reason_of(Some(b"\nx")), DEFAULT_REASON.as_bytes());
        assert_eq!(reason_of(Some("a\tb \u{e9}\nc".as_bytes())), b"a b   ");
        assert_eq!(reason_of(Some(b"a\0b")), b"ab");
    }

    #[test]
    fn newer_builds() {
        let attempt = b"stock gnome-shell-51.1-1.fc45\npin mutter-51.0-1.fc45\n";
        assert_eq!(
            newer(attempt, b"gnome-shell-51.0-1.fc45", b"mutter-51.0-1.fc45"),
            ["gnome-shell-51.1-1.fc45"]
        );
        assert_eq!(
            newer(b"stock x", b"y", b"-"),
            Vec::<String>::new(),
            "a last line without newline is not read"
        );
    }
}
