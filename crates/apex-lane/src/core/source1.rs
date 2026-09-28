pub fn member_ok(m: &str, paths: &[String]) -> bool {
    paths.iter().any(|p| {
        let parent_of_entry = m.ends_with('/') && p.starts_with(m);
        if p.ends_with('/') {
            m.starts_with(p.as_str()) || parent_of_entry
        } else {
            m == p || parent_of_entry
        }
    })
}

pub fn archive_name(source1: &str, tree: &str) -> String {
    let base = source1.rsplit('/').next().unwrap_or(source1);
    let short: String = tree.chars().take(12).collect();
    format!("apex-{base}-{short}.tar")
}
