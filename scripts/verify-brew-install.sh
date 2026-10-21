#!/usr/bin/env bash

# Install the real generated formula under a separate name without linking it.
# This checks Homebrew relocation as well as post_install signing. A notarized
# binary must remain byte-identical to the archive after installation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Homebrew's test harness uses its own Ruby and CA configuration.
export HOMEBREW_FORCE_BREWED_CA_CERTIFICATES="${HOMEBREW_FORCE_BREWED_CA_CERTIFICATES:-1}"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

ARCHIVE=""
VERSION=""
DOWNLOAD_URL=""
REQUIRE_DEVELOPER_ID=false
REQUIRE_SPCTL_ACCEPT=false
EXPECTED_TEAM_ID="${SIM_USE_EXPECTED_TEAM_ID:-GFPYJQXRSN}"
KEEP_ON_FAILURE=true
TAP_REF="sim-use-release-test/dryrun"
FORMULA_NAME="sim-use-dryrun"
TAP_CREATED=false
INSTALL_ATTEMPTED=false

usage() {
  cat <<'EOF'
Usage: scripts/verify-brew-install.sh --archive PATH --version VERSION [OPTIONS]

  --archive PATH            Existing release archive used as the reference.
  --version VERSION         Plain release version, without a leading v.
  --download-url URL        Have Homebrew fetch this URL instead of the local
                            archive. Its checksum must match --archive.
  --require-developer-id    Generate a notarized formula and verify its original
                            binary bytes, Developer ID signature and notary record.
  --require-spctl-accept    Also require a successful Gatekeeper assessment.
  --cleanup-on-failure      Remove this run's temporary tap and keg on failure.
                            Otherwise leave them available for inspection.
  -h, --help                Show this help.

The temporary formula is installed with --skip-link. The existing sim-use
installation and PATH links are not changed. Existing verification workspaces
are refused, not overwritten or removed.
EOF
}

log()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --download-url) DOWNLOAD_URL="${2:-}"; shift 2 ;;
    --require-developer-id) REQUIRE_DEVELOPER_ID=true; shift ;;
    --require-spctl-accept) REQUIRE_SPCTL_ACCEPT=true; shift ;;
    --cleanup-on-failure) KEEP_ON_FAILURE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$ARCHIVE" && -n "$VERSION" ]] || { usage >&2; fail "--archive and --version are required"; }
[[ -f "$ARCHIVE" ]] || fail "Archive not found: $ARCHIVE"
command -v brew >/dev/null || fail "brew not on PATH"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
TAP_DIR="$(brew --repository)/Library/Taps/sim-use-release-test/homebrew-dryrun"
FORMULA_PATH="$TAP_DIR/Formula/$FORMULA_NAME.rb"
INSTALLED_KEG="$(brew --cellar)/$FORMULA_NAME/$VERSION"
INSTALLED_BIN="$INSTALLED_KEG/libexec/sim-use"

[[ ! -e "$TAP_DIR" ]] || fail "Verification tap already exists: $TAP_DIR"
[[ -z "$(brew list --versions "$FORMULA_NAME" 2>/dev/null || true)" ]] \
  || fail "Verification formula is already installed: $FORMULA_NAME"

SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-verify-source.XXXXXX")"
# Homebrew 6+ requires trust for local formulae. Keep that permission inside this
# run rather than adding a permanent entry to the developer's trust database.
export XDG_CONFIG_HOME="$SOURCE_DIR/config"
cleanup() {
  local rc=$?
  local can_untap=true
  if [[ $rc -ne 0 && "$KEEP_ON_FAILURE" == "true" ]]; then
    warn "Verification failed; retaining this run's workspace for inspection."
    warn "Reference files and isolated trust config: $SOURCE_DIR"
    [[ "$TAP_CREATED" != "true" ]] || warn "Tap: $TAP_DIR"
    [[ "$INSTALL_ATTEMPTED" != "true" ]] || warn "Keg: $INSTALLED_KEG"
    exit "$rc"
  fi
  if [[ "$INSTALL_ATTEMPTED" == "true" ]]; then
    brew uninstall --formula "$TAP_REF/$FORMULA_NAME" || { rc=1; can_untap=false; }
  fi
  if [[ "$TAP_CREATED" == "true" && "$can_untap" == "true" ]]; then
    if brew untap "$TAP_REF"; then
      [[ ! -d "$TAP_DIR" ]] || rm -rf "$TAP_DIR"
    else
      rc=1
    fi
  fi
  rm -rf "$SOURCE_DIR"
  exit "$rc"
}
trap cleanup EXIT

tar -xzf "$ARCHIVE" -C "$SOURCE_DIR" sim-use SimUse_SimUse.bundle SimUse_AndroidBackend.bundle
SOURCE_APK="$(find "$SOURCE_DIR/SimUse_AndroidBackend.bundle" -type f -name sim-use-device-bridge.apk)"
[[ -f "$SOURCE_APK" ]] || fail "Archive must contain exactly one Android bridge APK"
APK_PATH="${SOURCE_APK#"$SOURCE_DIR/"}"
INSTALLED_APK="$INSTALLED_KEG/libexec/$APK_PATH"
ARCHIVE_APK_SHA="$(shasum -a 256 "$SOURCE_APK" | awk '{print $1}')"
ARCHIVE_BINARY_SHA="$(shasum -a 256 "$SOURCE_DIR/sim-use" | awk '{print $1}')"
ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ -z "$DOWNLOAD_URL" ]]; then
  DOWNLOAD_URL="$(ruby -ruri -e 'puts "file://" + URI::DEFAULT_PARSER.escape(ARGV.fetch(0))' "$ARCHIVE")"
fi

mkdir -p "$TAP_DIR/Formula"
TAP_CREATED=true
FORMULA_FLAGS=(
  --formula-class SimUseDryrun
  --homepage https://github.com/lycorp-jp/sim-use
  --version "$VERSION"
  --url "$DOWNLOAD_URL"
  --sha256 "$ARCHIVE_SHA256"
)
[[ "$REQUIRE_DEVELOPER_ID" != "true" ]] || FORMULA_FLAGS+=(--notarized)
scripts/generate-homebrew-formula.sh "${FORMULA_FLAGS[@]}" > "$FORMULA_PATH"
ruby -c "$FORMULA_PATH"
(
  cd "$TAP_DIR"
  git init --quiet
  git add "Formula/$FORMULA_NAME.rb"
  git -c user.email=verify@local -c user.name=verify commit --quiet -m "sim-use-dryrun $VERSION"
)

if brew help trust >/dev/null 2>&1; then
  brew trust --formula "$TAP_REF/$FORMULA_NAME"
fi
log "Installing $TAP_REF/$FORMULA_NAME without linking"
INSTALL_ATTEMPTED=true
brew install --formula --skip-link "$TAP_REF/$FORMULA_NAME"
[[ -x "$INSTALLED_BIN" ]] || fail "Installed binary is missing: $INSTALLED_BIN"
[[ -f "$INSTALLED_APK" ]] || fail "Installed APK is missing: $INSTALLED_APK"
[[ "$(shasum -a 256 "$INSTALLED_APK" | awk '{print $1}')" == "$ARCHIVE_APK_SHA" ]] \
  || fail "Installed APK differs from the archive"
ok "Installed APK is byte-identical to the archive"
for bundle in SimUse_SimUse.bundle SimUse_AndroidBackend.bundle; do
  diff -qr "$SOURCE_DIR/$bundle" "$INSTALLED_KEG/libexec/$bundle" \
    || fail "Installed resource bundle differs from the archive: $bundle"
done
ok "Both resource bundles are unchanged"

codesign --verify --deep --strict --all-architectures "$INSTALLED_BIN"
SIG_INFO="$(codesign -dvv "$INSTALLED_BIN" 2>&1)"
if [[ "$REQUIRE_DEVELOPER_ID" == "true" ]]; then
  [[ "$(shasum -a 256 "$INSTALLED_BIN" | awk '{print $1}')" == "$ARCHIVE_BINARY_SHA" ]] \
    || fail "Installed binary differs from the notarized archive"
  grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<< "$SIG_INFO" \
    || fail "Installed binary lost the expected Developer ID team"
  grep -q '^Authority=Developer ID Application:' <<< "$SIG_INFO" \
    || fail "Installed binary lost its Developer ID certificate"
  codesign --verify --strict --all-architectures --check-notarization "$INSTALLED_BIN"
  ok "Developer ID signature, notarization and binary bytes preserved ($EXPECTED_TEAM_ID)"
else
  printf '%s\n' "$SIG_INFO" | grep -E 'Signature|Identifier|Authority' || true
fi

if [[ "$REQUIRE_SPCTL_ACCEPT" == "true" ]]; then
  spctl_out="$(spctl -a -vv "$INSTALLED_BIN" 2>&1 || true)"
  # A flat CLI can be valid without being an app. Newer macOS versions omit
  # spctl's origin line, so check the identity and notary record with codesign.
  if grep -q 'the code is valid' <<< "$spctl_out" \
    && grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<< "$SIG_INFO" \
    && grep -q '^Authority=Developer ID Application:' <<< "$SIG_INFO"; then
    codesign --verify --strict --all-architectures --check-notarization "$INSTALLED_BIN"
    ok "Gatekeeper confirms valid CLI code from $EXPECTED_TEAM_ID"
  elif grep -Eq '(^|: )accepted$' <<< "$spctl_out"; then
    ok "Gatekeeper accepted the binary"
  else
    printf '%s\n' "$spctl_out" >&2
    fail "Gatekeeper did not confirm this binary; no ad-hoc fallback was attempted"
  fi
fi

"$INSTALLED_BIN" --version
"$INSTALLED_BIN" init --print >/dev/null
"$INSTALLED_BIN" devices --no-physical-ios --json >/dev/null
# --force permits testing an unlinked keg; it does not skip test assertions.
brew test --force "$TAP_REF/$FORMULA_NAME"
ok "Homebrew installation preserves the expected release signature and resources"
