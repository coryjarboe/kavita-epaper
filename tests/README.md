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
| `update_harness.sh` | Runs `deploy/update.sh` (this checkout's and the one from `OLD_REF`, default `v0.7.20`) with all system paths redirected to a temp dir and `systemctl` and `pip` stubbed. Checks unit sync and rollback, pip-before-stop, and the handoff. Needs `git`, `rsync` and `systemd-analyze`. |

## Running

Ports 18095, 18096, 18097, 18099 and 18443 must be free.

```bash
/tmp/ke-test-venv/bin/python tests/test_app.py
/tmp/ke-test-venv/bin/python tests/test_proxy.py
/tmp/ke-test-venv/bin/python tests/test_login_errors.py
tests/update_harness.sh
```

Each script prints one `PASS` or `FAIL` line per check, a final count, and exits
non-zero on any failure. Logs, the cover cache and harness files go to a new
temp directory, printed on the first line. Set `KE_TEST_WORK=<dir>` (Python
tests) or pass a directory as the harness's first argument to choose it.
`OLD_REF=v0.7.19 tests/update_harness.sh` tests the upgrade from another release.
