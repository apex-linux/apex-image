use crate::core::text;

/// rpm 4 prints `Signature, key ID f577861e: OK`, rpm 6 `signature, key fingerprint:
/// 4f50...861e: OK`: `key_id` is the fingerprint's last 8 hex digits, which both contain.
pub fn checksig_ok(output: &[u8], key_id: &str) -> bool {
    let id = key_id.to_ascii_lowercase();
    let mut any = false;
    let mut signed = false;
    for line in text::complete_lines(output) {
        let lower = line.to_ascii_lowercase();
        if !text::contains(&lower, b"signature") {
            continue;
        }
        any = true;
        if !line.ends_with(b": OK") {
            return false;
        }
        if let Some(at) = text::find(&lower, b"signature, key")
            && text::contains(&lower[at + 14..], id.as_bytes())
        {
            signed = true;
        }
    }
    any && signed
}
