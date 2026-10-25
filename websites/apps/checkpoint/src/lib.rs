use flate2::read::GzDecoder;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const MAX_STATE: usize = 512 * 1024 * 1024;
const MAX_FILE: u64 = 513 * 1024 * 1024;
const MAX_EXPANDED_STATE: usize = 1024 * 1024 * 1024;
fn require(ok: bool, code: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(code.into())
    }
}
#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    #[serde(default)]
    kind: String,
    #[serde(default)]
    source_run: String,
    #[serde(default)]
    deployment: Value,
    #[serde(default)]
    fingerprint: Value,
    #[serde(default)]
    state: String,
    #[serde(default)]
    state_sha256: String,
    #[serde(default)]
    created_at: Value,
    #[serde(default)]
    version: Value,
    #[serde(default)]
    endpoint: Value,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub run: Option<PathBuf>,
    pub deployment: Option<Value>,
    pub input: Option<PathBuf>,
    pub target: Option<PathBuf>,
    pub raw_target: Option<PathBuf>,
    pub fingerprint: Option<Value>,
    pub state_sha256: Option<String>,
    pub created_at: Option<String>,
    pub version: Option<String>,
    pub endpoint: Option<String>,
}
impl Config {
    fn run(&self) -> Result<&Path> {
        self.run.as_deref().ok_or("RUN_REQUIRED".into())
    }
    fn input(&self) -> Result<&Path> {
        self.input.as_deref().ok_or("INPUT_REQUIRED".into())
    }
    fn target(&self) -> Result<&Path> {
        self.target.as_deref().ok_or("TARGET_REQUIRED".into())
    }
    fn deployment(&self) -> Result<&Value> {
        self.deployment.as_ref().ok_or("DEPLOYMENT_REQUIRED".into())
    }
}
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    require(
        !fs::symlink_metadata(path)?.file_type().is_symlink(),
        "SYMLINK_INPUT",
    )?;
    let file = File::open(path)?;
    let before = file.metadata()?;
    require(
        before.is_file() && before.len() > 0 && before.len() <= MAX_FILE,
        "CHECKPOINT_FILE_SIZE_LIMIT",
    )?;
    let mut decoder = serde_json::Deserializer::from_reader(BufReader::with_capacity(
        64 * 1024,
        (&file).take(MAX_FILE + 1),
    ));
    let result = T::deserialize(&mut decoder)?;
    decoder.end()?;
    let after = file.metadata()?;
    require(
        before.len() == after.len() && before.modified()? == after.modified()?,
        "INPUT_CHANGED",
    )?;
    Ok(result)
}
fn amount(v: &Value) -> Result<u64> {
    if let Some(n) = v.as_u64() {
        return Ok(n);
    }
    let s = v.as_str().ok_or("INVALID_BLOCK_QUANTITY")?;
    Ok(
        if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            u64::from_str_radix(hex, 16)?
        } else {
            s.parse()?
        },
    )
}
fn portable(path: &str) -> String {
    let s = path.replace('\\', "/");
    let b = s.as_bytes();
    if b.len() >= 3 && b[0].is_ascii_alphabetic() && &b[1..3] == b":/" {
        format!("/mnt/{}/{}", (b[0] as char).to_ascii_lowercase(), &s[3..])
    } else {
        s
    }
}
fn hash(state: &str) -> String {
    hex::encode(Sha256::digest(state.as_bytes()))
}
fn valid_hex(state: &str) -> Result<()> {
    require(
        state.len() >= 4 && state.len() <= MAX_STATE && state.len() % 2 == 0,
        "CHECKPOINT_STATE_LENGTH",
    )?;
    require(
        state
            .as_bytes()
            .get(..2)
            .is_some_and(|p| p.eq_ignore_ascii_case(b"0x"))
            && state.as_bytes()[2..].iter().all(u8::is_ascii_hexdigit),
        "CHECKPOINT_STATE_HEX",
    )
}
fn envelope(s: &Snapshot, config: &Config) -> Result<()> {
    require(
        s.kind == "local-moderation-checkpoint",
        "CHECKPOINT_KIND_MISMATCH",
    )?;
    require(
        &s.deployment == config.deployment()?,
        "CHECKPOINT_DEPLOYMENT_MISMATCH",
    )?;
    require(
        portable(&s.source_run) == portable(&config.run()?.to_string_lossy()),
        "CHECKPOINT_SOURCE_RUN_MISMATCH",
    )?;
    valid_hex(&s.state)?;
    require(
        hash(&s.state) == s.state_sha256,
        "CHECKPOINT_STATE_HASH_MISMATCH",
    )
}
struct HexReader<'a> {
    bytes: &'a [u8],
    at: usize,
}
impl Read for HexReader<'_> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let count = out.len().min((self.bytes.len() - self.at) / 2);
        for byte in out.iter_mut().take(count) {
            let value = |b: u8| {
                if b <= b'9' {
                    b - b'0'
                } else {
                    b.to_ascii_lowercase() - b'a' + 10
                }
            };
            *byte = value(self.bytes[self.at]) * 16 + value(self.bytes[self.at + 1]);
            self.at += 2;
        }
        Ok(count)
    }
}
// Serde skips accounts, transaction and block-history contents without building
// their object graphs. Only the current block's two scalar fields are retained.
#[derive(Deserialize)]
struct History {
    accounts: Option<serde::de::IgnoredAny>,
    blocks: Option<serde::de::IgnoredAny>,
    transactions: Option<serde::de::IgnoredAny>,
    block: Block,
}
#[derive(Deserialize, Serialize)]
struct Block {
    number: Value,
    timestamp: Value,
}
struct Limited<R> {
    inner: R,
    count: usize,
    limit: usize,
}
impl<R: Read> Read for Limited<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(out)?;
        self.count = self
            .count
            .checked_add(n)
            .ok_or_else(|| io::Error::other("STATE_SIZE_LIMIT"))?;
        if self.count > self.limit {
            return Err(io::Error::other("STATE_EXPANDED_SIZE_LIMIT"));
        }
        Ok(n)
    }
}
fn state_header(state: &str) -> Result<Block> {
    valid_hex(state)?;
    let hex = HexReader {
        bytes: &state.as_bytes()[2..],
        at: 0,
    };
    let mut gzip = flate2::bufread::GzDecoder::new(BufReader::new(hex));
    let header = history_header(&mut gzip)?;
    // GzDecoder checks CRC and length while the JSON deserializer drains EOF.
    // Reject concatenated streams or trailing bytes beyond this gzip member.
    let hex = gzip.into_inner();
    require(
        hex.buffer().is_empty() && hex.get_ref().at == hex.get_ref().bytes.len(),
        "TRAILING_COMPRESSED_DATA",
    )?;
    Ok(header)
}
fn history_header(reader: impl Read) -> Result<Block> {
    let bounded = Limited {
        inner: reader,
        count: 0,
        limit: MAX_EXPANDED_STATE,
    };
    let mut decoder =
        serde_json::Deserializer::from_reader(BufReader::with_capacity(64 * 1024, bounded));
    let history = History::deserialize(&mut decoder)?;
    decoder.end()?;
    require(
        history.accounts.is_some() && history.blocks.is_some() && history.transactions.is_some(),
        "CHECKPOINT_HISTORY_REQUIRED",
    )?;
    amount(&history.block.number)?;
    amount(&history.block.timestamp)?;
    Ok(history.block)
}
fn verify_head(block: &Block, fingerprint: &Value) -> Result<()> {
    require(
        amount(&block.number)? == amount(&fingerprint["head"]["number"])?,
        "CHECKPOINT_EXPORTED_NUMBER_MISMATCH",
    )?;
    require(
        amount(&block.timestamp)? == amount(&fingerprint["head"]["timestamp"])?,
        "CHECKPOINT_EXPORTED_TIME_MISMATCH",
    )
}
fn metadata(s: &Snapshot) -> Value {
    json!({"kind":s.kind,"sourceRun":s.source_run,"deployment":s.deployment,"fingerprint":s.fingerprint,
        "stateSha256":s.state_sha256,"createdAt":s.created_at,"version":s.version,"endpoint":s.endpoint})
}
fn verify(s: &Snapshot, c: &Config) -> Result<Block> {
    envelope(s, c)?;
    let header = state_header(&s.state)?;
    verify_head(&header, &s.fingerprint)?;
    Ok(header)
}
fn private_file(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}
struct CheckedWriter {
    file: File,
    hash: Sha256,
}
impl Write for CheckedWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let n = self.file.write(bytes)?;
        self.hash.update(&bytes[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}
fn file_hash(path: &Path) -> Result<Vec<u8>> {
    let mut file = BufReader::new(File::open(path)?);
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
    }
    Ok(digest.finalize().to_vec())
}
fn atomic_write(
    target: &Path,
    write: impl FnOnce(&mut BufWriter<CheckedWriter>) -> Result<()>,
) -> Result<()> {
    require(
        target.parent().is_some_and(Path::is_dir),
        "TARGET_PARENT_REQUIRED",
    )?;
    if let Ok(meta) = fs::symlink_metadata(target) {
        require(
            meta.is_file() && !meta.file_type().is_symlink(),
            "UNSAFE_TARGET",
        )?;
    }
    let temp = target.with_file_name(format!(
        ".{}.{}.tmp",
        target
            .file_name()
            .ok_or("INVALID_TARGET")?
            .to_string_lossy(),
        std::process::id()
    ));
    let file = private_file(&temp)?;
    let result = (|| {
        let mut writer = BufWriter::with_capacity(
            64 * 1024,
            CheckedWriter {
                file,
                hash: Sha256::new(),
            },
        );
        write(&mut writer)?;
        writer.flush()?;
        writer.get_ref().file.sync_all()?;
        let expected = writer.get_ref().hash.clone().finalize().to_vec();
        drop(writer);
        require(
            file_hash(&temp)? == expected,
            "CHECKPOINT_WRITE_READBACK_MISMATCH",
        )?;
        fs::rename(&temp, target)?;
        #[cfg(unix)]
        {
            // DrvFS may not support directory fsync. File fsync and readback
            // remain mandatory; other directory I/O failures are reported.
            if let Err(error) = File::open(target.parent().unwrap())?.sync_all() {
                if !matches!(
                    error.kind(),
                    io::ErrorKind::InvalidInput | io::ErrorKind::Unsupported
                ) {
                    return Err(error.into());
                }
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
fn write_snapshot(target: &Path, s: &Snapshot) -> Result<()> {
    atomic_write(target, |w| {
        serde_json::to_writer_pretty(&mut *w, s)?;
        w.write_all(b"\n")?;
        Ok(())
    })
}
#[derive(Deserialize)]
struct RpcDump {
    jsonrpc: String,
    id: Value,
    result: String,
}
fn dump(c: &Config) -> Result<String> {
    let reply: RpcDump = read_json(c.input()?)?;
    require(
        reply.jsonrpc == "2.0" && reply.id == json!(1),
        "DUMP_RPC_CONTEXT",
    )?;
    valid_hex(&reply.result)?;
    Ok(reply.result)
}
fn scan_paths(run: &Path) -> Result<Vec<PathBuf>> {
    let mut dirs = vec![run.join("checkpoints")];
    for entry in fs::read_dir(run)? {
        let entry = entry?;
        if entry.file_type()?.is_dir()
            && entry.file_name().to_string_lossy().starts_with("recovery-")
        {
            dirs.push(entry.path().join("checkpoints"));
        }
    }
    let mut paths = Vec::new();
    for dir in dirs {
        if !dir.exists() {
            continue;
        }
        require(
            !fs::symlink_metadata(&dir)?.file_type().is_symlink(),
            "SYMLINK_CHECKPOINT_DIRECTORY",
        )?;
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name == "current-moderation.json"
                || name == "settled-moderation.json"
                || name.starts_with("moderation-")
                    && name.ends_with(".json")
                    && !name.ends_with("-verification.json")
            {
                paths.push(entry.path());
            }
        }
    }
    paths.sort();
    Ok(paths)
}
#[derive(Deserialize)]
struct ScanSnapshot {
    #[serde(default)]
    kind: String,
    #[serde(default)]
    fingerprint: Value,
}
fn select(c: &Config) -> Result<Value> {
    let mut selected: Option<(PathBuf, u64, String)> = None;
    let mut divergent = false;
    for path in scan_paths(c.run()?)? {
        let s: ScanSnapshot = read_json(&path)?;
        if s.kind != "local-moderation-checkpoint" {
            continue;
        }
        let number = amount(&s.fingerprint["head"]["number"])?;
        let head = s.fingerprint["head"]["hash"]
            .as_str()
            .ok_or("HEAD_HASH_REQUIRED")?
            .to_owned();
        match &selected {
            None => selected = Some((path, number, head)),
            Some((_, n, _)) if number > *n => {
                selected = Some((path, number, head));
                divergent = false;
            }
            Some((_, n, hash)) if number == *n && head != *hash => divergent = true,
            Some((_, n, _))
                if number == *n && path.file_name().unwrap() == "settled-moderation.json" =>
            {
                selected = Some((path, number, head))
            }
            _ => {}
        }
    }
    require(
        !divergent,
        "DIVERGENT_CHECKPOINTS_REQUIRE_EXPLICIT_SELECTION",
    )?;
    let (path, number, head) = selected.ok_or("NO_SAVED_CHECKPOINT")?;
    let s: Snapshot = read_json(&path)?;
    require(
        amount(&s.fingerprint["head"]["number"])? == number
            && s.fingerprint["head"]["hash"] == head,
        "CHECKPOINT_CHANGED_DURING_SELECTION",
    )?;
    verify(&s, c)?;
    Ok(
        json!({"snapshotPath":path,"number":number.to_string(),"headHash":head,"snapshot":metadata(&s),"engine":"native-rust"}),
    )
}
pub fn execute(command: &str, c: &Config) -> Result<Value> {
    match command {
        "limits" => Ok(
            json!({"maxStateHexBytes":MAX_STATE,"maxFileBytes":MAX_FILE,"maxExpandedBytes":MAX_EXPANDED_STATE}),
        ),
        "select" => select(c),
        "verify" => {
            let s: Snapshot = read_json(c.input()?)?;
            verify(&s, c)?;
            Ok(metadata(&s))
        }
        "restore" => {
            let s: Snapshot = read_json(c.input()?)?;
            verify(&s, c)?;
            let raw = c.raw_target.as_deref().ok_or("RAW_TARGET_REQUIRED")?;
            require(
                !raw.exists() && !c.target()?.exists(),
                "RESTORE_TARGET_ALREADY_EXISTS",
            )?;
            atomic_write(raw, |w| {
                let hex = HexReader {
                    bytes: &s.state.as_bytes()[2..],
                    at: 0,
                };
                let mut decoder = GzDecoder::new(hex);
                io::copy(&mut decoder, w)?;
                Ok(())
            })?;
            write_snapshot(c.target()?, &s)?;
            Ok(
                json!({"snapshot":metadata(&s),"rawHead":state_header(&s.state)?,"engine":"native-rust"}),
            )
        }
        "header" => {
            let file = File::open(c.input()?)?;
            require(
                file.metadata()?.len() <= MAX_EXPANDED_STATE as u64,
                "STATE_SIZE_LIMIT",
            )?;
            Ok(serde_json::to_value(history_header(file)?)?)
        }
        "inspect-export" => {
            let state = dump(c)?;
            let head = state_header(&state)?;
            Ok(json!({"block":head,"stateSha256":hash(&state),"engine":"native-rust"}))
        }
        "pack" => {
            let state = dump(c)?;
            require(
                Some(hash(&state)).as_ref() == c.state_sha256.as_ref(),
                "EXPORT_CHANGED_BEFORE_PACK",
            )?;
            let s = Snapshot {
                kind: "local-moderation-checkpoint".into(),
                source_run: c.run()?.to_string_lossy().into(),
                deployment: c.deployment()?.clone(),
                fingerprint: c.fingerprint.clone().ok_or("FINGERPRINT_REQUIRED")?,
                state,
                state_sha256: c.state_sha256.clone().unwrap(),
                created_at: json!(c.created_at),
                version: json!(c.version),
                endpoint: json!(c.endpoint),
            };
            verify(&s, c)?;
            write_snapshot(c.target()?, &s)?;
            Ok(
                json!({"head":s.fingerprint["head"],"savedAt":s.created_at,"checkpoint":c.target()?,"engine":"native-rust"}),
            )
        }
        _ => Err("UNKNOWN_CHECKPOINT_COMMAND".into()),
    }
}
pub fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["version"] {
        println!("swarm-checkpoint/1");
        return Ok(());
    }
    require(args.len() == 2, "CHECKPOINT_ARGUMENTS_REQUIRED")?;
    require(args[1].len() <= 64 * 1024, "CONFIG_SIZE_LIMIT")?;
    let c: Config = serde_json::from_str(&args[1])?;
    let mut result = execute(&args[0], &c)?;
    if let Some(object) = result.as_object_mut() {
        object.insert("engine".into(), json!("native-rust"));
        let peak = std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|text| {
                text.lines()
                    .find(|line| line.starts_with("VmHWM:"))
                    .and_then(|line| line.split_whitespace().nth(1))
                    .and_then(|v| v.parse::<u64>().ok())
            });
        object.insert("selectionPeakRssKiB".into(), json!(peak));
    }
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::GzEncoder, Compression};
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    fn state(v: Value) -> String {
        let mut gzip = GzEncoder::new(Vec::new(), Compression::fast());
        serde_json::to_writer(&mut gzip, &v).unwrap();
        format!("0x{}", hex::encode(gzip.finish().unwrap()))
    }
    fn raw() -> Value {
        json!({"accounts":{},"blocks":[],"transactions":[],"block":{"number":"0xc","timestamp":"0x78"}})
    }
    fn workspace() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "rust-checkpoint-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(p.join("checkpoints")).unwrap();
        p
    }
    fn config(run: &Path) -> Config {
        serde_json::from_value(json!({"run":run,"deployment":{"chainId":"10200"}})).unwrap()
    }
    fn snap(run: &Path, n: u64, h: &str) -> Snapshot {
        let mut v = raw();
        v["block"]["number"] = json!(n);
        let state = state(v);
        Snapshot {
            kind: "local-moderation-checkpoint".into(),
            source_run: run.to_string_lossy().into(),
            deployment: json!({"chainId":"10200"}),
            fingerprint: json!({"head":{"number":format!("0x{n:x}"),"timestamp":"0x78","hash":h}}),
            state_sha256: hash(&state),
            state,
            ..Default::default()
        }
    }
    fn put(path: &Path, s: &Snapshot) {
        serde_json::to_writer(File::create(path).unwrap(), s).unwrap();
    }
    #[test]
    fn validate_original_state_without_retaining_history() {
        let s = state(raw());
        let b = state_header(&s).unwrap();
        assert_eq!(amount(&b.number).unwrap(), 12);
    }
    #[test]
    fn malformed_hex_and_unicode_fail_without_panicking() {
        for s in ["0xgg", "😀ab", "0x0", "00ab"] {
            assert!(state_header(s).is_err());
        }
    }
    #[test]
    fn crc_truncation_and_trailing_gzip_are_rejected() {
        let good = state(raw());
        assert!(state_header(&good[..good.len() - 4]).is_err());
        let mut bytes = hex::decode(&good[2..]).unwrap();
        let n = bytes.len();
        bytes[n - 8] ^= 1;
        assert!(state_header(&format!("0x{}", hex::encode(bytes))).is_err());
        assert!(state_header(&(good.clone() + "0000")).is_err());
        assert!(state_header(&(good.clone() + &good[2..])).is_err());
    }
    #[test]
    fn required_history_and_trailing_json_are_checked() {
        let mut v = raw();
        v.as_object_mut().unwrap().remove("accounts");
        assert!(state_header(&state(v)).is_err());
        let mut v = raw();
        v["transactions"] = Value::Null;
        assert!(state_header(&state(v)).is_err());
    }
    #[test]
    fn deployment_source_hash_and_exported_head_are_checked() {
        let run = workspace();
        let c = config(&run);
        let mut s = snap(&run, 12, "original");
        assert!(verify(&s, &c).is_ok());
        s.state_sha256 = "changed".into();
        assert!(verify(&s, &c).is_err());
        s.state_sha256 = hash(&s.state);
        s.fingerprint["head"]["timestamp"] = json!(121);
        assert!(verify(&s, &c).is_err());
        s.fingerprint["head"]["timestamp"] = json!(120);
        s.deployment["chainId"] = json!(1);
        assert!(verify(&s, &c).is_err());
        s.deployment = c.deployment.clone().unwrap();
        s.source_run = "wrong".into();
        assert!(verify(&s, &c).is_err());
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn portable_windows_and_wsl_paths_match_exact_run() {
        assert_eq!(portable("C:\\Users\\test\\run"), "/mnt/c/Users/test/run");
        assert_ne!(
            portable("C:\\Users\\other\\run"),
            portable("/mnt/c/Users/test/run")
        );
    }
    #[test]
    fn select_newest_without_state_in_output() {
        let run = workspace();
        put(
            &run.join("checkpoints/moderation-old.json"),
            &snap(&run, 10, "old"),
        );
        put(
            &run.join("checkpoints/current-moderation.json"),
            &snap(&run, 12, "new"),
        );
        let result = select(&config(&run)).unwrap();
        assert_eq!(result["number"], "12");
        assert!(result["snapshot"].get("state").is_none());
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn corrupt_newest_never_falls_back() {
        let run = workspace();
        put(
            &run.join("checkpoints/moderation-old.json"),
            &snap(&run, 10, "old"),
        );
        let mut s = snap(&run, 12, "new");
        s.state_sha256 = "corrupt".into();
        put(&run.join("checkpoints/current-moderation.json"), &s);
        assert!(select(&config(&run)).is_err());
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn same_height_fork_requires_explicit_selection() {
        let run = workspace();
        put(
            &run.join("checkpoints/moderation-a.json"),
            &snap(&run, 12, "a"),
        );
        put(
            &run.join("checkpoints/moderation-b.json"),
            &snap(&run, 12, "b"),
        );
        assert!(select(&config(&run)).is_err());
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn temporary_files_never_enter_selection() {
        let run = workspace();
        put(
            &run.join("checkpoints/current-moderation.json"),
            &snap(&run, 12, "a"),
        );
        fs::write(
            run.join("checkpoints/current-moderation.json.tmp"),
            "invalid",
        )
        .unwrap();
        assert_eq!(select(&config(&run)).unwrap()["number"], "12");
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn corrupt_pack_preserves_previous_checkpoint() {
        let run = workspace();
        let input = run.join("dump.json");
        fs::write(&input, "invalid").unwrap();
        let target = run.join("checkpoints/current-moderation.json");
        fs::write(&target, "previous").unwrap();
        let c: Config = serde_json::from_value(
            json!({"run":run,"input":input,"target":target,"deployment":{}}),
        )
        .unwrap();
        assert!(execute("pack", &c).is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "previous");
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn large_history_fields_are_skipped() {
        let mut v = raw();
        v["transactions"] = json!([{"input":"f".repeat(4*1024*1024)}]);
        assert_eq!(
            amount(&state_header(&state(v)).unwrap().number).unwrap(),
            12
        );
    }
    #[test]
    fn streamed_raw_header_matches_snapshot_header() {
        let text = serde_json::to_vec(&raw()).unwrap();
        assert_eq!(
            amount(&history_header(text.as_slice()).unwrap().timestamp).unwrap(),
            120
        );
    }
    #[test]
    fn invalid_raw_header_is_rejected() {
        assert!(history_header(b"{\"block\":{}}".as_slice()).is_err());
    }
    #[test]
    fn a_preexisting_temporary_file_is_never_deleted_or_overwritten() {
        let run = workspace();
        let target = run.join("checkpoint.json");
        let temp = run.join(format!(".checkpoint.json.{}.tmp", std::process::id()));
        fs::write(&temp, b"preserve unrelated existing temporary file").unwrap();
        assert!(write_snapshot(&target, &snap(&run, 12, "head")).is_err());
        assert_eq!(
            fs::read(&temp).unwrap(),
            b"preserve unrelated existing temporary file"
        );
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn config_rejects_unknown_fields() {
        assert!(serde_json::from_value::<Config>(json!({"force":true})).is_err());
    }
    #[test]
    #[cfg_attr(
        not(unix),
        ignore = "Requires Ubuntu: Windows sandbox denies atomic file replacement"
    )]
    fn atomic_pack_restore_and_readback_preserve_original() {
        let run = workspace();
        let input = run.join("dump.json");
        let original = snap(&run, 12, "0x1234");
        serde_json::to_writer(
            File::create(&input).unwrap(),
            &json!({"jsonrpc":"2.0","id":1,"result":original.state}),
        )
        .unwrap();
        let target = run.join("checkpoints/current-moderation.json");
        fs::write(&target, "old").unwrap();
        let c:Config=serde_json::from_value(json!({"run":run,"input":input,"target":target,"deployment":original.deployment,
            "fingerprint":original.fingerprint,"stateSha256":original.state_sha256,"createdAt":"now","version":"anvil","endpoint":"http://127.0.0.1:1"})).unwrap();
        execute("pack", &c).unwrap();
        let before = fs::read(&target).unwrap();
        let raw = run.join("restore.json");
        let copy = run.join("copy.json");
        let c:Config=serde_json::from_value(json!({"run":run,"input":target,"target":copy,"rawTarget":raw,"deployment":original.deployment})).unwrap();
        execute("restore", &c).unwrap();
        assert_eq!(fs::read(&target).unwrap(), before);
        let decoded: Value = read_json(&raw).unwrap();
        assert_eq!(amount(&decoded["block"]["number"]).unwrap(), 12);
        assert!(execute("restore", &c).is_err());
        fs::remove_dir_all(run).unwrap();
    }
}

#[cfg(test)]
mod limit_tests {
    use super::*;
    #[test]
    fn transport_and_native_limits_have_envelope_headroom() {
        let c: Config = serde_json::from_value(json!({})).unwrap();
        let limits = execute("limits", &c).unwrap();
        assert_eq!(limits["maxStateHexBytes"], 512_u64 * 1024 * 1024);
        assert_eq!(limits["maxFileBytes"], 513_u64 * 1024 * 1024);
        assert_eq!(limits["maxExpandedBytes"], 1024_u64 * 1024 * 1024);
        assert!(MAX_FILE > 269_460_246 + 65_536);
    }
    #[test]
    fn expanded_stream_rejects_one_byte_over_its_own_cap() {
        let mut input = Limited {
            inner: io::repeat(0).take(7),
            count: 0,
            limit: 6,
        };
        let mut sink = io::sink();
        assert!(io::copy(&mut input, &mut sink)
            .unwrap_err()
            .to_string()
            .contains("STATE_EXPANDED_SIZE_LIMIT"));
    }
    #[test]
    fn expanded_stream_accepts_exact_limit() {
        let mut input = Limited {
            inner: io::repeat(0).take(6),
            count: 0,
            limit: 6,
        };
        assert_eq!(io::copy(&mut input, &mut io::sink()).unwrap(), 6);
    }
}
