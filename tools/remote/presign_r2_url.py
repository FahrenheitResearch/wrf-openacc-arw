#!/usr/bin/env python3
import argparse
import configparser
import datetime as dt
import hashlib
import hmac
import os
import sys
import urllib.parse


def load_ini(path: str) -> configparser.RawConfigParser:
    parser = configparser.RawConfigParser()
    if path and os.path.exists(path):
        parser.read(path)
    return parser


def get_profile_section(parser: configparser.RawConfigParser, profile: str, is_config: bool) -> str | None:
    candidates = [profile]
    if is_config:
        candidates.insert(0, f"profile {profile}")
    for section in candidates:
        if parser.has_section(section):
            return section
    return None


def resolve_credentials(profile: str) -> tuple[str, str, str | None]:
    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    session_token = os.environ.get("AWS_SESSION_TOKEN")

    if access_key and secret_key:
      return access_key, secret_key, session_token

    creds_path = os.environ.get("AWS_SHARED_CREDENTIALS_FILE", os.path.expanduser("~/.aws/credentials"))
    creds = load_ini(creds_path)
    section = get_profile_section(creds, profile, False)
    if not section:
        raise SystemExit(f"credentials profile not found: {profile}")

    access_key = creds.get(section, "aws_access_key_id", fallback=None)
    secret_key = creds.get(section, "aws_secret_access_key", fallback=None)
    session_token = creds.get(section, "aws_session_token", fallback=None)
    if not access_key or not secret_key:
        raise SystemExit(f"incomplete credentials for profile: {profile}")
    return access_key, secret_key, session_token


def resolve_region(profile: str) -> str:
    if os.environ.get("AWS_REGION"):
        return os.environ["AWS_REGION"]
    if os.environ.get("AWS_DEFAULT_REGION"):
        return os.environ["AWS_DEFAULT_REGION"]

    config_path = os.environ.get("AWS_CONFIG_FILE", os.path.expanduser("~/.aws/config"))
    config = load_ini(config_path)
    section = get_profile_section(config, profile, True)
    if section:
        region = config.get(section, "region", fallback=None)
        if region:
            return region
    return "auto"


def resolve_endpoint(profile: str, endpoint: str | None) -> str:
    if endpoint:
        return endpoint
    if os.environ.get("WRF_REMOTE_R2_ENDPOINT"):
        return os.environ["WRF_REMOTE_R2_ENDPOINT"]

    config_path = os.environ.get("AWS_CONFIG_FILE", os.path.expanduser("~/.aws/config"))
    config = load_ini(config_path)
    section = get_profile_section(config, profile, True)
    if section:
        value = config.get(section, "endpoint_url", fallback=None)
        if value:
            return value

    rclone_paths = [
        os.environ.get("RCLONE_CONFIG"),
        os.path.expanduser("~/.config/rclone/rclone.conf"),
        "/mnt/c/Users/drew/.config/rclone/rclone.conf",
        "/mnt/c/Users/drew/AppData/Roaming/rclone/rclone.conf",
    ]
    for path in rclone_paths:
        if not path or not os.path.exists(path):
            continue
        rclone = load_ini(path)
        if rclone.has_section(profile):
            value = rclone.get(profile, "endpoint", fallback=None)
            if value:
                return value

    raise SystemExit("unable to resolve R2 endpoint; set WRF_REMOTE_R2_ENDPOINT")


def sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def aws_v4_signing_key(secret_key: str, date_stamp: str, region: str, service: str) -> bytes:
    k_date = sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region = sign(k_date, region)
    k_service = sign(k_region, service)
    return sign(k_service, "aws4_request")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default=os.environ.get("WRF_REMOTE_R2_PROFILE", "r2"))
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--method", default="GET", choices=["GET", "PUT", "HEAD"])
    parser.add_argument("--expires", type=int, default=3600)
    parser.add_argument("--endpoint")
    args = parser.parse_args()

    access_key, secret_key, session_token = resolve_credentials(args.profile)
    region = resolve_region(args.profile)
    endpoint = resolve_endpoint(args.profile, args.endpoint)

    parsed = urllib.parse.urlparse(endpoint)
    scheme = parsed.scheme or "https"
    host = parsed.netloc or parsed.path
    base_path = parsed.path if parsed.netloc else ""
    if not host:
        raise SystemExit(f"invalid endpoint: {endpoint}")

    now = dt.datetime.now(dt.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    credential_scope = f"{date_stamp}/{region}/s3/aws4_request"

    object_path = "/".join(
        segment for segment in [base_path.strip("/"), args.bucket.strip("/"), args.key.strip("/")] if segment
    )
    canonical_uri = "/" + urllib.parse.quote(object_path, safe="/~")

    query = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access_key}/{credential_scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(args.expires),
        "X-Amz-SignedHeaders": "host",
    }
    if session_token:
        query["X-Amz-Security-Token"] = session_token

    canonical_query = "&".join(
        f"{urllib.parse.quote(key, safe='')}={urllib.parse.quote(query[key], safe='~')}"
        for key in sorted(query)
    )
    canonical_headers = f"host:{host}\n"
    canonical_request = "\n".join(
        [
            args.method,
            canonical_uri,
            canonical_query,
            canonical_headers,
            "host",
            "UNSIGNED-PAYLOAD",
        ]
    )

    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signing_key = aws_v4_signing_key(secret_key, date_stamp, region, "s3")
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    query["X-Amz-Signature"] = signature
    final_query = "&".join(
        f"{urllib.parse.quote(key, safe='')}={urllib.parse.quote(query[key], safe='~')}"
        for key in sorted(query)
    )
    final_url = urllib.parse.urlunparse((scheme, host, canonical_uri, "", final_query, ""))
    sys.stdout.write(final_url + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
