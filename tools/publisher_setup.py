#!/usr/bin/env python3
"""Generate an explicit, exact-byte publisher setup link. Never hosts or fetches files."""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlencode, urlsplit, urlunsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "simulation"))
from keccak import keccak256

LIMIT = 64 * 1024

def public_url(value):
    url = urlsplit(value)
    _ = url.port
    if (url.scheme != "https" and not (url.scheme == "http" and url.hostname in ["localhost", "127.0.0.1", "::1"])) or not url.hostname or url.username or url.password or "?" in value or "#" in value:
        raise ValueError("PUBLIC_URL_REQUIRED")
    return value

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("DUPLICATE_PROFILE_FIELD")
        result[key] = value
    return result

def validate_public(raw):
    if len(raw) > LIMIT:
        raise ValueError("PROFILE_SIZE_LIMIT")
    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
        if not isinstance(data, dict) or set(data) - {"deployment", "rpcUrl", "guidelinesUrl", "display", "upload", "contentGatewayUrl", "contentPath"}:
            raise ValueError("INVALID_PUBLIC_PROFILE")
        deployment = data["deployment"]
        if set(deployment) != {"chainId","moderation","stakes","index","token","guidelines"}:
            raise ValueError("INVALID_DEPLOYMENT_FIELDS")
        if str(deployment["chainId"]) not in ["100", "10200"]:
            raise ValueError("INVALID_CHAIN")
        for name in ["moderation", "stakes", "index", "token"]:
            if set(deployment[name]) != {"address","codeHash"}:
                raise ValueError("INVALID_DEPLOYMENT_PIN")
            for field, width in [("address", 40), ("codeHash", 64)]:
                value = deployment[name][field]
                if not re.fullmatch("0x[0-9a-fA-F]{" + str(width) + "}", value) or int(value, 16) == 0:
                    raise ValueError("INVALID_DEPLOYMENT_PIN")
        guidelines=deployment["guidelines"]
        if set(guidelines)!={"version","hash"} or not re.fullmatch(r"[1-9][0-9]*",str(guidelines["version"])) or int(guidelines["version"])>=2**64 or not re.fullmatch(r"0x[0-9a-fA-F]{64}",guidelines["hash"]) or int(guidelines["hash"],16)==0:
            raise ValueError("INVALID_GUIDELINES_PIN")
        display=data.get("display")
        if display is not None and (set(display)!={"decimals","symbol"} or type(display["decimals"]) is not int or not 0<=display["decimals"]<=36 or not re.fullmatch(r"[a-zA-Z0-9 _-]{1,16}",display["symbol"])):
            raise ValueError("INVALID_DISPLAY_SETTINGS")
        public_url(data["rpcUrl"])
        upload = data.get("upload")
        if upload is not None:
            if set(upload) - {"endpoint", "postageBatchId"}:
                raise ValueError("PRIVATE_UPLOAD_SETTINGS")
            public_url(upload["endpoint"])
            if not re.fullmatch(r"[0-9a-fA-F]{64}", upload["postageBatchId"]) or int(upload["postageBatchId"], 16) == 0:
                raise ValueError("INVALID_BATCH")
        if data.get("contentGatewayUrl"):
            public_url(data["contentGatewayUrl"])
        if data.get("contentPath", "bytes") not in ["bytes", "bzz"]:
            raise ValueError("INVALID_CONTENT_PATH")
        if data.get("guidelinesUrl", "./MODERATION_GUIDELINES.md") != "./MODERATION_GUIDELINES.md":
            public_url(data["guidelinesUrl"])
        return data
    except (KeyError, TypeError, UnicodeError, json.JSONDecodeError):
        raise ValueError("INVALID_PUBLIC_PROFILE") from None

def setup_link(raw, profile_url, app_url):
    validate_public(raw)
    public_url(profile_url)
    public_url(app_url)
    app = urlsplit(app_url)
    fingerprint = "0x" + keccak256(raw).hex()
    return urlunsplit((app.scheme, app.netloc, app.path, "", urlencode({"profile": profile_url, "profileHash": fingerprint})))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True, help="Reviewed public profile, without credentials")
    parser.add_argument("--profile-url", required=True, help="Where those exact bytes will be publicly served")
    parser.add_argument("--app-url", required=True, help="Publisher application URL")
    args = parser.parse_args()
    try:
        with args.profile.open("rb") as stream:
            raw = stream.read(LIMIT + 1)
        print(setup_link(raw, args.profile_url, args.app_url))
    except (OSError, ValueError) as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[A-Z_]+", str(error)) else "PROFILE_READ_OR_VALIDATION_FAILED"
        parser.exit(1, "Setup link not generated: " + code + "\n")

if __name__ == "__main__":
    main()
