//! ROADMAP S1c's lane rehearsals: an injected kmod failure and a set clock, honoured only
//! for a scratch store, so neither can reach the lane's own lock.

use std::path::Path;

use crate::core::utc::UtcSecond;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Rehearsal {
    pub active: bool,
    pub pair_fault: Option<String>,
    pub now: Option<UtcSecond>,
}

/// The environment's values, empty when unset: `APEX_LANE_REHEARSAL`, `APEX_STORE`,
/// `APEX_PAIR_FAULT` and `APEX_LANE_NOW`.
pub fn parse(
    flag: &str,
    store: Option<&Path>,
    default_store: &Path,
    fault: &str,
    now: &str,
) -> Result<Rehearsal, String> {
    if flag.is_empty() {
        if !fault.is_empty() || !now.is_empty() {
            return Err(
                "APEX_PAIR_FAULT and APEX_LANE_NOW are rehearsal hooks: set APEX_LANE_REHEARSAL=1 with a scratch APEX_STORE"
                    .into(),
            );
        }
        return Ok(Rehearsal::default());
    }
    if flag != "1" {
        return Err(format!("APEX_LANE_REHEARSAL is 1 or unset, not '{flag}'"));
    }
    match store {
        Some(store) if store != default_store => {}
        _ => {
            return Err(format!(
                "APEX_LANE_REHEARSAL needs a scratch APEX_STORE, not the lane's {}",
                default_store.display()
            ));
        }
    }
    let pair_fault = match fault {
        "" => None,
        "kmod" => Some(fault.to_owned()),
        _ => return Err(format!("APEX_PAIR_FAULT is kmod or unset, not '{fault}'")),
    };
    let now = match now {
        "" => None,
        _ => Some(UtcSecond::parse(now.as_bytes()).ok_or_else(|| {
            format!("APEX_LANE_NOW is a UTC time like 2026-12-01T00:00:00Z, not '{now}'")
        })?),
    };
    Ok(Rehearsal {
        active: true,
        pair_fault,
        now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const LANE: &str = "/home/builder/apex-store";
    const SCRATCH: &str = "/home/builder/apex-rehearsal/store";

    fn of(flag: &str, store: Option<&str>, fault: &str, now: &str) -> Result<Rehearsal, String> {
        parse(flag, store.map(Path::new), Path::new(LANE), fault, now)
    }

    #[test]
    fn hooks_need_a_rehearsal_on_a_scratch_store() {
        assert_eq!(of("", None, "", ""), Ok(Rehearsal::default()));
        assert_eq!(of("", Some(LANE), "", ""), Ok(Rehearsal::default()));
        assert!(of("", Some(SCRATCH), "kmod", "").is_err(), "no flag");
        assert!(of("", None, "", "2026-12-01T00:00:00Z").is_err());
        assert!(of("1", None, "kmod", "").is_err(), "the default store");
        assert!(
            of("1", Some(LANE), "kmod", "").is_err(),
            "the lane's store named"
        );
        assert!(of("yes", Some(SCRATCH), "", "").is_err());
        assert_eq!(
            of("1", Some(SCRATCH), "kmod", "2026-12-04T00:00:01Z"),
            Ok(Rehearsal {
                active: true,
                pair_fault: Some("kmod".into()),
                now: UtcSecond::parse(b"2026-12-04T00:00:01Z"),
            })
        );
        assert_eq!(
            of("1", Some(SCRATCH), "", ""),
            Ok(Rehearsal {
                active: true,
                ..Rehearsal::default()
            })
        );
        assert!(of("1", Some(SCRATCH), "kernel", "").is_err());
        assert!(of("1", Some(SCRATCH), "", "tomorrow").is_err());
    }
}
