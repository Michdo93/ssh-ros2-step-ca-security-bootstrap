#!/usr/bin/env bash
# Scan an IPv4 range for SSH hosts and run ros2-step-ca-security-bootstrap (SROS2 enclaves
# with step-ca certificates + renewal timer) on the selected devices, one after another:
#   https://github.com/Michdo93/ros2-step-ca-security-bootstrap
#
# The step-ca settings and the provisioner password are asked once. All devices get the same
# (shared) permissions CA, so their nodes accept each other's permissions.
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
  while true; do
    printf '\nEnter the first and last IPv4 address in the range.\n'
    read -r -p 'First address: ' first || exit 0
    read -r -p 'Last address:  ' last || exit 0
    first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
    last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
    (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
    (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
    if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
  done
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/Michdo93/ros2-step-ca-security-bootstrap/main/setup_sros2.sh}"
UPLOAD_DIR=".sros2-bootstrap-upload"   # relative to the remote home, removed after each run

CTL_DIR=$(mktemp -d) || exit 1
PWLOCAL=$(mktemp) || exit 1
trap 'for s in "$CTL_DIR"/*; do [ -S "$s" ] && ssh -S "$s" -O exit x 2>/dev/null; done; rm -rf "$CTL_DIR" "$PWLOCAL" "$LOG"' EXIT
chmod 600 "$PWLOCAL"

remote_result() { grep -ao '@@RESULT:[A-Z_]*@@' "$LOG" | tail -n 1 | sed 's/^@@RESULT://; s/@@$//'; }
q() { local s=$1 x="'"; printf "'%s'" "${s//$x/$x\\$x$x}"; }   # quote for the remote shell

# Remote part (POSIX sh) in the remote terminal: download and run setup_sros2.sh with bash.
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
mark() { printf '@@RESULT:%s@@\r\033[K' "$1"; }
url=$1; shift
cleanup() { rm -rf "$HOME/.sros2-bootstrap-upload"; }
command -v bash >/dev/null 2>&1 || { cleanup; mark NO_BASH; exit 0; }
tmp=$(mktemp) || { cleanup; mark DOWNLOAD_FAILED; exit 0; }
if command -v wget >/dev/null 2>&1; then wget -qO "$tmp" "$url"
elif command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$tmp"
fi
[ -s "$tmp" ] || { rm -f "$tmp"; cleanup; mark DOWNLOAD_FAILED; exit 0; }
cd "$HOME" && bash "$tmp" "$@"
rc=$?
rm -f "$tmp"; cleanup
if [ "$rc" -eq 0 ]; then mark SUCCESS; else mark SETUP_FAILED; fi
REMOTE

# ---------- settings (once) ----------
printf 'Setup script: %s\n' "$SCRIPT_URL"
while true; do
  read -r -p 'step-ca URL (e.g. https://ca.lab:9000): ' ca_url || exit 0
  [[ "$ca_url" == https://* ]] || { printf 'The URL must start with https://\n'; continue; }
  read -r -p 'Root certificate fingerprint (step certificate fingerprint root_ca.crt): ' fp || exit 0
  fp=${fp//[: ]/}; fp=${fp,,}
  [[ "$fp" =~ ^[0-9a-f]{64}$ ]] || { printf 'The fingerprint must be 64 hex characters (SHA-256).\n'; continue; }
  read -r -p 'JWK provisioner name (step ca provisioner list): ' provisioner || exit 0
  [[ -n "$provisioner" ]] || continue
  read -r -s -p "Password of provisioner $provisioner: " pw || exit 0; printf '\n'
  printf '%s' "$pw" > "$PWLOCAL"; unset pw
  if command -v step >/dev/null 2>&1; then
    root_tmp=$(mktemp)
    if step ca root "$root_tmp" --ca-url "$ca_url" --fingerprint "$fp" --force >/dev/null 2>&1 &&
       step ca token sros2-password-check --ca-url "$ca_url" --root "$root_tmp" --provisioner "$provisioner" \
         --password-file "$PWLOCAL" >/dev/null 2>&1; then
      printf 'step-ca, fingerprint, provisioner and password verified.\n'
    else
      printf 'Warning: could not verify the settings with the local step CLI (CA unreachable from here or wrong values).\n'
    fi
    rm -f "$root_tmp"
  fi
  if ask_yes_no 'Least-privilege permissions from the running nodes? (No: permissive within the ROS domain)' y; then
    perm_mode=graph; else perm_mode=permissive; fi
  read -r -p 'Certificate lifetime, e.g. 720h (Enter: provisioner default): ' not_after || exit 0
  printf 'CA %s, provisioner %s, permissions %s%s\n' "$ca_url" "$provisioner" "$perm_mode" "${not_after:+, lifetime $not_after}"
  if ask_yes_no 'Are these settings correct?' y; then break; fi
done

# ---------- shared permissions CA ----------
perm_cert=""; perm_key=""
if ask_yes_no 'Use one shared permissions CA for all devices? (needed when nodes talk across hosts)' y; then
  read -r -p "Permissions CA directory [${PERM_CA_DIR:-./sros2-permissions-ca}]: " d || exit 0
  d=${d:-${PERM_CA_DIR:-./sros2-permissions-ca}}
  perm_cert="$d/permissions_ca.cert.pem"; perm_key="$d/permissions_ca.key.pem"
  if [[ -r "$perm_cert" && -r "$perm_key" ]]; then
    printf 'Using the existing permissions CA in %s.\n' "$d"
  else
    command -v openssl >/dev/null || die 'openssl is required to create the permissions CA.'
    mkdir -p "$d" && chmod 700 "$d" || die "Cannot create $d."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=SROS2 Permissions CA" -keyout "$perm_key" -out "$perm_cert" >/dev/null 2>&1 ||
      die 'Creating the permissions CA failed.'
    chmod 600 "$perm_key"
    printf 'New permissions CA created in %s - keep this directory, it is needed for every further device.\n' "$d"
  fi
fi

ask_range
scan_range

# login IP -> 0 when a master connection for $username@IP exists (up to three attempts)
login() {
  local ip=$1 attempt
  read -r -p 'SSH username: ' username || return 1
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; return 1; }
  CTL="$CTL_DIR/$ip"
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    if ssh -fN -M -S "$CTL" -o ControlPersist=900 -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
        -o StrictHostKeyChecking=accept-new "$username@$ip" 2> >(tee "$LOG" >&2); then
      return 0
    fi
    sleep 0.2
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}
rssh() { ssh -S "$CTL" -o BatchMode=yes -p "$SSH_PORT" "$username@$ip" "$@"; }
upload() {  # local-file remote-name (inside UPLOAD_DIR, mode 600)
  rssh "umask 077; mkdir -p $UPLOAD_DIR && cat > $UPLOAD_DIR/$2" < "$1"
}

declare -a done_hosts=() failed_hosts=()
for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Set up SROS2 with step-ca on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  login "$ip" || { failed_hosts+=("$ip"); continue; }

  args=(--ca-url "$ca_url" --fingerprint "$fp" --provisioner "$provisioner" --permissions "$perm_mode"
        --password-file "$UPLOAD_DIR/provisioner.pw")
  [[ -n "$not_after" ]] && args+=(--not-after "$not_after")
  if ! upload "$PWLOCAL" provisioner.pw; then printf 'Upload to %s failed.\n' "$ip"; failed_hosts+=("$ip"); continue; fi
  if [[ -n "$perm_cert" ]]; then
    upload "$perm_cert" permissions_ca.cert.pem && upload "$perm_key" permissions_ca.key.pem ||
      { printf 'Upload to %s failed.\n' "$ip"; failed_hosts+=("$ip"); continue; }
    args+=(--permissions-ca-cert "$UPLOAD_DIR/permissions_ca.cert.pem" --permissions-ca-key "$UPLOAD_DIR/permissions_ca.key.pem")
  fi

  b64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')
  cmd="sh -c \"\$(echo $b64 | base64 -d)\" remote $(q "$SCRIPT_URL")"
  for a in "${args[@]}"; do cmd+=" $(q "$a")"; done
  # interactive: the setup script asks to start the nodes and waits for Enter
  ssh -tt -S "$CTL" -p "$SSH_PORT" "$username@$ip" "$cmd" 2>&1 | tee "$LOG"
  result=$(remote_result)
  rssh "rm -rf $UPLOAD_DIR" 2>/dev/null
  ssh -S "$CTL" -O exit "$ip" 2>/dev/null
  case "$result" in
    SUCCESS) printf 'SROS2 set up on %s.\n' "$ip"; done_hosts+=("$ip") ;;
    NO_BASH) printf 'Skipped: bash is missing on %s.\n' "$ip"; failed_hosts+=("$ip") ;;
    DOWNLOAD_FAILED) printf 'Could not download the setup script on %s (no Internet access or neither wget nor curl).\n' "$ip"; failed_hosts+=("$ip") ;;
    SETUP_FAILED) printf 'The setup script reported an error on %s - see the output above.\n' "$ip"; failed_hosts+=("$ip") ;;
    *) printf 'The remote session ended without a result on %s (interrupted?).\n' "$ip"; failed_hosts+=("$ip") ;;
  esac
done
printf '\nFinished. SROS2 set up: %d' "${#done_hosts[@]}"
((${#done_hosts[@]})) && printf ' (%s)' "${done_hosts[*]}"
printf ', failed: %d' "${#failed_hosts[@]}"
((${#failed_hosts[@]})) && printf ' (%s)' "${failed_hosts[*]}"
printf '\n'
exit 0
