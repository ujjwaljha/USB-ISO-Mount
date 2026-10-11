#!/usr/bin/env bash
#
# Cloud Agent setup for USB ISO Mount.
#
# Installs the Flutter SDK (which bundles the Dart SDK) and the Linux tools the
# best-effort `usb_iso` CLI shells out to, then fetches package dependencies for
# the Flutter app and the two Dart packages. Safe to run repeatedly: every step
# is guarded so a second run is a fast no-op.
#
# The app targets macOS/Windows only (no Flutter Linux desktop target), so this
# environment is for building, analyzing, and testing all packages and for
# running the command-line tool.
set -euo pipefail

# Flutter 3.44.9 bundles Dart 3.12.2, satisfying the repo's constraints
# (flutter >= 3.38.0, dart >= 3.11.5 < 4.0.0).
FLUTTER_VERSION="3.44.9"
FLUTTER_HOME="${HOME}/flutter"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Installing system packages the Linux CLI relies on"
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  ${SUDO} apt-get update -y
  # curl/git/xz for fetching Flutter; python3 for the CLI raw-write path;
  # parted/dosfstools/ntfs-3g/wimtools/eject/util-linux for real USB writes.
  ${SUDO} apt-get install "${APT_OPTS[@]}" --no-install-recommends \
    ca-certificates curl git xz-utils unzip \
    python3 \
    util-linux parted dosfstools ntfs-3g wimtools eject
fi

echo "==> Installing Flutter ${FLUTTER_VERSION} (bundles Dart)"
if [ ! -x "${FLUTTER_HOME}/bin/flutter" ]; then
  tmp_archive="$(mktemp --suffix=.tar.xz)"
  curl -fsSL "${FLUTTER_URL}" -o "${tmp_archive}"
  rm -rf "${FLUTTER_HOME}"
  tar -xf "${tmp_archive}" -C "${HOME}"
  rm -f "${tmp_archive}"
else
  echo "    Flutter already present at ${FLUTTER_HOME}"
fi

# Silence the "dubious ownership" git warning inside the Flutter checkout.
git config --global --add safe.directory "${FLUTTER_HOME}" || true

export PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"

# Expose flutter/dart on the default PATH for interactive and non-login shells.
if [ -n "${SUDO}" ] || [ -w /usr/local/bin ]; then
  ${SUDO} ln -sf "${FLUTTER_HOME}/bin/flutter" /usr/local/bin/flutter || true
  ${SUDO} ln -sf "${FLUTTER_HOME}/bin/dart" /usr/local/bin/dart || true
fi
# Also persist on PATH for interactive bash sessions.
BASHRC="${HOME}/.bashrc"
if [ -f "${BASHRC}" ] && ! grep -q 'flutter/bin' "${BASHRC}" 2>/dev/null; then
  {
    echo ''
    echo '# Flutter SDK (added by .cursor/install.sh)'
    echo "export PATH=\"${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:\$PATH\""
  } >> "${BASHRC}"
fi

flutter --version
flutter config --no-analytics >/dev/null 2>&1 || true

echo "==> Fetching Dart/Flutter dependencies"
( cd "${REPO_ROOT}/packages/usb_iso_core" && dart pub get )
( cd "${REPO_ROOT}/packages/usb_iso_cli" && dart pub get )
( cd "${REPO_ROOT}/app" && flutter pub get )

echo "==> Setup complete"
