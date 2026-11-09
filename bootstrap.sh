#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMPILER_SCRIPT="$SCRIPT_DIR/build_from_source_to_deb.sh"
MPS_DIR="$SCRIPT_DIR/mod_pagespeed"
ARTIFACT_DIR="$SCRIPT_DIR/artifacts"
SYSTEM_SETUP_MARKER="$SCRIPT_DIR/.system_setup_complete"
RESUME_BUILD="${RESUME_BUILD:-0}"
SYSTEM_SETUP_DONE=0
if [ "$RESUME_BUILD" = "1" ]; then
  if [ -f "$SYSTEM_SETUP_MARKER" ]; then
    SYSTEM_SETUP_DONE=1
  else
    for prior_clone in "$SCRIPT_DIR/work"/ngx_pagespeed-*; do
      if [ -d "$prior_clone/.git" ]; then
        # Older script versions did not write the setup marker. A compiler
        # workspace proves bootstrap passed package and nginx-source setup.
        touch "$SYSTEM_SETUP_MARKER"
        SYSTEM_SETUP_DONE=1
        break
      fi
    done
  fi
fi

NGX_PAGESPEED_REPO="${NGX_PAGESPEED_REPO:-https://github.com/bantilan/ngx_pagespeed.git}"
NGX_PAGESPEED_REF="${NGX_PAGESPEED_REF:-master}"
NGX_MPS_REPO="${NGX_MPS_REPO:-https://github.com/bantilan/mod_pagespeed.git}"
NGX_MPS_REF="${NGX_MPS_REF:-master}"

log() {
  printf '[zero-scratch] %s\n' "$*"
}

fail() {
  printf '[zero-scratch] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$COMPILER_SCRIPT" ] || fail "Missing bundled compiler: $COMPILER_SCRIPT"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || fail "sudo is required for package installation."
  SUDO=(sudo)
  if [ "$SYSTEM_SETUP_DONE" != "1" ]; then
    sudo -v
  fi
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
else
  fail "Cannot identify this operating system. This bootstrap supports Ubuntu 24.04 (Noble)."
fi

[ "${ID:-}" = ubuntu ] || fail "This build setup currently supports Ubuntu only."
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[ "$CODENAME" = noble ] || fail "This build setup targets Ubuntu 24.04 (Noble); detected '${CODENAME:-unknown}'."
[ "$(dpkg --print-architecture)" = amd64 ] || fail "This build setup targets amd64/x86_64."

if [ "$SYSTEM_SETUP_DONE" = "1" ]; then
  log "System prerequisites already set up; skipping apt and nginx repository setup."
else
  log "Installing bootstrap tools."
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y \
    build-essential ca-certificates curl dpkg-dev fakeroot g++ git gnupg \
    apache2 autoconf default-jre-headless debhelper devscripts gperf \
    libev-dev libexpat1-dev libmodsecurity-dev libpcre3-dev libssl-dev libtool memcached \
    lsb-release net-tools pkg-config psmisc python3 rsync subversion sudo uuid-dev \
    valgrind wget zlib1g-dev ssl-cert

  KEY_TMP="$(mktemp)"
  trap 'rm -f "$KEY_TMP"' EXIT
  curl -fsSL https://nginx.org/keys/nginx_signing.key -o "$KEY_TMP"
  KEY_FINGERPRINTS="$(gpg --batch --show-keys --with-colons "$KEY_TMP" | awk -F: '$1 == "fpr" { print $10 }')"
  grep -Fxq 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 <<< "$KEY_FINGERPRINTS" || \
    fail "nginx signing key fingerprint did not match the expected value."
  gpg --batch --dearmor < "$KEY_TMP" | "${SUDO[@]}" tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
  "${SUDO[@]}" chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg

  NGINX_SOURCE_LIST=/etc/apt/sources.list.d/nginx-mainline-source.list
  NGINX_SOURCE_LINE="deb-src [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu $CODENAME nginx"
  if [ ! -f "$NGINX_SOURCE_LIST" ] || ! grep -Fxq "$NGINX_SOURCE_LINE" "$NGINX_SOURCE_LIST"; then
    printf '%s\n' "$NGINX_SOURCE_LINE" | "${SUDO[@]}" tee "$NGINX_SOURCE_LIST" >/dev/null
  fi
  # Keep Nginx source packages in the dedicated list above, avoiding duplicate
  # deb-src entries when Ubuntu's deb822 sources also include nginx.org.
  UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu.sources
  if [ -f "$UBUNTU_SOURCES" ]; then
    "${SUDO[@]}" python3 - "$UBUNTU_SOURCES" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
blocks = re.split(r'(\n[ \t]*\n)', text)
updated = False
for index in range(0, len(blocks), 2):
    block = blocks[index]
    if re.search(r'(?m)^URIs:[ \t]*https://nginx\.org/packages/mainline/ubuntu[ \t]*$', block):
        changed, count = re.subn(r'(?m)^Types:[ \t]*deb[ \t]+deb-src[ \t]*$', 'Types: deb', block)
        if count:
            blocks[index] = changed
            updated = True
if updated:
    path.write_text(''.join(blocks))
    print('Moved the nginx.org deb-src entry to nginx-mainline-source.list.')
PY
  fi
  "${SUDO[@]}" apt-get update
  touch "$SYSTEM_SETUP_MARKER"
fi

if [ ! -d "$MPS_DIR/.git" ]; then
  [ ! -e "$MPS_DIR" ] || fail "$MPS_DIR exists but is not a Git checkout; move it aside and rerun."
  log "Cloning mod_pagespeed at $NGX_MPS_REF."
  GIT_REFERENCE_CACHE="$SCRIPT_DIR/work/git-reference-cache.git"
  if [ -d "$GIT_REFERENCE_CACHE" ]; then
    git clone --reference-if-able "$GIT_REFERENCE_CACHE" "$NGX_MPS_REPO" "$MPS_DIR"
  else
    git clone "$NGX_MPS_REPO" "$MPS_DIR"
  fi
else
  [ -z "$(git -C "$MPS_DIR" status --porcelain)" ] || \
    fail "$MPS_DIR has local changes; preserve them before changing revisions."
fi

# Reuse an existing clean checkout and move it to the requested pinned revision.
git -C "$MPS_DIR" remote set-url origin "$NGX_MPS_REPO"
git -C "$MPS_DIR" fetch origin "$NGX_MPS_REF"
MPS_TARGET="$(git -C "$MPS_DIR" rev-parse FETCH_HEAD)"
if [ "$(git -C "$MPS_DIR" rev-parse HEAD)" != "$MPS_TARGET" ]; then
  git -C "$MPS_DIR" checkout --detach "$MPS_TARGET"
fi
[ "$(git -C "$MPS_DIR" rev-parse HEAD)" = "$MPS_TARGET" ] || \
  fail "Could not check out requested mod_pagespeed ref $NGX_MPS_REF."
log "Using mod_pagespeed commit $MPS_TARGET."

log "Building nginx mainline source with ngx_pagespeed and mod_pagespeed."
NGX_PAGESPEED_REPO="$NGX_PAGESPEED_REPO" \
NGX_PAGESPEED_REF="$NGX_PAGESPEED_REF" \
NGX_MPS_REPO="$NGX_MPS_REPO" \
NGX_MPS_REF="$NGX_MPS_REF" \
RESUME_BUILD="$RESUME_BUILD" \
RESUME_BUILD_DIR="${RESUME_BUILD_DIR:-}" \
  bash "$COMPILER_SCRIPT"

mkdir -p "$ARTIFACT_DIR"
shopt -s nullglob
DEB_FILES=("$SCRIPT_DIR"/nginx-build/*.deb)
[ "${#DEB_FILES[@]}" -gt 0 ] || fail "The compiler finished without producing Debian packages."
cp -f -- "${DEB_FILES[@]}" "$ARTIFACT_DIR/"

PSOL_TARBALL="$(find "$SCRIPT_DIR/work" -type f -name 'psol-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
if [ -n "$PSOL_TARBALL" ]; then
  cp -f -- "$PSOL_TARBALL" "$ARTIFACT_DIR/"
fi

log "Build completed. Packages and PSOL tarball are in: $ARTIFACT_DIR"
for deb in "${DEB_FILES[@]}"; do
  printf '%s\n' "$ARTIFACT_DIR/$(basename "$deb")"
done
