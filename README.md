# Nginx Compiler

This folder is a portable build starter for a clean Ubuntu 24.04 (Noble) x86_64 computer. Copy the entire folder to the computer; keep `bootstrap.sh` and `build_from_source_to_deb.sh` together.

Run it from any current directory by passing the script's full path. For example, if the folder is in your home directory:

```bash
bash "$HOME/ngx_compiler/bootstrap.sh"
```

The script installs build prerequisites (including `libmodsecurity-dev`), configures nginx.org's mainline source repository, fetches the latest `master` revisions of `ngx_pagespeed` and `mod_pagespeed`, downloads the latest available nginx mainline Debian source, builds the packages, and collects the `.deb` packages and PSOL tarball in `artifacts/` beside the script. The compiler also fetches the latest `master` of the ModSecurity-nginx connector, builds it against libmodsecurity, and verifies its `.so` is in the output packages.

The Nginx build string and every Debian package version include the seven-character `mod_pagespeed` and `ngx_pagespeed` commit IDs. The `artifacts/nginx_version` file records the `nginx -v` style version string; package files include the same revisions, for example `nginx_1.31.8-1-pagespeed-mps-d16d084-ngx-61c1c5a_amd64.deb`.

To activate the connector after installation, load `modules/ngx_http_modsecurity_module.so` in the main Nginx context and configure ModSecurity rules. Building the connector alone does not turn the WAF on.

Requirements: Ubuntu 24.04 Noble on x86_64, an internet connection, and a user account with `sudo` access. Do not run the script itself with `sudo`; it invokes `sudo` for system package setup.

By default, the `*_REF` settings follow `master` at build time. Set `NGX_PAGESPEED_REF`, `NGX_MPS_REF`, or `NGX_MODSECURITY_NGINX_REF` to a commit hash to make a build reproducible. Repository URLs can be overridden with `NGX_PAGESPEED_REPO`, `NGX_MPS_REPO`, and `NGX_MODSECURITY_NGINX_REPO`.

## Resume a failed build

The compiler keeps each timestamped source checkout under `work/`.
To retry after fixing a build error, preserve that folder and rerun with
`RESUME_BUILD=1`. The compiler reuses the newest matching checkout, retaining
completed object files so `make` can rebuild only what changed. On resume, JS
artifacts are not forcibly deleted. If the mod_pagespeed ref changed, pass its
new commit hash as usual; the saved checkout is updated to that revision.
Completed system setup is recorded, so retries skip apt and nginx repository
setup. A dirty `mod_pagespeed` checkout in `mod_pagespeed/` is never overwritten.

```bash
cd /path/to/ngx_compiler
RESUME_BUILD=1 NGX_MPS_REF=<new-full-commit-hash> bash ./bootstrap.sh
```

If there is more than one prior checkout, choose one explicitly with
`RESUME_BUILD_DIR=/absolute/path/to/ngx_pagespeed-checkout`. Omit
`RESUME_BUILD=1` for a clean build in a new timestamped checkout.
