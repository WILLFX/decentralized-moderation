//! Exact display conversion. Token identity still comes from the deployment pin.
use swarm_core::{moderator::Uint256, Display};

pub(crate) fn decimal(value: Uint256, decimals: u8) -> String {
    let raw = value.to_decimal();
    if decimals == 0 {
        return raw;
    }
    let padded = format!("{:0>width$}", raw, width = decimals as usize + 1);
    let (whole, fraction) = padded.split_at(padded.len() - decimals as usize);
    let fraction = fraction.trim_end_matches('0');
    if fraction.is_empty() {
        whole.into()
    } else {
        format!("{whole}.{fraction}")
    }
}
pub(crate) fn describe(value: Uint256, display: Option<&Display>) -> String {
    match display {
        Some(d) => format!(
            "{} {} ({} base units)",
            decimal(value, d.decimals),
            d.symbol,
            value
        ),
        None => format!("{value} token base units"),
    }
}
pub(crate) fn parse(raw: &str, display: Option<&Display>) -> Result<Uint256, &'static str> {
    let raw = raw.trim();
    if raw.is_empty() || raw.len() > 200 {
        return Err("INVALID_FEE_AMOUNT");
    }
    let decimals = display.map(|d| d.decimals as usize).unwrap_or(0);
    let mut parts = raw.split('.');
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next().unwrap_or("");
    if parts.next().is_some()
        || (whole.is_empty() && fraction.is_empty())
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || !fraction.bytes().all(|b| b.is_ascii_digit())
        || fraction.len() > decimals
        || (decimals == 0 && raw.contains('.'))
    {
        return Err("INVALID_FEE_AMOUNT");
    }
    let scaled = format!(
        "{whole}{fraction}{:0<width$}",
        "",
        width = decimals - fraction.len()
    );
    let scaled = scaled.trim_start_matches('0');
    swarm_core::publisher::fee(if scaled.is_empty() { "0" } else { scaled })
        .map_err(|_| "FEE_OVERFLOW")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn display(decimals: u8) -> Display {
        Display {
            decimals,
            symbol: "TEST".into(),
        }
    }
    #[test]
    fn fee_conversion_uses_sixteen_decimals_without_rounding() {
        let d = display(16);
        let n = Uint256::decimal("100000000000000").unwrap();
        assert_eq!(parse("0.01", Some(&d)).unwrap(), n);
        assert_eq!(
            describe(n, Some(&d)),
            "0.01 TEST (100000000000000 base units)"
        );
        assert_eq!(
            parse("0.0000000000000001", Some(&d)).unwrap(),
            Uint256::from_u64(1)
        );
        for raw in ["0.00000000000000001", "1e-2", "-1", "1,000", "NaN", "1.2.3"] {
            assert!(parse(raw, Some(&d)).is_err(), "{raw}");
        }
    }
    #[test]
    fn full_width_format_and_uint128_fee_limit_stay_exact() {
        let max = Uint256::hex(&format!("0x{}", "ff".repeat(32))).unwrap();
        assert_eq!(
            decimal(max, 18),
            "115792089237316195423570985008687907853269984665640564039457.584007913129639935"
        );
        let d = display(16);
        let max_fee = Uint256::decimal("340282366920938463463374607431768211455").unwrap();
        assert_eq!(parse(&decimal(max_fee, 16), Some(&d)).unwrap(), max_fee);
        assert!(parse("34028236692093846346337.4607431768211456", Some(&d)).is_err());
    }
    #[test]
    fn missing_display_never_assumes_decimal_places() {
        assert_eq!(parse("10", None).unwrap(), Uint256::from_u64(10));
        assert!(parse("0.01", None).is_err());
        assert_eq!(describe(Uint256::from_u64(10), None), "10 token base units");
        assert_eq!(decimal(Uint256::ZERO, 36), "0");
    }
}
