#!/bin/bash
# Installs a MacMint build that CI already built and tested, in about a minute.
# Nothing is compiled locally: the zip comes from the "macOS build" workflow's artifact.
#
#   ./scripts/install_dev_build.sh                 latest green build of main
#   ./scripts/install_dev_build.sh <branch>        latest green build of a branch
#   ./scripts/install_dev_build.sh <sha>           a specific commit (7–40 hex characters)
#   ./scripts/install_dev_build.sh --pr <number>   latest green build of a pull request's branch
#   ./scripts/install_dev_build.sh --rollback      put back the previously installed copy
#
# Options: --no-launch (don't open the app afterwards), --os macos-26 (use the macOS 26 runner's
# build; the default macos-15 build is universal and runs on macOS 14 or later).
#
# Requires the GitHub CLI signed in (`gh auth login`); artifact downloads need authentication
# even for public repositories. Never touches your live data: the old app moves to
# ~/MacMint-backups/<time>/ and ~/Library/Application Support/MacMint is copied there first.
# Only the newest five of those backup folders are kept.
set -euo pipefail

REPO="QuntmTech/mac-mint"
APP_ID="co.macmint.MacMint"
DEST="/Applications/MacMint.app"
BACKUPS="${HOME}/MacMint-backups"
DATA="${HOME}/Library/Application Support/MacMint"
RUNNER="macos-15"
LAUNCH=1
TARGET="main"
MODE="branch"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
step() { printf '▶ %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) [[ $# -ge 2 ]] || die "--pr needs a number"; MODE="pr"; TARGET="$2"; shift 2 ;;
    --rollback) MODE="rollback"; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --os) [[ $# -ge 2 ]] || die "--os needs macos-15 or macos-26"; RUNNER="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option $1 (see --help)" ;;
    *) TARGET="$1"; [[ "$1" =~ ^[0-9a-fA-F]{7,40}$ ]] && MODE="sha" || MODE="branch"; shift ;;
  esac
done
[[ "${RUNNER}" == "macos-15" || "${RUNNER}" == "macos-26" ]] || die "--os must be macos-15 or macos-26"
[[ "$(uname -s)" == "Darwin" ]] || die "Run this on the Mac you want to install on."

quit_running_app() {
  pgrep -x MacMint >/dev/null || return 0
  step "Asking MacMint to quit..."
  osascript -e "tell application id \"${APP_ID}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x MacMint >/dev/null || return 0; sleep 1; done
  die "MacMint is still running (it may be finishing an operation or showing a dialog). Quit it, then run this again."
}

register() {
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -x "$lsregister" ]] && "$lsregister" -f "$1" >/dev/null 2>&1 || true
}

if [[ "${MODE}" == "rollback" ]]; then
  PREVIOUS=$(ls -1dt "${BACKUPS}"/*/MacMint.app 2>/dev/null | head -1 || true)
  [[ -n "${PREVIOUS}" ]] || die "No backed-up MacMint.app in ${BACKUPS}."
  quit_running_app
  if [[ -d "${DEST}" ]]; then mv "${DEST}" "${BACKUPS}/rolled-back-$(date +%Y%m%d-%H%M%S).app"; fi
  ditto "${PREVIOUS}" "${DEST}"
  register "${DEST}"
  printf '✓ Restored %s\n' "${PREVIOUS}"
  [[ "${LAUNCH}" == 1 ]] && open "${DEST}"
  exit 0
fi

command -v gh >/dev/null || die "Install the GitHub CLI first: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || die "Sign the GitHub CLI in first: gh auth login"
STARTED=$(date +%s)

if [[ "${MODE}" == "pr" ]]; then
  TARGET=$(gh pr view "${TARGET}" --repo "${REPO}" --json headRefName -q .headRefName) || die "Pull request not found."
  MODE="branch"
fi

step "Finding the latest green build of ${TARGET}..."
if [[ "${MODE}" == "sha" ]]; then
  TARGET=$(gh api "repos/${REPO}/commits/${TARGET}" -q .sha 2>/dev/null) || die "Commit not found on GitHub."
  RUN=$(gh run list --repo "${REPO}" --workflow macos.yml --commit "${TARGET}" --event push --status success \
    --limit 1 --json databaseId,headSha -q '.[0] | "\(.databaseId) \(.headSha)"')
else
  RUN=$(gh run list --repo "${REPO}" --workflow macos.yml --branch "${TARGET}" --event push --status success \
    --limit 1 --json databaseId,headSha -q '.[0] | "\(.databaseId) \(.headSha)"')
fi
[[ -n "${RUN}" ]] || die "No successful macOS build found for ${TARGET} (CI may still be running, or the artifact expired after 14 days)."
RUN_ID=${RUN%% *}
SHA=${RUN##* }
ARTIFACT="MacMint-${RUNNER}-${SHA}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/macmint-install.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

step "Downloading ${ARTIFACT}..."
gh run download "${RUN_ID}" --repo "${REPO}" --name "${ARTIFACT}" --dir "${WORK}" >/dev/null \
  || die "Could not download ${ARTIFACT} from run ${RUN_ID}."
[[ -f "${WORK}/MacMint.zip" && -f "${WORK}/MacMint.zip.sha256" ]] || die "The artifact has no MacMint.zip and checksum."

step "Verifying checksum and signature..."
EXPECTED=$(tr -d '[:space:]' < "${WORK}/MacMint.zip.sha256")
ACTUAL=$(shasum -a 256 "${WORK}/MacMint.zip" | awk '{print $1}')
[[ "${EXPECTED}" == "${ACTUAL}" ]] || die "Checksum mismatch: expected ${EXPECTED}, got ${ACTUAL}."
ditto -x -k "${WORK}/MacMint.zip" "${WORK}/extracted"
NEW="${WORK}/extracted/MacMint.app"
[[ -d "${NEW}" ]] || die "The zip does not contain MacMint.app."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${NEW}/Contents/Info.plist")" == "${APP_ID}" ]] \
  || die "Unexpected bundle identifier in the download."
codesign --verify --deep --strict "${NEW}" || die "The downloaded app's signature does not verify."

[[ -w /Applications ]] || die "/Applications isn't writable by this account; use an administrator account."
quit_running_app

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "${BACKUPS}/${STAMP}"
step "Backing up the current app and your data to ${BACKUPS}/${STAMP}..."
if [[ -d "${DATA}" ]]; then ditto "${DATA}" "${BACKUPS}/${STAMP}/Application Support/MacMint"; fi
if [[ -d "${DEST}" ]]; then mv "${DEST}" "${BACKUPS}/${STAMP}/MacMint.app"; fi

step "Installing..."
if ! ditto "${NEW}" "${DEST}"; then
  rm -rf "${DEST}"
  [[ -d "${BACKUPS}/${STAMP}/MacMint.app" ]] && mv "${BACKUPS}/${STAMP}/MacMint.app" "${DEST}"
  die "Install failed; the previous copy was put back."
fi
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
register "${DEST}"
printf '%s %s %s\n' "${STAMP}" "${SHA}" "${TARGET}" >> "${BACKUPS}/installed.log"
# Keep the newest five backups this script made (folders named like 20261019-181500).
ls -1d "${BACKUPS}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | sort -r | tail -n +6 \
  | while read -r old; do rm -rf "$old"; done

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DEST}/Contents/Info.plist" 2>/dev/null || echo "?")
printf '✓ Installed MacMint %s from %s @ %s in %ss\n' "${VERSION}" "${TARGET}" "${SHA:0:7}" "$(( $(date +%s) - STARTED ))"
printf '  Previous copy and data backup: %s\n  Undo: %s --rollback\n' "${BACKUPS}/${STAMP}" "$0"
[[ "${LAUNCH}" == 1 ]] && open "${DEST}"
exit 0
