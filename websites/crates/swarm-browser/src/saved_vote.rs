//! Locate a saved secret for a mined commitment. Committee intent is not part
//! of the commitment domain and can differ from the committee assigned on chain.
use crate::BrowserResult as Result;
use swarm_core::{
    moderator::{make_commitment, Uint256},
    recovery::{VoteContext, VoteRecord},
};

pub(crate) fn matching_record(
    context: &VoteContext,
    commitment: &str,
    records: &[VoteRecord],
) -> Result<VoteRecord> {
    let context = context.clone().normalized().map_err(|e| e.0)?;
    let chain = context
        .chain_id
        .parse::<u64>()
        .map_err(|_| "INVALID_RECORD")?;
    let case = Uint256::decimal(&context.case_id).map_err(|e| e.0)?;
    let mut found: Option<VoteRecord> = None;
    for record in records.iter().filter(|v| {
        v.chain_id == context.chain_id
            && v.contract.eq_ignore_ascii_case(&context.contract)
            && v.voter.eq_ignore_ascii_case(&context.voter)
            && v.case_id == context.case_id
            && v.round == context.round
            && v.commitment.eq_ignore_ascii_case(commitment)
    }) {
        let record = record.clone().normalized().map_err(|e| e.0)?;
        let computed = make_commitment(
            chain,
            &context.contract,
            case,
            context.round,
            &context.voter,
            record.vote,
            &record.salt,
        )
        .map_err(|e| e.0)?;
        if !computed.eq_ignore_ascii_case(commitment)
            || found
                .as_ref()
                .is_some_and(|old| old.vote != record.vote || old.salt != record.salt)
        {
            return Err("SECRET_MISMATCH");
        }
        if found.is_none() {
            found = Some(record);
        }
    }
    found.ok_or("SECRET_NOT_FOUND")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> VoteRecord {
        let mut record = VoteRecord {
            chain_id: "10200".into(),
            contract: format!("0x{}", "11".repeat(20)),
            voter: format!("0x{}", "22".repeat(20)),
            case_id: "4".into(),
            round: 0,
            committee: 1,
            commitment: String::new(),
            vote: 1,
            salt: format!("0x{}", "44".repeat(32)),
        };
        record.commitment = make_commitment(
            10200,
            &record.contract,
            Uint256::decimal("4").unwrap(),
            0,
            &record.voter,
            1,
            &record.salt,
        )
        .unwrap();
        record
    }
    #[test]
    fn mined_commitment_matches_despite_a_different_saved_committee_intent() {
        let record = fixture();
        let mut context = record.context();
        context.committee = 2;
        let found = matching_record(&context, &record.commitment, &[record.clone()]).unwrap();
        assert_eq!(found.committee, 1);
        assert_eq!(found.commitment, record.commitment);
    }
    #[test]
    fn other_deployments_accounts_cases_rounds_and_commitments_cannot_match() {
        let record = fixture();
        let base = record.context();
        let mut contexts = vec![];
        let mut c = base.clone();
        c.chain_id = "100".into();
        contexts.push(c);
        let mut c = base.clone();
        c.contract = format!("0x{}", "55".repeat(20));
        contexts.push(c);
        let mut c = base.clone();
        c.voter = format!("0x{}", "66".repeat(20));
        contexts.push(c);
        let mut c = base.clone();
        c.case_id = "5".into();
        contexts.push(c);
        let mut c = base.clone();
        c.round = 1;
        contexts.push(c);
        for context in contexts {
            assert_eq!(
                matching_record(&context, &record.commitment, &[record.clone()]).err(),
                Some("SECRET_NOT_FOUND")
            );
        }
        assert_eq!(
            matching_record(&base, &format!("0x{}", "77".repeat(32)), &[record]).err(),
            Some("SECRET_NOT_FOUND")
        );
    }
    #[test]
    fn a_matching_label_with_a_changed_secret_is_rejected() {
        let mut record = fixture();
        let context = record.context();
        let commitment = record.commitment.clone();
        record.salt = format!("0x{}", "88".repeat(32));
        assert_eq!(
            matching_record(&context, &commitment, &[record]).err(),
            Some("SECRET_MISMATCH")
        );
    }
}
