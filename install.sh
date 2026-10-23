#!/usr/bin/env bash
#
# One-command Bulky installer for a fresh Ubuntu 22.04/24.04 amd64 server:
#
#   curl -fsSL https://access.usebulky.com/install | sudo bash
#
# Asks for the hostname, the first admin's email and the license key, then
# downloads the newest release the license allows from access.usebulky.com
# (checking its size and SHA-256), unpacks it to /opt/bulky-vX.Y.Z, prepares
# the server (prepare-ubuntu-server.sh), and runs init, activate, admin and,
# optionally, backup setup. Set BULKY_DATA_DIR to use another data directory
# than /srv/bulky. Everything after this is docs/install.md (update, restore).
#
# The whole script is one function so bash reads it completely before
# running: prompts read /dev/tty, never the pipe the script arrives on.

set -Eeuo pipefail

main() {
    umask 022
    # Keep in sync with internal/license/keygen.json (deploy_test.go checks).
    local api="https://access.usebulky.com/v1/accounts/1b7e8bca-d3ed-4737-a3b7-b289902196d2"
    local product="87e1aa88-f09a-44d2-bb50-2bdebad92e07"
    local data="${BULKY_DATA_DIR:-/srv/bulky}"
    local host email key backups version bundle tmp stage="checks"

    [ "$(id -u)" = 0 ] || die "run as root: curl -fsSL https://access.usebulky.com/install | sudo bash"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04 | ubuntu:24.04) ;;
        *) die "Bulky needs Ubuntu 22.04 or 24.04 (this is ${PRETTY_NAME:-unknown})" ;;
    esac
    [ "$(uname -m)" = x86_64 ] || die "Bulky needs an amd64 (x86_64) server"
    (: </dev/tty) 2>/dev/null || die "run this from an interactive terminal (it asks for passwords)"
    [ -z "$(ls -A "$data" 2>/dev/null)" ] ||
        die "$data is not empty: Bulky is already installed here. Use 'bulky update' to update it."

    say "Bulky installer. The data directory will be $data."
    ask host "Hostname for Bulky (its DNS A record must point here), e.g. mail.example.com: "
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    host=${host#https://}
    host=${host%%/*}
    [ -n "$host" ] || die "a hostname is required"
    ask email "Email of the first admin user: "
    read -rsp "License key (input hidden): " key </dev/tty
    echo >/dev/tty
    [ -n "$key" ] || die "a license key is required"

    command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3 >/dev/null; }

    stage="download"
    tmp=$(mktemp -d /opt/bulky-install.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    say "Finding the newest release for your license..."
    version=$(printf '%s\n' "$key" | python3 -I -c "$FETCH" "$api" "$product" "$tmp/bulky.tar.gz")
    bundle="/opt/bulky-$version"
    if [ -x "$bundle/bulky" ]; then
        say "Using the already unpacked $bundle."
    else
        mkdir -m 755 "$bundle"
        tar --no-same-owner -C "$bundle" -xzf "$tmp/bulky.tar.gz"
    fi
    rm -rf "$tmp"
    trap - EXIT

    stage="prepare"
    say "Preparing the server (Docker, firewall, security updates)..."
    bash "$bundle/prepare-ubuntu-server.sh" --host "$host" --data-dir "$data" </dev/null

    stage="init"
    trap 'failed "$stage" "$bundle" "$data"' ERR
    say "Installing Bulky $version into $data..."
    bulky init --url "https://$host" </dev/null

    stage="activate"
    say "Activating the license..."
    local rc=0
    printf '%s\n' "$key" | bulky activate --key-stdin || rc=$?
    # ponytail: releases before --key-stdin exit 2 (usage); drop once none is installable.
    if [ "$rc" = 2 ]; then
        say "This release asks for the key once more."
        bulky activate </dev/tty
    elif [ "$rc" != 0 ]; then
        false
    fi

    stage="admin"
    say "Creating the admin user $email..."
    bulky admin "$email" </dev/tty

    stage="backups"
    say "Backups are encrypted with restic and are required before 'bulky update'."
    ask backups "Backup folder (ideally a separate disk), 's3' for S3-compatible storage, or Enter to skip: "
    if [ -n "$backups" ]; then
        if [ "$backups" = s3 ]; then
            bulky backup-configure </dev/tty
        else
            bulky backup-configure --local "$backups" </dev/tty
        fi
        bulky backup-schedule --enable --time 03:00
        bulky backup
    fi
    trap - ERR

    bulky status || true
    say ""
    say "Bulky $version is installed. Open https://$host and sign in as $email."
    say "Manage it with: sudo $bundle/bulky --data-dir $data <command>   (e.g. status, update)"
    [ -n "$backups" ] || say "Backups are not configured yet: sudo $bundle/bulky --data-dir $data backup-configure"
    say "Keep $bundle: the installation runs from it. Store the backup recovery password and"
    say "$data/compose.env (database password, master key) in a password manager, off this server."
}

bulky() { "$bundle/bulky" --data-dir "$data" "$@"; }
say() { printf '%s\n' "$*"; }
die() { printf 'bulky install: %s\n' "$*" >&2; exit 1; }
ask() { local _v; read -rp "$2" _v </dev/tty; printf -v "$1" '%s' "$_v"; }

failed() {
    if [ "$1" = init ]; then
        say "Install failed while initialising. Fix the problem above, then: rm -rf $3 and re-run." >&2
    else
        say "Install stopped at the '$1' step; Bulky itself is installed in $3." >&2
        say "Fix the problem above and finish by hand with: sudo $2/bulky --data-dir $3 <activate|admin EMAIL|backup-configure>" >&2
    fi
}

# FETCH reads the license key on stdin, downloads the newest stable release
# archive the license may download to argv[3], checks its published size and
# SHA-256, and prints its version. Mirrors internal/ops/keygen.go.
FETCH=$(cat <<'PY'
import hashlib, json, re, sys, urllib.error, urllib.request

api, product, dest = sys.argv[1:4]
key = sys.stdin.readline().strip()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None

keygen = urllib.request.build_opener(NoRedirect)

def get(path):
    req = urllib.request.Request(api + path, headers={
        "Authorization": "License " + key, "Accept": "application/vnd.api+json",
        "Keygen-Version": "1.8", "Prefer": "no-redirect", "User-Agent": "bulky-installer"})
    try:
        with keygen.open(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise PermissionError
        sys.exit(f"bulky install: access.usebulky.com answered HTTP {e.code}; try again later")
    except urllib.error.URLError as e:
        sys.exit(f"bulky install: cannot reach access.usebulky.com ({e.reason}); outbound HTTPS is required")

def semver(v):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
    return tuple(map(int, m.groups())) if m else None

try:
    # ponytail: one page of 100 releases (Keygen lists newest first); page if that ever runs out.
    releases = get(f"/releases?product={product}&channel=stable&status=PUBLISHED&page[size]=100&page[number]=1")["data"]
except PermissionError:
    sys.exit("bulky install: the license key was not accepted; check it, or contact Bulky support")

releases = [r for r in releases if semver(r["attributes"]["version"])]
releases.sort(key=lambda r: semver(r["attributes"]["version"]), reverse=True)
for rel in releases:
    version = "v" + rel["attributes"]["version"]
    name = f"bulky-{version}-linux-amd64.tar.gz"
    try:
        arts = [a for a in get(f"/releases/{rel['id']}/artifacts")["data"] if a["attributes"]["filename"] == name]
        if len(arts) != 1 or arts[0]["attributes"]["status"] != "UPLOADED":
            continue
        link = get(f"/artifacts/{arts[0]['id']}")["data"]["links"]["redirect"]
    except PermissionError:
        continue  # released after this license's update window
    size, checksum = int(arts[0]["attributes"]["filesize"]), arts[0]["attributes"]["checksum"]
    if not link.startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        sys.exit(f"bulky install: {version} has an invalid download link or checksum")
    print(f"Downloading {name} ({size // 1048576} MiB)...", file=sys.stderr)
    h, n = hashlib.sha256(), 0
    with urllib.request.urlopen(urllib.request.Request(link, headers={"User-Agent": "bulky-installer"}), timeout=60) as r, \
            open(dest, "xb") as f:
        while chunk := r.read(1 << 20):
            n += len(chunk)
            if n > size:
                break
            h.update(chunk)
            f.write(chunk)
    if n != size or h.hexdigest() != checksum:
        sys.exit(f"bulky install: the download of {name} failed size or SHA-256 verification; re-run")
    print(version)
    sys.exit(0)
sys.exit("bulky install: no release is available to this license; contact Bulky support")
PY
)

main "$@"
