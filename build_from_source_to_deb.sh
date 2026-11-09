#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LOG_DIR="$SCRIPT_DIR/logs"
WORK_DIR="$SCRIPT_DIR/work"
NGINX_SOURCE_WORKDIR="$ROOT_DIR/nginx-build"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/ngx_compiler_${TIMESTAMP}.log"
RESUME_BUILD="${RESUME_BUILD:-0}"
LAST_BUILD_FILE="$WORK_DIR/last_build_dir"
LAST_BUILD_SOURCE_FILE="$WORK_DIR/last_build_source"
RESUME_BUILD_DIR="${RESUME_BUILD_DIR:-}"

NGINX_DEB_SRC_DIR="${NGINX_DEB_SRC_DIR:-}"
RULES_FILE=""
DEBIAN_NGINX_CONF=""
DEBIAN_NGINX_SERVICE=""
DEBIAN_NGINX_DEBUG_SERVICE=""
DEBIAN_CHANGELOG=""

mkdir -p "$LOG_DIR"
mkdir -p "$WORK_DIR"
touch "$LOG_FILE"

case "$RESUME_BUILD" in
  0|1) ;;
  *) printf '[ngx_compiler] ERROR: RESUME_BUILD must be 0 or 1.\n' >&2; exit 1 ;;
esac

log() {
  echo "[ngx_compiler] $*" | tee -a "$LOG_FILE"
}

run() {
  log "RUN: $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing command: $1"
    exit 1
  }
}

for cmd in bash git cp chmod tar ls tee find sed head rm sudo dpkg-buildpackage dpkg-parsechangelog nproc apt-get dpkg-query python3; do
  require_cmd "$cmd"
done

ensure_nginx_source() {
  if [ -n "$NGINX_DEB_SRC_DIR" ] && [ -d "$NGINX_DEB_SRC_DIR/debian" ]; then
    return 0
  fi

  if [ "$RESUME_BUILD" = "1" ]; then
    local existing_source
    existing_source="$(find "$NGINX_SOURCE_WORKDIR" -maxdepth 1 -mindepth 1 \
      -type d -name 'nginx-*' -exec test -d '{}/debian' \; -print \
      | sort -V | tail -n 1 || true)"
    if [ -n "$existing_source" ]; then
      NGINX_DEB_SRC_DIR="$existing_source"
      log "Resuming with existing nginx source: $NGINX_DEB_SRC_DIR"
      return 0
    fi
  fi

  log "nginx Debian source not found at: $NGINX_DEB_SRC_DIR"
  log "Bootstrapping nginx build prerequisites via apt."
  run sudo apt-get update
  run sudo apt-get build-dep -y nginx

  mkdir -p "$NGINX_SOURCE_WORKDIR"
  log "Fetching nginx Debian source via apt-get source nginx"
  run bash -lc "cd '$NGINX_SOURCE_WORKDIR' && apt-get source nginx"

  local detected_dir
  detected_dir="$(find "$NGINX_SOURCE_WORKDIR" -maxdepth 1 -mindepth 1 -type d -name 'nginx-*' | sort -V | tail -n 1 || true)"
  if [ -z "$detected_dir" ]; then
    log "Unable to find extracted nginx-* source dir under $NGINX_SOURCE_WORKDIR"
    exit 1
  fi
  NGINX_DEB_SRC_DIR="$detected_dir"
  log "Detected nginx Debian source dir: $NGINX_DEB_SRC_DIR"
}

ensure_modsecurity_dev_package() {
  if dpkg-query -W -f='${Status}' libmodsecurity-dev 2>/dev/null | grep -qx 'install ok installed'; then
    log "libmodsecurity-dev is already installed."
    return 0
  fi

  log "Installing libmodsecurity-dev required by the ModSecurity Nginx connector."
  run sudo apt-get update
  run sudo apt-get install -y libmodsecurity-dev
}

set_nginx_paths() {
  RULES_FILE="$NGINX_DEB_SRC_DIR/debian/rules"
  DEBIAN_NGINX_CONF="$NGINX_DEB_SRC_DIR/debian/nginx.conf"
  DEBIAN_NGINX_SERVICE="$NGINX_DEB_SRC_DIR/debian/nginx.service"
  DEBIAN_NGINX_DEBUG_SERVICE="$NGINX_DEB_SRC_DIR/debian/nginx-debug.service"
  DEBIAN_CHANGELOG="$NGINX_DEB_SRC_DIR/debian/changelog"
}

ensure_nginx_source
ensure_modsecurity_dev_package
set_nginx_paths

if [ ! -f "$RULES_FILE" ]; then
  log "Missing Debian rules file: $RULES_FILE"
  exit 1
fi

if [ ! -f "$DEBIAN_NGINX_CONF" ]; then
  log "Missing Debian nginx.conf file: $DEBIAN_NGINX_CONF"
  exit 1
fi

if [ ! -f "$DEBIAN_NGINX_SERVICE" ]; then
  log "Missing Debian nginx.service file: $DEBIAN_NGINX_SERVICE"
  exit 1
fi

if [ ! -f "$DEBIAN_NGINX_DEBUG_SERVICE" ]; then
  log "Missing Debian nginx-debug.service file: $DEBIAN_NGINX_DEBUG_SERVICE"
  exit 1
fi

DEFAULT_REPO_URL="https://github.com/bantilan/ngx_pagespeed.git"
REPO_URL="${NGX_PAGESPEED_REPO:-$DEFAULT_REPO_URL}"
REPO_REF="${NGX_PAGESPEED_REF:-master}"
if [ "$RESUME_BUILD" = "1" ]; then
  if [ -z "$RESUME_BUILD_DIR" ]; then
    if [ -f "$LAST_BUILD_FILE" ]; then
      RESUME_BUILD_DIR="$(cat "$LAST_BUILD_FILE")"
    else
      # Support workspaces created by older script versions, which did not
      # save a last-build pointer.
      mapfile -t CANDIDATE_DIRS < <(ls -1dt "$WORK_DIR"/ngx_pagespeed-* 2>/dev/null || true)
      for candidate in "${CANDIDATE_DIRS[@]}"; do
        if [ -d "$candidate/.git" ] &&
           [ "$(git -C "$candidate" remote get-url origin)" = "$REPO_URL" ]; then
          RESUME_BUILD_DIR="$candidate"
          printf '%s\n' "$candidate" > "$LAST_BUILD_FILE"
          break
        fi
      done
    fi
    [ -n "$RESUME_BUILD_DIR" ] || {
      log "No matching prior workspace found under $WORK_DIR."
      exit 1
    }
  fi
  CLONE_DIR="$(cd "$RESUME_BUILD_DIR" && pwd -P)"
  [ -d "$CLONE_DIR/.git" ] || {
    log "Saved workspace is not a git checkout: $CLONE_DIR"
    exit 1
  }
  [ "$(git -C "$CLONE_DIR" remote get-url origin)" = "$REPO_URL" ] || {
    log "Workspace origin does not match NGX_PAGESPEED_REPO: $CLONE_DIR"
    exit 1
  }
  if [ -f "$LAST_BUILD_SOURCE_FILE" ]; then
    mapfile -t SAVED_SOURCE < "$LAST_BUILD_SOURCE_FILE"
    [ "${SAVED_SOURCE[0]:-}" = "$REPO_URL" ] &&
      [ "${SAVED_SOURCE[1]:-}" = "$REPO_REF" ] || {
        log "Saved workspace uses a different ngx_pagespeed repo/ref. Start a clean build or select its matching ref."
        exit 1
      }
  elif [ "$REPO_REF" != "HEAD" ]; then
    expected_source="$(git -C "$CLONE_DIR" rev-parse "$REPO_REF^{commit}" 2>/dev/null || true)"
    [ -n "$expected_source" ] &&
      [ "$(git -C "$CLONE_DIR" rev-parse HEAD)" = "$expected_source" ] || {
        log "Cannot verify the older workspace against NGX_PAGESPEED_REF=$REPO_REF."
        exit 1
      }
  fi
  log "Resuming existing build workspace: $CLONE_DIR"
else
  CLONE_DIR="$WORK_DIR/ngx_pagespeed-${TIMESTAMP}-$$"
fi
DEFAULT_MPS_REPO="https://github.com/bantilan/mod_pagespeed.git"
MPS_REPO="${NGX_MPS_REPO:-$DEFAULT_MPS_REPO}"
MPS_REF="${NGX_MPS_REF:-master}"
MODSECURITY_NGINX_REPO="${NGX_MODSECURITY_NGINX_REPO:-https://github.com/owasp-modsecurity/ModSecurity-nginx.git}"
MODSECURITY_NGINX_REF="${NGX_MODSECURITY_NGINX_REF:-master}"

log "Build log: $LOG_FILE"
log "GitHub repo: $REPO_URL"
log "Git ref: $REPO_REF"
log "mod_pagespeed repo override: $MPS_REPO"
log "mod_pagespeed ref override: $MPS_REF"
log "ModSecurity-nginx repo: $MODSECURITY_NGINX_REPO"
log "ModSecurity-nginx ref: $MODSECURITY_NGINX_REF"
if [ "$RESUME_BUILD" = "0" ]; then
  log "Fresh clone target: $CLONE_DIR"
  log "Step 1/4: Clone ngx_pagespeed source (from scratch)."
  run git clone "$REPO_URL" "$CLONE_DIR"
  printf '%s\n' "$CLONE_DIR" > "$LAST_BUILD_FILE"
  if [ -n "$REPO_REF" ] && [ "$REPO_REF" != "HEAD" ]; then
    run git -C "$CLONE_DIR" checkout "$REPO_REF"
  fi
  printf '%s\n%s\n' "$REPO_URL" "$REPO_REF" > "$LAST_BUILD_SOURCE_FILE"
else
  log "Reusing the saved ngx_pagespeed checkout; completed build outputs are preserved."
fi

run git -C "$CLONE_DIR" submodule update --init testing-dependencies/mod_pagespeed
run git -C "$CLONE_DIR/testing-dependencies/mod_pagespeed" remote set-url origin "$MPS_REPO"
run git -C "$CLONE_DIR/testing-dependencies/mod_pagespeed" fetch origin "$MPS_REF"
run git -C "$CLONE_DIR/testing-dependencies/mod_pagespeed" checkout FETCH_HEAD
run git -C "$CLONE_DIR" add testing-dependencies/mod_pagespeed

# Stamp the exact source revisions into nginx -v/-V without changing the
# upstream nginx version or its HTTP Server header.
MPS_SHA="$(git -C "$CLONE_DIR/testing-dependencies/mod_pagespeed" rev-parse HEAD)"
MPS_SHA="${MPS_SHA:0:7}"
NGX_SHA="$(git -C "$CLONE_DIR" rev-parse HEAD)"
NGX_SHA="${NGX_SHA:0:7}"
NGINX_BUILD_METADATA="pagespeed-mps-${MPS_SHA}-ngx-${NGX_SHA}"
log "Nginx build metadata: $NGINX_BUILD_METADATA"

SOURCE_PACKAGE_VERSION="$(dpkg-parsechangelog -l "$DEBIAN_CHANGELOG" -S Version)"
VERSION_WITHOUT_EPOCH="${SOURCE_PACKAGE_VERSION#*:}"
UPSTREAM_NGINX_VERSION="${VERSION_WITHOUT_EPOCH%%-*}"
DEBIAN_REVISION="${VERSION_WITHOUT_EPOCH#*-}"
DEBIAN_REVISION="${DEBIAN_REVISION%%~*}"
DEBIAN_REVISION="${DEBIAN_REVISION%%-pagespeed-mps-*}"
[ -n "$UPSTREAM_NGINX_VERSION" ] && [ -n "$DEBIAN_REVISION" ] || {
  log "Could not derive the upstream version and Debian revision from $SOURCE_PACKAGE_VERSION"
  exit 1
}
NGINX_PACKAGE_VERSION="${UPSTREAM_NGINX_VERSION}-${DEBIAN_REVISION}-${NGINX_BUILD_METADATA}"
NGINX_DISPLAY_VERSION="nginx/${UPSTREAM_NGINX_VERSION} (${NGINX_BUILD_METADATA})"
log "Nginx package version: $NGINX_PACKAGE_VERSION"

MODSECURITY_NGINX_DIR="$CLONE_DIR/testing-dependencies/ModSecurity-nginx"
mkdir -p "$(dirname "$MODSECURITY_NGINX_DIR")"
if git -C "$CLONE_DIR" ls-files --error-unmatch testing-dependencies/ModSecurity-nginx >/dev/null 2>&1; then
  run git -C "$CLONE_DIR" submodule update --init -- testing-dependencies/ModSecurity-nginx
else
  if [ ! -d "$MODSECURITY_NGINX_DIR/.git" ] && [ ! -f "$MODSECURITY_NGINX_DIR/.git" ]; then
    [ ! -e "$MODSECURITY_NGINX_DIR" ] || {
      log "ModSecurity-nginx path exists but is not a Git checkout: $MODSECURITY_NGINX_DIR"
      exit 1
    }
    run git clone "$MODSECURITY_NGINX_REPO" "$MODSECURITY_NGINX_DIR"
  fi
fi
[ -z "$(git -C "$MODSECURITY_NGINX_DIR" status --porcelain)" ] || {
    log "ModSecurity-nginx checkout has local changes; preserve them before updating it."
    exit 1
}
run git -C "$MODSECURITY_NGINX_DIR" remote set-url origin "$MODSECURITY_NGINX_REPO"
run git -C "$MODSECURITY_NGINX_DIR" fetch origin "$MODSECURITY_NGINX_REF"
MODSECURITY_NGINX_TARGET="$(git -C "$MODSECURITY_NGINX_DIR" rev-parse FETCH_HEAD)"
if [ "$(git -C "$MODSECURITY_NGINX_DIR" rev-parse HEAD)" != "$MODSECURITY_NGINX_TARGET" ]; then
  [ -z "$(git -C "$MODSECURITY_NGINX_DIR" status --porcelain)" ] || {
    log "ModSecurity-nginx checkout is dirty; refusing to switch revisions."
    exit 1
  }
  run git -C "$MODSECURITY_NGINX_DIR" checkout --detach "$MODSECURITY_NGINX_TARGET"
fi
log "Using ModSecurity-nginx commit $MODSECURITY_NGINX_TARGET."

# Apply the workspace's PSOL build helper when available, so fixes can be
# tested locally before the ngx_pagespeed submodule revision is updated.
LOCAL_NGX_PAGESPEED_DIR="${NGX_PAGESPEED_LOCAL_DIR:-$SCRIPT_DIR/../ngx_pagespeed}"
if [ -f "$LOCAL_NGX_PAGESPEED_DIR/scripts/build_from_scratch_with_fixes.sh" ]; then
  run cp "$LOCAL_NGX_PAGESPEED_DIR/scripts/build_from_scratch_with_fixes.sh" \
    "$CLONE_DIR/scripts/build_from_scratch_with_fixes.sh"
  run chmod +x "$CLONE_DIR/scripts/build_from_scratch_with_fixes.sh"
  log "Applied local override for scripts/build_from_scratch_with_fixes.sh from workspace."
fi

# If a local mod_pagespeed checkout exists, prefer patched build
# helper scripts from local workspace (useful before upstream push).
LOCAL_MPS_DIR="$ROOT_DIR/mod_pagespeed"
if [ -f "$LOCAL_MPS_DIR/install/build_psol.sh" ]; then
  run cp "$LOCAL_MPS_DIR/install/build_psol.sh" \
    "$CLONE_DIR/testing-dependencies/mod_pagespeed/install/build_psol.sh"
  run chmod +x "$CLONE_DIR/testing-dependencies/mod_pagespeed/install/build_psol.sh"
  log "Applied local override for install/build_psol.sh from workspace."
fi
if [ -f "$LOCAL_MPS_DIR/net/instaweb/instaweb.gyp" ]; then
  run cp "$LOCAL_MPS_DIR/net/instaweb/instaweb.gyp" \
    "$CLONE_DIR/testing-dependencies/mod_pagespeed/net/instaweb/instaweb.gyp"
  log "Applied local override for net/instaweb/instaweb.gyp from workspace."
fi

SKIP_PSOL_BUILD="${SKIP_PSOL_BUILD:-0}"
PSOL_TARBALL_PATH="${PSOL_TARBALL_PATH:-}"
NGX_PAGESPEED_BUILD_JS="${NGX_PAGESPEED_BUILD_JS:-1}"
if [ "$RESUME_BUILD" = "1" ]; then
  NGX_PAGESPEED_FORCE_JS_REBUILD="${NGX_PAGESPEED_FORCE_JS_REBUILD:-0}"
else
  NGX_PAGESPEED_FORCE_JS_REBUILD="${NGX_PAGESPEED_FORCE_JS_REBUILD:-1}"
fi
CLOSURE_COMPILER_VERSION="${CLOSURE_COMPILER_VERSION:-}"
CLOSURE_DOWNLOAD_BASE="${CLOSURE_DOWNLOAD_BASE:-}"

if [ "$SKIP_PSOL_BUILD" = "1" ]; then
  log "Step 2/4: Skip PSOL source build (SKIP_PSOL_BUILD=1)."
  if [ -n "$PSOL_TARBALL_PATH" ] && [ -f "$PSOL_TARBALL_PATH" ]; then
    PSOL_TARBALL="$PSOL_TARBALL_PATH"
  else
    PSOL_TARBALL="$(ls -1t "$CLONE_DIR"/testing-dependencies/mod_pagespeed/psol-*.tar.gz 2>/dev/null | head -n 1 || true)"
    if [ -z "$PSOL_TARBALL" ]; then
      PSOL_TARBALL="$(ls -1t "$WORK_DIR"/ngx_pagespeed-*/testing-dependencies/mod_pagespeed/psol-*.tar.gz 2>/dev/null | head -n 1 || true)"
    fi
    if [ -z "$PSOL_TARBALL" ] && [ -d "$ROOT_DIR/ngx_pagespeed/testing-dependencies/mod_pagespeed" ]; then
      PSOL_TARBALL="$(ls -1t "$ROOT_DIR"/ngx_pagespeed/testing-dependencies/mod_pagespeed/psol-*.tar.gz 2>/dev/null | head -n 1 || true)"
    fi
  fi
else
  log "Step 2/4: Build PSOL from source in fresh clone."
  log "Using BUILD_JS=$NGX_PAGESPEED_BUILD_JS for JS asset generation."
  log "Using FORCE_JS_REBUILD=$NGX_PAGESPEED_FORCE_JS_REBUILD"
  if [ -n "$CLOSURE_COMPILER_VERSION" ]; then
    log "Using CLOSURE_COMPILER_VERSION=$CLOSURE_COMPILER_VERSION"
  fi
  if [ -n "$CLOSURE_DOWNLOAD_BASE" ]; then
    log "Using CLOSURE_DOWNLOAD_BASE=$CLOSURE_DOWNLOAD_BASE"
  fi
  if [ "$NGX_PAGESPEED_BUILD_JS" = "1" ] && [ "$NGX_PAGESPEED_FORCE_JS_REBUILD" = "1" ]; then
    run bash -lc "cd '$CLONE_DIR/testing-dependencies/mod_pagespeed' && rm -rf out && find net/instaweb/genfiles -type f \\( -name '*_dbg.js' -o -name '*_opt.js' \\) -delete"
    log "Forced JS rebuild by clearing prior generated JS artifacts."
  fi
  run chmod +x "$CLONE_DIR/scripts/build_from_scratch_with_fixes.sh"
  run bash -lc "cd '$CLONE_DIR' && BUILD_JS='$NGX_PAGESPEED_BUILD_JS' CLOSURE_COMPILER_VERSION='$CLOSURE_COMPILER_VERSION' CLOSURE_DOWNLOAD_BASE='$CLOSURE_DOWNLOAD_BASE' JOBS=\${JOBS:-\$(nproc)} bash scripts/build_from_scratch_with_fixes.sh"
  PSOL_TARBALL="$(ls -1t "$CLONE_DIR"/testing-dependencies/mod_pagespeed/psol-*.tar.gz 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$PSOL_TARBALL" ]; then
  log "PSOL tarball not found."
  log "If skipping PSOL build, provide PSOL_TARBALL_PATH=/absolute/path/to/psol-*.tar.gz"
  exit 1
fi
log "PSOL tarball: $PSOL_TARBALL"

log "Step 3/4: Extract PSOL tarball into fresh clone and point debian/rules to it."
run bash -lc "cd '$CLONE_DIR' && tar -xzf '$PSOL_TARBALL'"

if [ ! -f "$CLONE_DIR/psol/lib/Release/linux/x64/pagespeed_automatic.a" ]; then
  log "Expected PSOL static library not found after extraction in clone."
  exit 1
fi

RULES_BACKUP="${RULES_FILE}.ngx_compiler_backup_${TIMESTAMP}"
NGINX_SERVICE_BACKUP="${DEBIAN_NGINX_SERVICE}.ngx_compiler_backup_${TIMESTAMP}"
NGINX_DEBUG_SERVICE_BACKUP="${DEBIAN_NGINX_DEBUG_SERVICE}.ngx_compiler_backup_${TIMESTAMP}"
CHANGELOG_BACKUP="${DEBIAN_CHANGELOG}.ngx_compiler_backup_${TIMESTAMP}"
run cp "$RULES_FILE" "$RULES_BACKUP"
run cp "$DEBIAN_NGINX_SERVICE" "$NGINX_SERVICE_BACKUP"
run cp "$DEBIAN_NGINX_DEBUG_SERVICE" "$NGINX_DEBUG_SERVICE_BACKUP"
run cp "$DEBIAN_CHANGELOG" "$CHANGELOG_BACKUP"
cleanup_rules() {
  if [ -f "$RULES_BACKUP" ]; then
    cp "$RULES_BACKUP" "$RULES_FILE"
  fi
  if [ -f "$NGINX_SERVICE_BACKUP" ]; then
    cp "$NGINX_SERVICE_BACKUP" "$DEBIAN_NGINX_SERVICE"
  fi
  if [ -f "$NGINX_DEBUG_SERVICE_BACKUP" ]; then
    cp "$NGINX_DEBUG_SERVICE_BACKUP" "$DEBIAN_NGINX_DEBUG_SERVICE"
  fi
  if [ -f "$CHANGELOG_BACKUP" ]; then
    cp "$CHANGELOG_BACKUP" "$DEBIAN_CHANGELOG"
  fi
}
trap cleanup_rules EXIT
# Put the source commits in the Debian version so every binary package and
# artifact filename carries the exact module revisions used for this build.
run python3 - "$DEBIAN_CHANGELOG" "$NGINX_PACKAGE_VERSION" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
updated, count = re.subn(
    r'(?m)^nginx \([^)]*\)', 'nginx (%s)' % sys.argv[2], text, count=1)
if count != 1:
    raise SystemExit('Could not update the leading nginx changelog entry')
path.write_text(updated)
PY
# Ensure Debian rules points ngx_pagespeed to the fresh clone.
# Some rule templates already use NGX_PAGESPEED_MODULE; in that case set it.
if grep -q '^NGX_PAGESPEED_MODULE[[:space:]]*=' "$RULES_FILE"; then
  run sed -Ei "s|^NGX_PAGESPEED_MODULE[[:space:]]*=.*$|NGX_PAGESPEED_MODULE = $CLONE_DIR|" "$RULES_FILE"
else
  # Otherwise normalize and inject exactly one ngx_pagespeed dynamic module arg.
  run sed -Ei 's|--add-dynamic-module=[^[:space:]]*ngx_pagespeed[^[:space:]]*||g' "$RULES_FILE"
  run sed -Ei 's|  +| |g' "$RULES_FILE"
  run sed -i "s|\\./configure |./configure --add-dynamic-module=$CLONE_DIR |g" "$RULES_FILE"
fi

# Add the ModSecurity connector to both regular and debug Nginx builds.
run sed -Ei 's|--add-dynamic-module=[^[:space:]]*ModSecurity-nginx[^[:space:]]*||g' "$RULES_FILE"
run sed -Ei 's|  +| |g' "$RULES_FILE"
run sed -i "s|\\./configure |./configure --add-dynamic-module=$MODSECURITY_NGINX_DIR |g" "$RULES_FILE"
run sed -i "s|\\./configure |./configure --build=$NGINX_BUILD_METADATA |g" "$RULES_FILE"

# Ensure nginx package ships built dynamic modules. Replace any stale/bad line
# first so reruns are deterministic.
run bash -lc "sed -i '/debian\\/build-nginx\\/objs\\/\\*\\.so/d' '$NGINX_DEB_SRC_DIR/debian/nginx.install'"
run bash -lc "printf '%s\n' 'debian/build-nginx/objs/*.so usr/lib/nginx/modules' >> '$NGINX_DEB_SRC_DIR/debian/nginx.install'"

for service_file in "$DEBIAN_NGINX_SERVICE" "$DEBIAN_NGINX_DEBUG_SERVICE"; do
  run sed -i 's|^ExecReload=.*|ExecReload=/bin/kill -s HUP $MAINPID|' "$service_file"
  run sed -i 's|^ExecStop=.*|ExecStop=/bin/kill -s TERM $MAINPID|' "$service_file"
done

log "Step 4/4: Build Debian package (requested command)."
# Remove stale output packages so we only inspect artifacts from this run.
run bash -lc "find '$ROOT_DIR/nginx-build' -maxdepth 1 -type f -name '*.deb' -delete"

set +e
run bash -lc "cd '$NGINX_DEB_SRC_DIR' && dpkg-buildpackage -b -us -uc"
DPKG_EXIT=$?
set -e

if [ "$DPKG_EXIT" -ne 0 ]; then
  log "dpkg-buildpackage -b -us -uc exited with code $DPKG_EXIT."
  log "Retrying with sudo: sudo dpkg-buildpackage -b -us -uc"
  set +e
  run bash -lc "cd '$NGINX_DEB_SRC_DIR' && sudo dpkg-buildpackage -b -us -uc"
  DPKG_EXIT=$?
  set -e
fi

mapfile -t DEBS < <(find "$ROOT_DIR/nginx-build" -maxdepth 1 -type f -name "*.deb" | sort)

if [ "${#DEBS[@]}" -eq 0 ]; then
  log "No .deb files found under $ROOT_DIR/nginx-build"
  exit 1
fi

log "Debian package output files:"
for deb in "${DEBS[@]}"; do
  PACKAGE_VERSION="$(dpkg-deb -f "$deb" Version)"
  if [ "$PACKAGE_VERSION" != "$NGINX_PACKAGE_VERSION" ]; then
    log "ERROR: $deb has version $PACKAGE_VERSION, expected $NGINX_PACKAGE_VERSION"
    exit 1
  fi
  log "DEB_OUTPUT: $deb"
done

FOUND_PAGESPEED_SO=0
for deb in "${DEBS[@]}"; do
  if dpkg-deb -c "$deb" | grep 'usr/lib/nginx/modules/ngx_pagespeed.so' >/dev/null; then
    FOUND_PAGESPEED_SO=1
    break
  fi
done

if [ "$FOUND_PAGESPEED_SO" -ne 1 ]; then
  log "ERROR: Built package set does not contain usr/lib/nginx/modules/ngx_pagespeed.so"
  exit 1
fi

FOUND_MODSECURITY_SO=0
for deb in "${DEBS[@]}"; do
  if dpkg-deb -c "$deb" | grep 'usr/lib/nginx/modules/ngx_http_modsecurity_module.so' >/dev/null; then
    FOUND_MODSECURITY_SO=1
    break
  fi
done

if [ "$FOUND_MODSECURITY_SO" -ne 1 ]; then
  log "ERROR: Built package set does not contain usr/lib/nginx/modules/ngx_http_modsecurity_module.so"
  exit 1
fi

mkdir -p "$ROOT_DIR/artifacts"
printf '%s\n' "$NGINX_DISPLAY_VERSION" > "$ROOT_DIR/artifacts/nginx_version"
log "Version record written: $ROOT_DIR/artifacts/nginx_version"

if [ "$DPKG_EXIT" -ne 0 ]; then
  log "Packaging command still returned non-zero ($DPKG_EXIT), but .deb files were found above."
else
  log "Packaging completed successfully."
fi

cleanup_rules
rm -f "$RULES_BACKUP"
rm -f "$NGINX_SERVICE_BACKUP"
rm -f "$NGINX_DEBUG_SERVICE_BACKUP"
rm -f "$CHANGELOG_BACKUP"
trap - EXIT

log "Done."
log "Log saved to: $LOG_FILE"
