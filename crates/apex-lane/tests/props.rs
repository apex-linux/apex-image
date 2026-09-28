use apex_lane::core::ere::Ere;
use apex_lane::core::lock;
use apex_lane::core::release::{StoredBuild, release_for};
use apex_lane::core::spec_edit::{self, Values};
use apex_lane::core::text;
use apex_lane::core::utc::UtcSecond;
use proptest::prelude::*;

fn family() -> impl Strategy<Value = String> {
    prop::sample::select(vec!["gnome-shell", "libfprint", "mutter", "nautilus"])
        .prop_map(String::from)
}

fn lock_line() -> impl Strategy<Value = String> {
    prop_oneof![
        (family(), "[a-z0-9]{1,6}").prop_map(|(f, k)| format!("family {f} built {k}")),
        (family(), "[a-z ]{0,12}").prop_map(|(f, r)| format!("family {f} degraded - reason={r}")),
        family().prop_map(|f| format!(
            "rpm {f} built {f} {f}-0:1-1.x86_64 {} p/{f}.rpm",
            "a".repeat(64)
        )),
        family().prop_map(|f| format!("rpm\t{f}\tmirror\tm\tm-0:1-1.x86_64\tx\tp")),
        Just("# a comment".to_owned()),
        Just(String::new()),
        Just(" \t".to_owned()),
        family().prop_map(|f| format!("pin {f} 51.0  ")),
    ]
}

fn records_of<'a>(lock_text: &'a [u8], family: &str) -> Vec<&'a [u8]> {
    text::lines(lock_text)
        .into_iter()
        .filter(|l| {
            let f = text::fields(l);
            !l.starts_with(b"#")
                && !f.is_empty()
                && !((f[0] == b"family" || f[0] == b"rpm") && f.get(1) == Some(&family.as_bytes()))
        })
        .collect()
}

proptest! {
    #![proptest_config(ProptestConfig { rng_seed: proptest::test_runner::RngSeed::Fixed(0x1a4e), ..ProptestConfig::default() })]

    #[test]
    fn lock_put_keeps_the_others_and_puts_the_family_last(
        lines in prop::collection::vec(lock_line(), 0..12),
        family in family(),
        key in "[a-z0-9]{1,8}",
        rpm_count in 0usize..3,
    ) {
        let old = text::join_lines(&lines);
        let rpms: Vec<String> = (0..rpm_count).map(|i| format!("rpm {family} built n n-0:1-1.x86_64 {} p/{i}", "b".repeat(64))).collect();
        let rpms = text::join_lines(&rpms);
        let line = format!("built {key}");
        let new = lock::put(Some(&old), &family, line.as_bytes(), &rpms);
        prop_assert_eq!(records_of(&old, &family), records_of(&new, &family));
        let family_lines: Vec<&[u8]> = text::lines(&new).into_iter().filter(|l| {
            let f = text::fields(l);
            f.first() == Some(&&b"family"[..]) && f.get(1) == Some(&family.as_bytes())
        }).collect();
        let family_line = format!("family {family} {line}");
        prop_assert_eq!(family_lines, vec![family_line.as_bytes()]);
        let expected_tail = [format!("family {family} {line}\n").as_bytes(), rpms.as_slice()].concat();
        prop_assert!(new.ends_with(&expected_tail));
        prop_assert_eq!(lock::put(Some(&new), &family, line.as_bytes(), &rpms), new);
    }

    #[test]
    fn release_for_never_reuses_a_release(
        stored in prop::collection::vec((0u8..6, 0u64..5, prop::bool::ANY), 0..8),
        key in 0u8..8,
    ) {
        let stock = "x-51.0-1.fc45";
        let base = "1.fc45.apex3";
        let builds: Vec<StoredBuild> = stored.iter().map(|(k, m, same_stock)| StoredBuild {
            key: format!("k{k}").into_bytes(),
            release: if *m == 0 { base.as_bytes().to_vec() } else { format!("{base}.{m}").into_bytes() },
            stock: if *same_stock { stock.as_bytes().to_vec() } else { b"x-51.1-1.fc45".to_vec() },
        }).collect();
        let key = format!("k{key}");
        let got = release_for(&builds, stock, base, &key);
        if let Some(b) = builds.iter().find(|b| b.key == key.as_bytes()) {
            prop_assert_eq!(got, b.release.clone());
        } else {
            for b in builds.iter().filter(|b| b.stock == stock.as_bytes()) {
                prop_assert_ne!(&got, &b.release);
            }
            let m = |r: &[u8]| -> i64 {
                if r == base.as_bytes() { 0 } else {
                    std::str::from_utf8(&r[base.len() + 1..]).ok().and_then(|s| s.parse().ok()).unwrap_or(-1)
                }
            };
            let top = builds.iter().filter(|b| b.stock == stock.as_bytes()).map(|b| m(&b.release)).max();
            prop_assert!(top.is_none_or(|t| m(&got) > t));
        }
    }

    #[test]
    fn spec_edit_changes_only_the_anchor(
        before in prop::collection::vec("[a-z %{}:]{0,20}", 0..8),
        after in prop::collection::vec("[a-z %{}:]{0,20}", 0..8),
        text_lines in prop::collection::vec("[a-zA-Z0-9 %{}]{0,16}", 1..4),
        replace in prop::bool::ANY,
    ) {
        let anchor = "ANCHOR: here";
        let spec: Vec<String> = before.iter().cloned().chain([anchor.to_owned()]).chain(after.iter().cloned()).collect();
        let spec_bytes = text::join_lines(&spec);
        let op = if replace { "replace" } else { "after" };
        let body: String = text_lines.iter().flat_map(|l| ["\t", l.as_str(), "\n"]).collect();
        let edit = format!("{op} ^ANCHOR: here$\n{body}end\n");
        let parsed = spec_edit::parse("spec-edit", edit.as_bytes()).map_err(|e| TestCaseError::fail(e.0))?;
        let out = spec_edit::apply(&parsed, &spec_bytes, &Values::default(), &mut |_| {}).map_err(|e| TestCaseError::fail(text::lossy(&e.reason())))?;
        let expected: Vec<String> = before.iter().cloned()
            .chain((!replace).then(|| anchor.to_owned()))
            .chain(text_lines.iter().cloned())
            .chain(after.iter().cloned())
            .collect();
        prop_assert_eq!(out, text::join_lines(&expected));
    }

    #[test]
    fn utc_round_trips(secs in 0i64..8_000_000_000) {
        let t = UtcSecond(secs);
        prop_assert_eq!(UtcSecond::parse(t.to_string().as_bytes()), Some(t));
        prop_assert_eq!(t.add_days(14), t.add_hours(336));
    }

    #[test]
    fn an_escaped_literal_matches_itself(literal in "[ -~]{1,24}") {
        let escaped: String = literal.chars().map(|c| {
            if ".[](){}*+?|^$\\/".contains(c) { format!("\\{c}") } else { c.to_string() }
        }).collect();
        let ere = Ere::new(format!("^{escaped}$").as_bytes()).map_err(|e| TestCaseError::fail(e.0))?;
        prop_assert!(ere.is_match(literal.as_bytes()));
        let longer = format!("{literal}x");
        prop_assert!(!ere.is_match(longer.as_bytes()));
    }
}
