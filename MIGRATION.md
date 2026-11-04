# Migrating older kavita-epaper installs

One-time fixes for installs that predate the current `install.sh`. `update.sh` only replaces code; it never rewrites `.env` or creates directories, so older hosts keep whatever their original installer left behind.

## Upgrading from before 0.7.15

Older installers left `/opt/kavita-epaper` owned by the `kavita-epaper` service user, and the `update.sh` they installed executes `.env` as root. For this one upgrade, run the `update.sh` that ships in the new release, not the installed one. Run these from the directory that holds the tarball, or give the tarball's absolute path in both places:

```bash
D=$(mktemp -d)
tar -xzf kavita-epaper-vX.Y.Z.tar.gz -C "$D"
sudo bash "$D/deploy/update.sh" kavita-epaper-vX.Y.Z.tar.gz
rm -rf "$D"
```

It makes the install dir root-owned before reading anything in it, never executes `.env`, and replaces `/opt/kavita-epaper/update.sh` with itself. Don't use the installed `update.sh` for this upgrade: it finishes by handing `app/`, `requirements.txt` and `VERSION` back to the service user. After this, update as usual; from 0.7.15 on, `update.sh` hands off to the copy shipped in each new release by itself.

The service keeps working with a root-only `.env`, because systemd reads it as root before starting the service. If you suspect the service account was compromised, review `.env` for anything you didn't put there before upgrading.

## `.env` from before 0.7.11

Your `.env` was copied from an older template and won't pick up new settings on its own. Compare it with the current template:

```bash
diff /opt/kavita-epaper/.env deploy/env.example
```

(run from an extracted release or a clone). Things to look for:

- `KAVITA_PUBLIC_URL` is ignored since 0.7.11. Delete the line.
- `KAVITA_EPAPER_HOST` and `KAVITA_EPAPER_PORT` aren't listed. The defaults (`0.0.0.0`, `8095`) come from the service file, so you only need them to change the bind address or port.
- `KAVITA_EPAPER_COOKIE_SECURE` also accepts `auto` (the default), which sets the `Secure` flag only on HTTPS requests. Keep `true` if you only ever use HTTPS.
- Old comments may give the wrong default for `KAVITA_EPAPER_RELEASES_DIR`. The real default is `/var/lib/kavita-epaper/releases`.

Keep your existing `KAVITA_EPAPER_SECRET`. Changing it signs everyone out.

Restart after editing:

```bash
sudo systemctl restart kavita-epaper
```

## Missing releases directory

If `sudo /opt/kavita-epaper/update.sh` (no arguments) fails with `Releases dir does not exist`, your install predates the step that creates it. Either create it:

```bash
sudo mkdir -p /var/lib/kavita-epaper/releases
```

or point at the directory where you already keep tarballs by adding this to `.env`:

```
KAVITA_EPAPER_RELEASES_DIR=/path/to/your/tarballs
```

Passing a tarball path, URL or `--github` always works regardless.

## Moving from the old `kavita-boox` name

`update.sh` refuses to apply a `kavita-epaper` tarball to a `kavita-boox` install, because the paths, service name and user all changed. Do a fresh install instead, then remove the old one:

```bash
# both default to port 8095, so stop the old service first
sudo systemctl disable --now kavita-boox
sudo bash ./deploy/install.sh        # from an extracted kavita-epaper release
# copy KAVITA_BASE_URL and any other settings from /opt/kavita-boox/.env;
# variables were renamed from KAVITA_BOOX_* to KAVITA_EPAPER_*
sudo systemctl restart kavita-epaper
# once it works:
sudo rm -rf /opt/kavita-boox /var/cache/kavita-boox /etc/systemd/system/kavita-boox.service
sudo userdel kavita-boox
sudo systemctl daemon-reload
```

Users sign in again after the move, because the new install generates a new session secret.


For version-by-version changes, see [`CHANGELOG.md`](./CHANGELOG.md).
