#!/usr/bin/env python3
"""Mint a GitHub Actions runner registration token from a GitHub App.

A self-hosted runner registers with a token that lasts one hour, so
something has to produce one at apply time. The alternatives were a
classic PAT with `repo` scope sitting in a vars file forever, or this:
an App scoped to Administration on one repository, whose key never
leaves the control host and whose derived tokens all expire.

Three steps, each documented by GitHub:

  1. an RS256 JWT signed with the App's private key (iss/iat/exp)
  2. POST /app/installations/{id}/access_tokens   -> 1h install token
  3. POST /repos/{owner}/{repo}/actions/runners/registration-token

Signing is `openssl dgst -sha256 -sign` rather than PyJWT on purpose.
PyYAML is the only dependency this repository has outside the standard
library — ci.yml says so where it installs it — and one ~40-line
function is a cheaper price than a second one.

Configuration comes from the environment, not the manifest: these are
a credential, they differ per operator, and a committed placeholder is
something CI would have to pretend to validate.

    ROCM_BAKE_RUNNER_APP_ID           the App's id
    ROCM_BAKE_RUNNER_INSTALLATION_ID  its installation on the repo
    ROCM_BAKE_RUNNER_KEY              path to the .pem private key

Usage:

    gh-app-token.py --registration-token [--repo owner/name]
    gh-app-token.py --installation-token
    gh-app-token.py --jwt

With no --repo, the repository comes from the fleet manifest's
`runner.repo`. Prints the token on stdout and nothing else, so it can
be captured directly.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
UA = "rocm-bake-fleet"


def die(msg):
    print(f"gh-app-token: {msg}", file=sys.stderr)
    raise SystemExit(1)


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        die(f"{name} is not set; see docs/operations/runners.md")
    return value


def b64(raw):
    """JWT base64url: no padding, which is not what b64encode gives."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def make_jwt(app_id, key_path):
    """An App JWT, RS256, valid ten minutes.

    `iat` is backdated sixty seconds. GitHub rejects a token whose
    `iat` is in the future, and a control host whose clock is a little
    fast is otherwise an authentication failure with no clue in it.
    """
    key = Path(key_path).expanduser()
    if not key.is_file():
        die(f"private key {key} does not exist")

    now = int(time.time())
    header = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({
        "iat": now - 60,
        "exp": now + 540,
        "iss": str(app_id),
    }).encode())
    signing_input = f"{header}.{payload}".encode()

    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key)],
            input=signing_input, capture_output=True, check=True)
    except FileNotFoundError:
        die("openssl not found; it signs the App JWT")
    except subprocess.CalledProcessError as exc:
        err = exc.stderr.decode(errors="replace").strip()
        die(f"openssl could not sign with {key}: {err}")

    return f"{header}.{payload}.{b64(proc.stdout)}"


def post(url, token):
    req = urllib.request.Request(url, data=b"", method="POST", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": UA,
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace").strip()
        hint = ""
        if exc.code == 403:
            hint = ("; the App needs the repository permission "
                    "'Administration: read & write'")
        elif exc.code == 404:
            hint = ("; check the installation id, and that the App is "
                    "installed on this repository")
        die(f"POST {url} -> {exc.code} {exc.reason}{hint}\n  {body}")
    except urllib.error.URLError as exc:
        die(f"POST {url} failed: {exc.reason}")


def installation_token():
    jwt = make_jwt(env("ROCM_BAKE_RUNNER_APP_ID"), env("ROCM_BAKE_RUNNER_KEY"))
    inst = env("ROCM_BAKE_RUNNER_INSTALLATION_ID")
    return post(f"{API}/app/installations/{inst}/access_tokens", jwt)["token"]


def registration_token(repo):
    return post(f"{API}/repos/{repo}/actions/runners/registration-token",
                installation_token())["token"]


def manifest_repo():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import fleet
    data = fleet.load()
    repo = (data.get("runner") or {}).get("repo")
    if not repo:
        die("no `runner.repo:` in the manifest and no --repo given")
    return repo


def main(argv):
    args = list(argv)

    def opt(flag):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                die(f"{flag} needs a value")
            return args[i + 1]
        return None

    repo = opt("--repo")

    if "--jwt" in args:
        print(make_jwt(env("ROCM_BAKE_RUNNER_APP_ID"),
                       env("ROCM_BAKE_RUNNER_KEY")))
    elif "--installation-token" in args:
        print(installation_token())
    elif "--registration-token" in args:
        print(registration_token(repo or manifest_repo()))
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
