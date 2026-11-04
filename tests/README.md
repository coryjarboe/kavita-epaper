# Tests

Developer tests for kavita-epaper. They are not part of the release tarball
and never touch an installed copy: everything runs on 127.0.0.1 scratch ports
or in a temporary directory.

## Setup

From the repo root, make a separate venv (not the one in `/opt/kavita-epaper`):

```bash
python3 -m venv /tmp/ke-test-venv
/tmp/ke-test-venv/bin/pip install -r tests/requirements.txt
```

`tests/requirements.txt` adds `itsdangerous`, only to mint cookies in the old
pre-0.7.19 format.

## What's here

| file | what it does |
|---|---|
| `kavita_stub.py` | Fake Kavita: users `alice` and `bob` (password `pw`), Kavita-shaped JWTs, covers, and control endpoints (`/_deny`, `/_allow`, `/_expire`, `/_hits`, `/_reset`). `JWT_PAD` and `REFRESH_LEN` set token sizes. |
| `test_app.py` | Starts the stub on 18096 and the real app (uvicorn, from this checkout) on 18095, five times with different settings. Covers cookie encryption and size, stale or foreign cookies, secret rotation, token refresh, the per-user cover cache and its cleanup, and `X-Forwarded-*` trust. |
| `test_login_errors.py` | Sign-in error messages against the stub, a non-Kavita web server, a self-signed TLS server, a closed port, an unknown host and an unroutable address; that Kavita's own refusal messages are passed through but tokens and passwords never are; that only private or loopback clients see the Kavita URL; and that the app refuses to start (exit 78) with a missing, placeholder or short secret. Uses ports 18096, 18097, 18099, 18195 and 18443. |
| `test_proxy.py` | Runs the app in-process behind uvicorn's proxy-header middleware with `192.0.2.10` trusted, to check the exact proxy address gets `https` and the Secure flag while another client can't fake them, plus the comma-list, CIDR and hostname forms of the allow-list. |
| `test_kavita_tls.py` | `/healthz` (200, 503 with a reason, the 10 s cache, kept out of the access log), Kavita over HTTPS with a throwaway private CA (`KAVITA_CA_BUNDLE`, `KAVITA_TLS_VERIFY=false`, and bad settings refusing to start), and `python -m app.kavita_check` as `install.sh` runs it. Uses ports 18096, 18097, 18195 and 18443. |
| `install_harness.sh` | Runs `deploy/install.sh` with every system path redirected to a temp dir. apt, dpkg, useradd, hostname and the Python version check are stubbed; the `systemctl` stub really starts the installed app on 127.0.0.1:18295, so the health wait, exit 78 and a busy port are real. Kavita is the stub on 18396. Covers the flag, the environment variable, the terminal prompt, an unreachable Kavita, an existing `.env`, `--overwrite-env` backups, not root, old Python and the TLS settings. Needs `git`, `rsync` and `script`. |
| `update_harness.sh` | Runs `deploy/update.sh` and `deploy/configure` (and v0.7.22's `update.sh` for the migration) with every system path redirected to a temp dir. Its `systemctl` stub really starts the installed app on 127.0.0.1:18295 and pip runs offline from a local wheelhouse, so health checks, rollbacks and "no network" are real. Covers the migration from the old layout, updates with and without new dependencies, older tarballs, every failure path (venv build, start, login page, unit, crash mid-swap, both versions broken), Kavita down, unit sync and backup pruning, the secret check, `--status`, `--rollback` (including toggling and a broken previous version) and every `configure` command. Needs network once for `pip download`, plus `git`, `rsync`, `script` and `systemd-analyze`. |

## Running

Ports 18095, 18096, 18097, 18099, 18195, 18295, 18396, 18399 and 18443 must be free.

```bash
/tmp/ke-test-venv/bin/python tests/test_app.py
/tmp/ke-test-venv/bin/python tests/test_proxy.py
/tmp/ke-test-venv/bin/python tests/test_login_errors.py
/tmp/ke-test-venv/bin/python tests/test_kavita_tls.py
tests/install_harness.sh
tests/update_harness.sh
```

Each script prints one `PASS` or `FAIL` line per check, a final count, and exits
non-zero on any failure. Logs, the cover cache and harness files go to a new
temp directory, printed on the first line. Set `KE_TEST_WORK=<dir>` (Python
tests) or pass a directory as the harness's first argument to choose it.
`OLD_REF=v0.7.19 tests/update_harness.sh` tests the upgrade from another release.
