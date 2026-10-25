use swarm_core::{decode_address, decode_uint};
type Result<T> = std::result::Result<T, &'static str>;
fn words(raw: &str, count: usize) -> Result<Vec<String>> {
    let s = raw.strip_prefix("0x").ok_or("INVALID_ABI_RESULT")?;
    if s.len() != count * 64 || !s.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("INVALID_ABI_RESULT");
    }
    Ok(s.as_bytes()
        .chunks_exact(64)
        .map(|v| format!("0x{}", std::str::from_utf8(v).unwrap()))
        .collect())
}

pub(crate) fn case_facts(case: &str, vote: &str) -> Result<String> {
    let c = words(case, 25)?;
    let v = words(vote, 5)?;
    decode_address(&c[3]).map_err(|_| "INVALID_ABI_RESULT")?;
    let number = |word: &str| decode_uint(word).map_err(|_| "INVALID_ABI_RESULT");
    let phase = number(&c[7])?;
    let phase_label = [
        "Absent",
        "First committee commitments",
        "Second committee commitments",
        "Reveal / outcome draw",
        "Challenge window",
        "Finalized",
        "Unresolved",
    ]
    .get(phase as usize)
    .ok_or("INVALID_ABI_RESULT")?;
    let verdict = match number(&c[21])? {
        0 => "None",
        1 => "Approve",
        2 => "Reject",
        _ => return Err("INVALID_ABI_RESULT"),
    };
    let settled = number(&v[4])?;
    if settled > 1 || number(&v[1])? > 2 || number(&v[2])? > 2 || number(&v[3])? > 2 {
        return Err("INVALID_ABI_RESULT");
    }
    let has_vote = v[0][2..].bytes().any(|c| c != b'0');
    let vote_label = if !has_vote {
        "No recorded vote"
    } else if settled == 1 {
        "Settled"
    } else {
        "Not settled"
    };
    let verdict_label = if phase == 5 {
        "Final verdict"
    } else {
        "Recorded preliminary verdict"
    };
    Ok(format!("Case 2: {phase_label}\n{verdict_label}: {verdict}\nReveals, first / second: {} / {}\nYour vote on chain: {vote_label}\nRead-only preview: no action or recovery controls are implemented.", number(&c[17])?, number(&c[18])?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(values: &[u64]) -> String {
        format!(
            "0x{}",
            values
                .iter()
                .map(|v| format!("{v:064x}"))
                .collect::<String>()
        )
    }

    fn fixture(phase: u64, settled: u64) -> (String, String) {
        let mut case = vec![0; 25];
        case[3] = 1;
        case[7] = phase;
        case[17] = 3;
        case[18] = 3;
        case[21] = 1;
        (encode(&case), encode(&[42, 1, 0, 1, settled]))
    }

    #[test]
    fn settled_final_vote_gets_explicit_final_verdict_and_settlement() {
        let (case, vote) = fixture(5, 1);
        let facts = case_facts(&case, &vote).unwrap();
        assert!(facts.contains("Final verdict: Approve"));
        assert!(facts.contains("Your vote on chain: Settled"));
        assert!(facts.contains("3 / 3"));
    }

    #[test]
    fn preliminary_outcome_is_not_mislabelled_final() {
        let (case, vote) = fixture(4, 0);
        let facts = case_facts(&case, &vote).unwrap();
        assert!(facts.contains("Recorded preliminary verdict: Approve"));
        assert!(facts.contains("Your vote on chain: Not settled"));
        assert!(!facts.contains("Final verdict:"));
    }

    #[test]
    fn rejects_noncanonical_tuple_shape() {
        let (case, vote) = fixture(5, 1);
        assert!(case_facts(&(case + "00"), &vote).is_err());
        assert!(case_facts("0x", &vote).is_err());
        let (case, invalid_bool) = fixture(5, 2);
        assert!(case_facts(&case, &invalid_bool).is_err());
        let (invalid_phase, vote) = fixture(7, 1);
        assert!(case_facts(&invalid_phase, &vote).is_err());
    }
}
