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
    if not isinstance(value, str):
        raise ValueError("PUBLIC_URL_REQUIRED")
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

def valid_pin(pin):
    if not isinstance(pin, dict) or set(pin) != {"address", "codeHash"}:
        return False
    for field, width in [("address", 40), ("codeHash", 64)]:
        value = pin[field]
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{" + str(width) + "}", value) or int(value, 16) == 0:
            return False
    return True


def valid_version_guidelines(guidelines):
    if not isinstance(guidelines, dict) or set(guidelines) != {"version", "hash"}:
        return False
    version = str(guidelines["version"])
    value = guidelines["hash"]
    return (re.fullmatch(r"[1-9][0-9]*", version) is not None
            and int(version) < 2**32
            and isinstance(value, str)
            and re.fullmatch(r"0x[0-9a-fA-F]{64}", value) is not None
            and int(value, 16) != 0)


def validate_versions(deployment, guidelines_url):
    family = deployment.get("persistent")
    if family is None:
        return
    if not isinstance(family, dict) or set(family) != {"authority", "versions"}:
        raise ValueError("INVALID_VERSION_PROFILE")
    if not valid_pin(family["authority"]) or not isinstance(family["versions"], list) or not 1 <= len(family["versions"]) <= 16:
        raise ValueError("INVALID_VERSION_PROFILE")
    shared = {family["authority"]["address"].lower()}
    shared.update(deployment[k]["address"].lower() for k in ["stakes", "index", "token"])
    seen = set()
    selected = None
    for version in family["versions"]:
        if not isinstance(version, dict) or set(version) != {"moderation", "guidelines", "rulesHash", "guidelinesUrl"}:
            raise ValueError("INVALID_VERSION_PROFILE")
        if not valid_pin(version["moderation"]) or not valid_version_guidelines(version["guidelines"]):
            raise ValueError("INVALID_VERSION_PROFILE")
        address = version["moderation"]["address"].lower()
        rules = version["rulesHash"]
        if address in seen or address in shared or not isinstance(rules, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", rules) or int(rules, 16) == 0:
            raise ValueError("INVALID_VERSION_PROFILE")
        seen.add(address)
        if version["guidelinesUrl"] != "./MODERATION_GUIDELINES.md":
            public_url(version["guidelinesUrl"])
        if address == deployment["moderation"]["address"].lower():
            selected = version
    guidelines = deployment["guidelines"]
    if (selected is None
            or selected["moderation"]["codeHash"].lower() != deployment["moderation"]["codeHash"].lower()
            or str(selected["guidelines"]["version"]) != str(guidelines["version"])
            or selected["guidelines"]["hash"].lower() != guidelines["hash"].lower()
            or selected["guidelinesUrl"] != guidelines_url):
        raise ValueError("SELECTED_VERSION_MISMATCH")


def validate_public(raw):
    if len(raw) > LIMIT:
        raise ValueError("PROFILE_SIZE_LIMIT")
    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
        if not isinstance(data, dict) or set(data) - {"purpose", "deployment", "rpcUrl", "guidelinesUrl", "display", "upload", "contentGatewayUrl", "contentPath"}:
            raise ValueError("INVALID_PUBLIC_PROFILE")
        if data.get("purpose", "standard") not in ["standard", "existingWork"]:
            raise ValueError("INVALID_PROFILE_PURPOSE")
        deployment = data["deployment"]
        required={"chainId","moderation","stakes","index","token","guidelines"}
        if not required <= set(deployment) or set(deployment)-required-{"persistent"}:
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
        validate_versions(deployment, data.get("guidelinesUrl", "./MODERATION_GUIDELINES.md"))
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
