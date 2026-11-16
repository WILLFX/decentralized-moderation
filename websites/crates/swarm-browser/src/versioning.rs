//! Deployment identity and authority reads at the caller's existing block pin.
use crate::{
    transport::{as_str, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use std::future::Future;
use swarm_core::{
    moderator::{CaseInfo, Uint256},
    versioning as core, Deployment, ModeratorProfile,
};

async fn call(
    p: &ModeratorProfile,
    pin: &Value,
    target: &str,
    sig: &str,
    args: &str,
) -> Result<String> {
    Ok(as_str(
        &rpc(
            p,
            "eth_call",
            json!([{"to":target,
        "data":format!("{}{}",swarm_core::selector(sig),args)},pin]),
        )
        .await?,
    )?
    .into())
}
/// The caller owns block selection, cancellation and the final canonical recheck.
/// Only semantic failures use the supplied mapping; read/response errors pass through.
pub(crate) async fn verify_deployment<F, Fut>(
    deployment: &Deployment,
    pin: &Value,
    read: F,
    max_runtime_length: Option<usize>,
    validation_error: impl Fn(&'static str, &'static str) -> &'static str,
) -> Result<()>
where
    F: Fn(&'static str, Value) -> Fut,
    Fut: Future<Output = Result<Value>>,
{
    let call = |to: &str, signature: &str, args: &str| {
        read(
            "eth_call",
            json!([{"to":to,"data":format!("{}{}",swarm_core::selector(signature),args)},pin]),
        )
    };
    for contract in core::runtime_pins(deployment) {
        let raw = read("eth_getCode", json!([contract.address, pin])).await?;
        let code = as_str(&raw)?;
        if max_runtime_length.is_some_and(|limit| code.len() > limit) {
            return Err("INVALID_RUNTIME_LENGTH");
        }
        swarm_core::verify_runtime(contract, code)
            .map_err(|e| validation_error(e.0, "DEPLOYMENT_RUNTIME_MISMATCH"))?;
    }
    for link in swarm_core::link_checks(deployment) {
        let raw = call(&link.contract_address, link.signature, "").await?;
        swarm_core::verify_link(&link, as_str(&raw)?)
            .map_err(|e| validation_error(e.0, "DEPLOYMENT_LINK_MISMATCH"))?;
    }
    let version = call(&deployment.moderation.address, "guidelinesVersion()", "").await?;
    let version = as_str(&version)?;
    let hash = call(&deployment.moderation.address, "guidelinesHash()", "").await?;
    swarm_core::verify_guidelines(deployment, version, as_str(&hash)?)
        .map_err(|e| validation_error(e.0, "DEPLOYMENT_GUIDELINES_MISMATCH"))?;
    for check in core::word_checks(deployment).map_err(|e| e.0)? {
        let raw = call(&check.contract, check.signature, &check.args).await?;
        core::verify_word(&check, as_str(&raw)?).map_err(|e| e.0)?;
    }
    Ok(())
}
pub(crate) async fn case(
    p: &ModeratorProfile,
    pin: &Value,
    id: Uint256,
    c: &CaseInfo,
) -> Result<Option<String>> {
    let Some(family) = &p.deployment.persistent else {
        return Ok(None);
    };
    let args = core::registration_args(&p.deployment.moderation.address, id).map_err(|e| e.0)?;
    let raw = call(
        p,
        pin,
        &family.authority.address,
        "registration(address,uint256)",
        &args,
    )
    .await?;
    core::verify_registration(&p.deployment, c, &raw).map_err(|e| e.0)
}
pub(crate) async fn active_address(p: &ModeratorProfile, pin: &Value) -> Result<Option<String>> {
    let Some(family) = &p.deployment.persistent else {
        return Ok(None);
    };
    let raw = call(p, pin, &family.authority.address, "active()", "").await?;
    Ok(Some(swarm_core::decode_address(&raw).map_err(|e| e.0)?))
}
pub(crate) async fn require_active(p: &ModeratorProfile, pin: &Value) -> Result<()> {
    p.purpose.check_publication("submit").map_err(|e| e.0)?;
    if let Some(active) = active_address(p, pin).await? {
        if !active.eq_ignore_ascii_case(&p.deployment.moderation.address) {
            return Err("VERSION_CLOSED_TO_SUBMISSIONS");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        future::ready,
        task::{Context, Poll, Waker},
    };
    use swarm_core::{ContractPin, Guidelines};

    type Step = (&'static str, Value, Result<Value>);

    fn deployment(persistent: bool) -> Deployment {
        let pin = |n| ContractPin {
            address: format!("0x{n:040x}"),
            code_hash: swarm_core::keccak256_hex(&[0x60, 0]),
        };
        let mut d = Deployment {
            chain_id: 10200,
            moderation: pin(1),
            stakes: pin(2),
            index: pin(3),
            token: pin(4),
            guidelines: Guidelines {
                version: 1,
                hash: format!("0x{}", "ab".repeat(32)),
            },
            persistent: None,
        };
        if persistent {
            d.persistent = Some(core::PersistentDeployment {
                authority: pin(5),
                versions: vec![core::VersionPin {
                    moderation: d.moderation.clone(),
                    guidelines: d.guidelines.clone(),
                    rules_hash: format!("0x{}", "cd".repeat(32)),
                    guidelines_url: "./MODERATION_GUIDELINES.md".into(),
                }],
            });
        }
        d
    }
    fn pin() -> Value {
        json!({"blockHash":format!("0x{}", "AB".repeat(32)),"requireCanonical":true})
    }
    fn script(d: &Deployment) -> Vec<Step> {
        let pin = pin();
        let mut steps = core::runtime_pins(d)
            .into_iter()
            .map(|p| ("eth_getCode", json!([p.address, pin]), Ok(json!("0x6000"))))
            .collect::<Vec<_>>();
        let mut call = |to: &str, sig: &str, args: &str, value: Value| {
            steps.push((
                "eth_call",
                json!([{"to":to,"data":format!("{}{}",swarm_core::selector(sig),args)},pin]),
                Ok(value),
            ));
        };
        for link in swarm_core::link_checks(d) {
            call(
                &link.contract_address,
                link.signature,
                "",
                json!(format!("0x{:0>64}", &link.expected_address[2..])),
            );
        }
        call(
            &d.moderation.address,
            "guidelinesVersion()",
            "",
            json!(format!("0x{:064x}", d.guidelines.version)),
        );
        call(
            &d.moderation.address,
            "guidelinesHash()",
            "",
            json!(d.guidelines.hash),
        );
        for check in core::word_checks(d).unwrap() {
            call(
                &check.contract,
                check.signature,
                &check.args,
                json!(check.expected),
            );
        }
        steps
    }
    fn run(
        d: &Deployment,
        steps: &[Step],
        limit: Option<usize>,
        setup: bool,
    ) -> (Result<()>, usize) {
        let count = Cell::new(0);
        let read = |method, params| {
            let i = count.get();
            count.set(i + 1);
            let (expected_method, expected_params, response) = &steps[i];
            assert_eq!(method, *expected_method, "request {i}");
            assert_eq!(params, *expected_params, "request {i}");
            ready(response.clone())
        };
        let pin = pin();
        let mut future = Box::pin(verify_deployment(d, &pin, read, limit, |raw, mapped| {
            if setup {
                mapped
            } else {
                raw
            }
        }));
        let Poll::Ready(result) = future
            .as_mut()
            .poll(&mut Context::from_waker(Waker::noop()))
        else {
            panic!("scripted reads must complete without a browser executor")
        };
        (result, count.get())
    }

    #[test]
    fn selected_deployment_checks_keep_one_pin_and_order_for_both_families() {
        for persistent in [false, true] {
            let d = deployment(persistent);
            let steps = script(&d);
            assert_eq!(steps.len(), if persistent { 20 } else { 12 });
            for setup in [false, true] {
                assert_eq!(run(&d, &steps, None, setup), (Ok(()), steps.len()));
            }
        }
    }
    #[test]
    fn semantic_failures_stop_at_the_same_stage_and_only_setup_maps_them() {
        let d = deployment(true);
        let zero = format!("0x{}", "00".repeat(32));
        let wrong_version = format!("0x{:064x}", 2);
        // Persistent reads: runtime 0..5, links 5..15, guidelines 15..17, authority 17..20.
        for (at, calls, mapped, responses) in [
            (
                0,
                1,
                "DEPLOYMENT_RUNTIME_MISMATCH",
                vec![("0x6001", "DEPLOYMENT_MISMATCH_RUNTIME")],
            ),
            (
                5,
                6,
                "DEPLOYMENT_LINK_MISMATCH",
                vec![
                    (zero.as_str(), "DEPLOYMENT_MISMATCH_LINK"),
                    ("0x01", "INVALID_ABI_RESULT"),
                ],
            ),
            (
                15,
                17,
                "DEPLOYMENT_GUIDELINES_MISMATCH",
                vec![
                    (wrong_version.as_str(), "DEPLOYMENT_MISMATCH_GUIDELINES"),
                    ("0x01", "INVALID_ABI_RESULT"),
                ],
            ),
            (
                17,
                18,
                "DEPLOYMENT_VERSION_MISMATCH",
                vec![(zero.as_str(), "DEPLOYMENT_VERSION_MISMATCH")],
            ),
        ] {
            for (value, raw) in responses {
                let mut steps = script(&d);
                steps[at].2 = Ok(json!(value));
                for setup in [false, true] {
                    assert_eq!(
                        run(&d, &steps, None, setup),
                        (Err(if setup { mapped } else { raw }), calls)
                    );
                }
            }
        }
    }
    #[test]
    fn read_and_nonstring_errors_pass_through_at_each_conversion_stage() {
        let d = deployment(true);
        let original = script(&d);
        for at in [0, 5, 15, 16, 17] {
            for (reply, expected) in [
                (Err("RPC_READ_FAILED"), "RPC_READ_FAILED"),
                (Ok(json!({})), "INVALID_RPC_RESULT"),
            ] {
                let mut steps = original.clone();
                steps[at].2 = reply;
                assert_eq!(run(&d, &steps, None, true), (Err(expected), at + 1));
            }
        }
    }
    #[test]
    fn guideline_hash_read_failure_precedes_version_semantics() {
        let d = deployment(true);
        let mut steps = script(&d);
        steps[15].2 = Ok(json!("0x01"));
        steps[16].2 = Err("RPC_READ_FAILED");
        assert_eq!(run(&d, &steps, None, true), (Err("RPC_READ_FAILED"), 17));
    }
    #[test]
    fn runtime_limit_is_optional_and_checked_before_runtime_semantics() {
        for (byte_count, limit, expected) in [
            (65_536, Some(131_074), Ok(())),
            (65_537, Some(131_074), Err("INVALID_RUNTIME_LENGTH")),
            (65_537, None, Ok(())),
        ] {
            let bytes = vec![0x60; byte_count];
            let mut d = deployment(false);
            d.moderation.code_hash = swarm_core::keccak256_hex(&bytes);
            let mut steps = script(&d);
            steps[0].2 = Ok(json!(format!("0x{}", hex::encode(&bytes))));
            let calls = if expected.is_ok() { steps.len() } else { 1 };
            assert_eq!(run(&d, &steps, limit, false), (expected, calls));
        }
        let d = deployment(false);
        let mut steps = script(&d);
        steps[0].2 = Ok(json!(format!("0x{}", "0".repeat(131_073))));
        assert_eq!(
            run(&d, &steps, Some(131_074), true),
            (Err("INVALID_RUNTIME_LENGTH"), 1)
        );
        assert_eq!(
            run(&d, &steps, None, true),
            (Err("DEPLOYMENT_RUNTIME_MISMATCH"), 1)
        );
    }
}
