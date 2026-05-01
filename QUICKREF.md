# Quick reference

Day-to-day workflows for `macos-ssh-vault`. For setup and architecture, see [README.md](README.md).

## Mental model

```
        bootstrap (vault → local)
           ↓
  Vault ─────► ~/.ssh
           ↑
        sync (local → vault)
```

The vault is the source of truth. `~/.ssh` is a working copy. You sync between them **explicitly** — there is no automatic background sync.

---

## Common tasks

### Add or change a shared host

```bash
# 1. Edit a conf.d fragment locally
$EDITOR ~/.ssh/conf.d/50-servers.conf

# 2. Test it works
ssh -G newhost

# 3. Push to vault
~/.macos-ssh-vault/bin/ssh-vault sync ssh-canonical
```

### Add a new key

```bash
# 1. Generate or drop the key into ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/newserver_key

# 2. Push to vault
~/.macos-ssh-vault/bin/ssh-vault sync ssh-canonical
```

### Pull latest vault state onto another Mac

```bash
~/.macos-ssh-vault/bootstrap ssh-canonical
```

### See what's deployed and when

```bash
~/.macos-ssh-vault/bin/ssh-vault status
```

Shows the current profile marker (which profile is deployed, when), vault mount status, and available profiles.

### Back up the encrypted vault

iCloud syncs across Macs but **iCloud is not a backup** — accidental deletes propagate. Back up periodically:

```bash
~/.macos-ssh-vault/bin/ssh-vault backup /Volumes/Backup/ssh-vault.sparsebundle
```

The sparsebundle is AES-256 encrypted, so it's safe on any drive you trust.

---

## What syncs vs. what doesn't

| Path | Synced? | Notes |
|---|---|---|
| `~/.ssh/config` | yes | Top-level config |
| `~/.ssh/conf.d/*.conf` | yes | Shared host fragments |
| `~/.ssh/<key>` | yes | All non-public-key files in the root |
| `~/.ssh/<key>.pub` | yes | Public keys |
| `~/.ssh/local.d/config` | **no** | Machine-specific (colima, LAN aliases) |
| `~/.ssh/known_hosts` | **no** | Machine-specific |
| `~/.ssh/.ssh-vault-marker` | **no** | Local deployment metadata |
| `~/.ssh/.ssh-vault-backups/` | **no** | Collision backups from past bootstraps |

If a value should differ between Macs (e.g. a sparky entry that only resolves on your home network), put it in `~/.ssh/local.d/config` — it stays local.

---

## The discipline

The one rule that prevents grief: **after editing `~/.ssh` on a Mac, run `sync` before doing anything on another Mac.**

If you skip this and bootstrap on Mac B, Mac B will overwrite its `~/.ssh` with the older vault state — no warning. The local edits on Mac A are still there, but Mac B is now stale until you sync from A and bootstrap B again.

A safe habit: run `ssh-vault status` before bootstrapping on a different machine to confirm the vault timestamp is recent.

---

## Recovering from mistakes

### "I synced from the wrong machine and overwrote vault state"

If the older state is still on another Mac that hasn't bootstrapped yet, `sync` from there to push it back.

If the vault sparsebundle has already overwritten everywhere, restore from your most recent `ssh-vault backup`:

```bash
~/.macos-ssh-vault/bin/ssh-vault restore /Volumes/Backup/ssh-vault.sparsebundle
~/.macos-ssh-vault/bootstrap ssh-canonical
```

### "Bootstrap clobbered a local key I cared about"

It didn't — colliding files are moved to `~/.ssh/.ssh-vault-backups/<timestamp>/` rather than deleted. Check there.

### "I want to see what bootstrap will do without running it"

There's no dry-run flag yet. The safest preview: mount the vault and inspect the profile directly:

```bash
~/.macos-ssh-vault/bin/ssh-vault mount
ls -la ~/.macos-ssh-vault/mount/profiles/ssh-canonical/
~/.macos-ssh-vault/bin/ssh-vault unmount
```

---

## Profiles

A profile is a self-contained set of config + keys. Switch between them by passing a different profile name:

```bash
~/.macos-ssh-vault/bootstrap ssh-lite       # e.g. minimal/GitHub-only
~/.macos-ssh-vault/bootstrap ssh-canonical  # full identity
```

Each profile lives at `<vault>/profiles/<name>/`. The `sync` command writes to whichever profile you pass.
