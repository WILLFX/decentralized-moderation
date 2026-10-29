use swarm_core::{moderator::*, Timing};
#[test]
fn commitment_matches_existing_ethers_abi_vector() {
    // Generated with the existing pinned ethers codec, using synthetic addresses and zero salt.
    let result = make_commitment(
        10200,
        "0x2222222222222222222222222222222222222222",
        Uint256::from_u64(2),
        0,
        "0x1111111111111111111111111111111111111111",
        1,
        &hash(0),
    )
    .unwrap();
    assert_eq!(
        result,
        "0xee5da45dac3b8de42cacf0e80345648b3ac172e27577a4eedb5f32fc0ff4fea2"
    );
    assert_ne!(
        result,
        make_commitment(
            100,
            "0x2222222222222222222222222222222222222222",
            Uint256::from_u64(2),
            0,
            "0x1111111111111111111111111111111111111111",
            1,
            &hash(0)
        )
        .unwrap()
    );
}
fn hash(n: u64) -> String {
    format!("0x{}", Uint256::from_u64(n).abi())
}
fn raw(values: &[u64]) -> String {
    format!(
        "0x{}",
        values
            .iter()
            .map(|v| Uint256::from_u64(*v).abi())
            .collect::<String>()
    )
}
fn snapshot() -> CaseSnapshot {
    let mut values = [0; 25];
    values[4] = 1;
    values[7] = 3;
    values[9] = 2000;
    values[11] = 80;
    values[12] = 90;
    CaseSnapshot {
        outcome_recovery: None,
        case_id: Uint256::from_u64(2),
        source: SourceBlock {
            number: 100,
            timestamp: 1000,
            hash: hash(10),
        },
        case: decode_case(&raw(&values)).unwrap(),
        vote: decode_vote(&format!(
            "0x{}{}",
            Uint256::from_u64(99).abi(),
            &raw(&[1, 0, 0, 0])[2..]
        ))
        .unwrap(),
        schedule: decode_schedule(&raw(&[900, 950, 0, 0])).unwrap(),
        moderator: decode_stake(&raw(&[1, 0, 1, 0])).unwrap(),
        refund_owed: Uint256::ZERO,
    }
}
fn timing() -> Timing {
    Timing {
        clock_error_seconds: 5,
        max_evidence_age_seconds: 30,
        max_head_lag_seconds: 30,
        inclusion_budget_seconds: 120,
    }
}
#[test]
fn uint256_exact_and_overflow() {
    let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    assert_eq!(Uint256::decimal(max).unwrap().abi(), "ff".repeat(32));
    assert_eq!(Uint256::decimal(max).unwrap().to_decimal(), max);
    assert!(Uint256::decimal(
        "115792089237316195423570985008687907853269984665640564039457584007913129639936"
    )
    .is_err());
    assert!(Uint256::decimal("01").is_err());
    assert_eq!(Uint256::from_u64(858).quantity(), "0x35a");
}
#[test]
fn canonical_abi_rejects_extra_data_bool_and_width() {
    assert!(decode_vote(&format!("0x{}", "é".repeat(160))).is_err());
    assert!(decode_vote(&raw(&[1, 1, 0, 0, 2])).is_err());
    assert!(decode_schedule(&raw(&[1u64 << 40, 2, 0, 0])).is_err());
    assert!(decode_stake(&raw(&[1, 0, 1u64 << 32, 0])).is_err());
    assert!(decode_topics(&raw(&[1, 2, 3, 4, 5, 6])).is_err());
}
#[test]
fn shared_commit_windows_and_third_commit_revision() {
    let mut s = snapshot();
    s.case.phase = 1;
    s.vote.commitment = hash(0);
    s.source.timestamp = 899;
    s.case.commits_a = 2;
    s.case.phase_deadline = 900;
    s.case.seed_block_b = 110;
    assert_eq!(committee_at(&s), Some(1));
    assert!(case_actions(&s, Eligibility::Selected).allowed(Action::Commit));
    s.source.number = 110;
    assert!(!case_actions(&s, Eligibility::Selected).allowed(Action::Commit));
    s.source.timestamp = 900;
    s.case.commits_a = 0;
    assert_eq!(committee_at(&s), None);
    s.case.phase = 2;
    assert_eq!(committee_at(&s), Some(2));
}
#[test]
fn outcome_draw_exact_250_block_horizon_and_claim_once() {
    let mut s = snapshot();
    s.case.outcome_seed_block = 100;
    s.source.number = 100;
    assert!(!case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
    s.source.number = 350;
    assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
    s.source.number = 351;
    assert_eq!(
        case_actions(&s, Eligibility::NotOpen).state,
        "OUTCOME_EXPIRED"
    );
    s.case.phase = 5;
    assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Claim));
    s.vote.settled = true;
    assert!(!case_actions(&s, Eligibility::NotOpen).allowed(Action::Claim));
}
#[test]
fn finalized_guard_checks_wall_head_and_budget() {
    let f = snapshot();
    let mut h = f.clone();
    h.source.number += 1;
    let input = GuardInput {
        case_id: f.case_id,
        voter: "0x1111111111111111111111111111111111111111",
        commitment: &f.vote.commitment,
        expected_round: 0,
    };
    assert!(check_reveal(&f, &h, &input, &timing(), 1_000_000, 10).ready);
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_031_000, 10).reason,
        "HEAD_STALE"
    );
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 30_001).reason,
        "EVIDENCE_STALE"
    );
    h.source.timestamp = 1006;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 10).reason,
        "HEAD_CLOCK_AHEAD"
    );
    h.source.timestamp = 1000;
    h.case.phase_deadline = 1125;
    let mut f = f.clone();
    f.case.phase_deadline = 1125;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 10).reason,
        "INCLUSION_BUDGET"
    );
}
#[test]
fn finalized_guard_rejects_changed_round_commitment_and_seed() {
    let f = snapshot();
    let input = GuardInput {
        case_id: f.case_id,
        voter: "0x1111111111111111111111111111111111111111",
        commitment: &f.vote.commitment,
        expected_round: 0,
    };
    let mut h = f.clone();
    h.vote.round = 1;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "ROUND_CHANGED"
    );
    h = f.clone();
    h.vote.commitment = hash(88);
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "COMMITMENT_CHANGED"
    );
    h = f.clone();
    h.case.outcome_seed_block = 1;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "OUTCOME_ARMED"
    );
}
#[test]
fn staking_preserves_fixed_amount_and_open_vote_lock() {
    let mut s = snapshot();
    let n = Uint256::from_u64;
    assert!(!staking_actions(&s.moderator, 1000, n(10), n(100), n(100)).withdraw);
    s.moderator.open_votes = 0;
    assert!(staking_actions(&s.moderator, 1000, n(10), n(100), n(100)).withdraw);
    s.moderator.staked = false;
    assert!(staking_actions(&s.moderator, 1000, n(10), n(100), n(0)).approve_stake);
    assert!(!staking_actions(&s.moderator, 1000, n(10), n(100), n(0)).stake);
}

#[test]
fn transaction_preparation_binds_round_committee_and_reveal_secret() {
    let voter = "0x1111111111111111111111111111111111111111";
    let moderation = "0x2222222222222222222222222222222222222222";
    let commitment = hash(99);
    let salt = hash(0);
    let mut s = snapshot();
    s.case.phase = 1;
    s.source.timestamp = 899;
    s.case.phase_deadline = 900;
    s.vote.commitment = hash(0);
    s.case.seed_block_b = 110;
    let mut input = ActionInput {
        action: Action::Commit,
        case_id: s.case_id,
        voter,
        beneficiary: None,
        expected_round: Some(0),
        expected_committee: Some(1),
        expected_outcome: None,
        commitment: Some(&commitment),
        vote: None,
        salt: None,
    };
    assert!(
        prepare_action(10200, moderation, &s, Eligibility::Selected, &input)
            .unwrap()
            .starts_with(&swarm_core::selector("commit(uint256,bytes32)"))
    );
    input.expected_committee = Some(2);
    assert_eq!(
        prepare_action(10200, moderation, &s, Eligibility::Selected, &input)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_COMMITTEE"
    );
    input.action = Action::Reveal;
    input.vote = Some(1);
    input.salt = Some(&salt);
    s.case.phase = 3;
    s.case.phase_deadline = 2000;
    s.vote.commitment = commitment.clone();
    assert_eq!(
        prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_COMMITMENT"
    );
    s.vote.commitment = make_commitment(10200, moderation, s.case_id, 0, voter, 1, &salt).unwrap();
    assert!(prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input).is_ok());
    input.expected_round = Some(1);
    assert_eq!(
        prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_ROUND"
    );
}

#[test]
fn all_action_calldata_matches_existing_ethers_interface() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/moderator-calldata.json")).unwrap();
    for vector in fixture["vectors"].as_array().unwrap() {
        let (action, extra) = match vector["action"].as_str().unwrap() {
            "Commit" => (Action::Commit, vec![hash(99)]),
            "Reveal" => (Action::Reveal, vec!["1".into(), hash(0)]),
            "Claim" => (
                Action::Claim,
                vec!["0x1111111111111111111111111111111111111111".into()],
            ),
            "Challenge" => (Action::Challenge, vec!["0".into(), "1".into()]),
            "CloseCommitA" => (Action::CloseCommitA, vec![]),
            "CloseCommitB" => (Action::CloseCommitB, vec![]),
            "CloseReveal" => (Action::CloseReveal, vec![]),
            "Draw" => (Action::Draw, vec![]),
            "CloseChallenge" => (Action::CloseChallenge, vec![]),
            "WithdrawRefund" => (Action::WithdrawRefund, vec![]),
            _ => panic!("unknown fixture action"),
        };
        assert_eq!(
            encode_action(action, Uint256::from_u64(2), &extra).unwrap(),
            vector["data"].as_str().unwrap(),
            "{action:?}"
        );
    }
}

#[test]
fn freezing_and_challenge_boundaries_match_source_block() {
    let n = Uint256::from_u64;
    let mut s = snapshot();
    s.moderator.open_votes = 0;
    for (frozen_until, withdraw) in [(999, true), (1000, true), (1001, false)] {
        s.moderator.frozen_until = frozen_until;
        assert_eq!(
            staking_actions(&s.moderator, 1000, n(10), n(100), n(100)).withdraw,
            withdraw
        );
    }
    s.case.phase = 4;
    s.case.phase_deadline = 1100;
    s.vote.commitment = hash(0);
    for (frozen_until, used, round, now, allowed) in [
        (1000, false, 0, 1000, true),
        (1001, false, 0, 1000, false),
        (0, true, 0, 1000, false),
        (0, false, 1, 1000, true),
        (0, false, 2, 1000, false),
        (0, false, 0, 1100, false),
    ] {
        s.moderator.frozen_until = frozen_until;
        s.vote.commitment = hash(if used { 99 } else { 0 });
        s.case.challenges = round;
        s.source.timestamp = now;
        assert_eq!(
            case_actions(&s, Eligibility::NotOpen).allowed(Action::Challenge),
            allowed,
            "freeze={frozen_until},used={used},round={round},time={now}"
        );
    }
}

#[test]
fn non_vote_actions_reject_stale_ui_round_when_supplied() {
    let mut s = snapshot();
    s.case.phase = 4;
    s.case.phase_deadline = 999;
    s.case.challenges = 1;
    let mut input = ActionInput {
        action: Action::CloseChallenge,
        case_id: s.case_id,
        voter: "0x1111111111111111111111111111111111111111",
        beneficiary: None,
        expected_round: Some(0),
        expected_committee: None,
        expected_outcome: None,
        commitment: None,
        vote: None,
        salt: None,
    };
    let moderation = "0x2222222222222222222222222222222222222222";
    assert_eq!(
        prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_ROUND"
    );
    input.expected_round = Some(1);
    assert!(prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input).is_ok());
    s.case.phase = 5;
    input.action = Action::Claim;
    input.expected_round = Some(0);
    assert_eq!(
        prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_ROUND"
    );
    input.expected_round = Some(1);
    assert!(prepare_action(10200, moderation, &s, Eligibility::NotOpen, &input).is_ok());
}

#[test]
fn reveal_guard_rejects_changed_identity_phase_and_source_order() {
    type Edit = fn(&mut CaseSnapshot);
    let changes: &[(&str, bool, Edit)] = &[
        ("FINALIZED_REVEAL_REQUIRED", true, |s| s.case.phase = 2),
        ("LATEST_REVEAL_REQUIRED", false, |s| s.case.phase = 4),
        ("CASE_CHANGED", false, |s| s.case.content_hash = hash(1)),
        ("CASE_CHANGED", false, |s| s.case.meta_hash = hash(1)),
        ("CASE_CHANGED", false, |s| s.case.claim_key = hash(1)),
        ("CASE_CHANGED", false, |s| {
            s.case.submitter = "0x1111111111111111111111111111111111111111".into()
        }),
        ("CASE_CHANGED", false, |s| s.case.topic_count = 2),
        ("CASE_CHANGED", false, |s| s.case.action_type = 1),
        ("CASE_CHANGED", false, |s| {
            s.case.target_case_id = Uint256::from_u64(1)
        }),
        ("DEADLINE_CHANGED", true, |s| s.case.phase_deadline -= 1),
        ("VOTE_REVEALED", true, |s| s.vote.revealed = 1),
        ("VOTE_SETTLED", false, |s| s.vote.settled = true),
        ("NODE_ORDER_INVALID", true, |s| s.source.number += 1),
        ("NODE_ORDER_INVALID", true, |s| s.source.timestamp += 1),
        ("NODE_ORDER_INVALID", false, |s| s.source.hash = hash(11)),
        ("SNAPSHOT_INVALID", false, |s| {
            s.source.hash = "invalid".into()
        }),
    ];
    let base = snapshot();
    let input = GuardInput {
        case_id: base.case_id,
        voter: "0x1111111111111111111111111111111111111111",
        commitment: &base.vote.commitment,
        expected_round: 0,
    };
    for (reason, edit_finalized, edit) in changes {
        let mut f = base.clone();
        let mut h = base.clone();
        edit(if *edit_finalized { &mut f } else { &mut h });
        assert_eq!(
            check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
            *reason
        );
    }
    let mut h = base.clone();
    let mut f = base.clone();
    f.case.phase_deadline = 1005;
    h.case.phase_deadline = 1005;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "WINDOW_EXPIRED"
    );
    f = base.clone();
    h = base.clone();
    f.source.timestamp = 900;
    h.source.timestamp = 900;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "HEAD_STALE"
    );
    f = base.clone();
    h = base.clone();
    f.source.timestamp = 1006;
    h.source.timestamp = 1006;
    assert_eq!(
        check_reveal(&f, &h, &input, &timing(), 1_000_000, 0).reason,
        "HEAD_CLOCK_AHEAD"
    );
}

#[test]
fn challenge_codec_requires_both_reviewed_arguments_and_strict_capability() {
    let id = Uint256::from_u64(2);
    assert!(encode_action(Action::Challenge, id, &[]).is_err());
    for values in [
        ["2", "1"],
        ["256", "1"],
        ["0", "0"],
        ["0", "3"],
        ["-1", "1"],
    ] {
        assert!(encode_action(Action::Challenge, id, &values.map(String::from)).is_err());
    }
    for round in 0..2 {
        for outcome in 1..3 {
            let data = encode_action(
                Action::Challenge,
                id,
                &[round.to_string(), outcome.to_string()],
            )
            .unwrap();
            assert_eq!(data.len(), 202);
            assert!(data.ends_with(&format!(
                "{}{}",
                Uint256::from_u64(round).abi(),
                Uint256::from_u64(outcome).abi()
            )));
        }
    }
    assert!(challenge_intent_supported(&format!(
        "0x{}",
        Uint256::from_u64(1).abi()
    )));
    for raw in ["0x", "0x1", "0x01", "bad"] {
        assert!(!challenge_intent_supported(raw));
    }
    for n in [0, 2, 255] {
        assert!(!challenge_intent_supported(&format!(
            "0x{}",
            Uint256::from_u64(n).abi()
        )));
    }
}

#[test]
fn challenge_preflight_encodes_and_rejects_changed_reviewed_context() {
    let mut s = snapshot();
    s.case.phase = 4;
    s.case.phase_deadline = 1100;
    s.case.preliminary = 1;
    s.vote.commitment = hash(0);
    let mut i = ActionInput {
        action: Action::Challenge,
        case_id: s.case_id,
        voter: "0x1111111111111111111111111111111111111111",
        beneficiary: None,
        expected_round: Some(0),
        expected_committee: None,
        expected_outcome: Some(1),
        commitment: None,
        vote: None,
        salt: None,
    };
    let target = "0x2222222222222222222222222222222222222222";
    let data = prepare_action(10200, target, &s, Eligibility::NotOpen, &i).unwrap();
    assert_eq!(
        data,
        encode_action(Action::Challenge, s.case_id, &["0".into(), "1".into()]).unwrap()
    );
    s.case.challenges = 1;
    assert_eq!(
        prepare_action(10200, target, &s, Eligibility::NotOpen, &i)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_ROUND"
    );
    s.case.challenges = 0;
    s.case.preliminary = 2;
    assert_eq!(
        prepare_action(10200, target, &s, Eligibility::NotOpen, &i)
            .unwrap_err()
            .0,
        "CONTEXT_CHANGED_OUTCOME"
    );
    s.case.preliminary = 1;
    i.expected_outcome = None;
    assert!(prepare_action(10200, target, &s, Eligibility::NotOpen, &i).is_err());
}

#[test]
fn recovery_boundary_and_cached_original_are_distinct_from_read_failures() {
    let mut s = snapshot();
    s.case.phase = 3;
    s.case.outcome_seed_block = 100;
    let zero = format!("0x{}", "00".repeat(32));
    s.outcome_recovery = Some(OutcomeRecovery {
        original_hash: zero,
        recover_until: 8291,
        expired: false,
    });
    for (height, draw, expire) in [
        (100, false, false),
        (101, true, false),
        (356, true, false),
        (357, true, false),
        (8291, true, false),
        (8292, false, true),
    ] {
        s.source.number = height;
        let a = case_actions(&s, Eligibility::NotOpen);
        assert_eq!(a.allowed(Action::Draw), draw);
        assert_eq!(a.allowed(Action::ExpireOutcome), expire);
    }
    s.outcome_recovery.as_mut().unwrap().original_hash = hash(9);
    s.source.number = 100000;
    assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
    assert!(!case_actions(&s, Eligibility::NotOpen).allowed(Action::ExpireOutcome));
    s.outcome_recovery = None; // failed/unknown capability never authorizes expiry
    assert!(!case_actions(&s, Eligibility::NotOpen).allowed(Action::ExpireOutcome));
}
#[test]
fn recovery_decoder_rejects_unknown_malformed_and_wrong_boundaries() {
    let mut c = snapshot().case;
    c.outcome_seed_block = 100;
    let raw = format!(
        "0x{}{}{}{}",
        Uint256::from_u64(1).abi(),
        Uint256::ZERO.abi(),
        Uint256::from_u64(8291).abi(),
        Uint256::ZERO.abi()
    );
    assert!(decode_outcome_recovery(&raw, &c).is_ok());
    assert!(decode_outcome_recovery("0x1", &c).is_err());
    for (version, until, expired) in [(2, 8291, 0), (1, 8292, 0), (1, 8291, 2), (1, 8291, 1)] {
        let bad = format!(
            "0x{}{}{}{}",
            Uint256::from_u64(version).abi(),
            Uint256::ZERO.abi(),
            Uint256::from_u64(until).abi(),
            Uint256::from_u64(expired).abi()
        );
        assert!(decode_outcome_recovery(&bad, &c).is_err());
    }
}
#[test]
fn expiry_calldata_requires_bound_round_and_original_target() {
    assert!(encode_action(Action::ExpireOutcome, Uint256::from_u64(1), &[]).is_err());
    assert!(encode_action(
        Action::ExpireOutcome,
        Uint256::from_u64(1),
        &["3".into(), "100".into()]
    )
    .is_err());
    assert!(encode_action(
        Action::ExpireOutcome,
        Uint256::from_u64(1),
        &["1".into(), "0".into()]
    )
    .is_err());
    let data = encode_action(
        Action::ExpireOutcome,
        Uint256::from_u64(1),
        &["1".into(), "100".into()],
    )
    .unwrap();
    assert_eq!(data.len(), 202);
    assert!(data.ends_with(&Uint256::from_u64(100).abi()));
}
