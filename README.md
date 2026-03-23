# macos-ssh-vault

Manage your SSH keys and config across all your Macs — encrypted at rest, synced via iCloud, deployed with one command.

You have SSH keys on your Mac. Probably a dozen of them. They live in `~/.ssh` alongside a config file that's grown organically over the years — some entries stale, some critical, some you're afraid to touch.

Now picture setting up a new Mac, or recovering from a dead drive. Where are those keys? Scattered across old backups? In a password manager? On a USB stick in a drawer?

**macos-ssh-vault** keeps everything in a single AES-256 encrypted sparsebundle on your iCloud Drive — your config, your keys, your host definitions — and deploys it all to any of your Macs with one command:

```bash
./bootstrap ssh-canonical
```

That's it. Your config, your host definitions, your keys — all provisioned into `~/.ssh`, permissions fixed, sanity-checked. Same identity, any Mac, sixty seconds.

## How it works

Your SSH data lives in an AES-256 encrypted sparsebundle in iCloud Drive. The vault holds everything portable about your SSH identity: config, host files, keys, even iTerm profiles. This repo holds only the tooling to manage it — no secrets ever touch git.

```
Encrypted Vault (iCloud)          Local ~/.ssh
┌──────────────────────┐          ┌──────────────────────┐
│  profiles/           │  deploy  │  config              │
│    ssh-canonical/    │ ──────>  │  conf.d/*.conf       │
│      config          │          │  id_rsa, fio_key ... │
│      conf.d/*.conf   │   sync   │  local.d/config      │
│      id_rsa, ...     │ <──────  │  known_hosts (local) │
│      local.d/        │          │                      │
│      iterm-profiles  │          │                      │
└──────────────────────┘          └──────────────────────┘
```

The vault is the single source of truth. Local `~/.ssh` is a working copy you can always rebuild.

## Why not just...

- **...copy `~/.ssh` to iCloud directly?** Unencrypted keys in cloud storage. No thanks.
- **...use a password manager?** Great for passwords, awkward for multi-file SSH configs with conf.d fragments and key pairs that need specific permissions.
- **...use a dotfiles repo?** Keys can't go in git. Splitting config into git and keys into "somewhere else" creates sync headaches and split-brain drift.
- **...use Ansible/Chef/etc?** Massive overkill for managing one directory on your personal machines.

macos-ssh-vault keeps it simple: one encrypted container, one sync target, one command to deploy.

## Quick start

**First time — import your existing SSH setup:**

```bash
git clone <repo> ~/macos-ssh-vault
cd ~/macos-ssh-vault

./bin/ssh-vault init          # creates the encrypted vault (you'll set a passphrase)
./bin/ssh-vault mount         # mount it
./bin/ssh-vault sync ssh-canonical   # push your current ~/.ssh into the vault
./bin/ssh-vault unmount       # done
```

**On another Mac — provision from the vault:**

```bash
git clone <repo> ~/macos-ssh-vault
cd ~/macos-ssh-vault

./bootstrap ssh-canonical     # that's it
```

**After making local changes — push back to the vault:**

```bash
./bin/ssh-vault sync ssh-canonical
```

## What bootstrap does

1. Creates the encrypted sparsebundle if it doesn't exist yet
2. Mounts it (prompts for your passphrase)
3. Deploys config, conf.d host files, and keys into `~/.ssh`
4. Creates `~/.ssh/local.d/config` from a template if missing
5. Fixes all permissions (700 dirs, 600 private files, 644 public)
6. Runs `ssh -G github.com` as a sanity check
7. Unmounts the vault

If a local key already exists with different contents, the existing file is backed up to `~/.ssh/.ssh-vault-backups/<timestamp>/` before the vault version is written. Extra local keys not in the vault are left untouched.

## Commands

| Command | What it does |
|---|---|
| `./bootstrap <profile>` | Full deploy from vault to `~/.ssh` |
| `ssh-vault init [size]` | Create encrypted vault (default 250MB) |
| `ssh-vault mount` | Mount the vault |
| `ssh-vault unmount` | Unmount the vault |
| `ssh-vault sync <profile>` | Push local `~/.ssh` state into the vault |
| `ssh-vault list` | List available profiles |
| `ssh-vault status` | Show vault and local state |
| `ssh-vault backup <target>` | Copy encrypted vault to backup location |
| `ssh-vault restore <source>` | Restore vault from backup |

## Profiles

The vault supports multiple profiles for different use cases:

- **ssh-canonical** — your full identity: all keys, all hosts
- **ssh-dev** — lighter profile: just the keys you need for dev work
- **ssh-lite** — minimal: GitHub key only

Each profile is self-contained — its own config, conf.d, keys, and optional iTerm profiles.

## Machine-local config

Some SSH config is machine-specific: colima includes, LAN host aliases, VPN bastions. These go in `~/.ssh/local.d/config`, which is:

- Created from a template on first bootstrap
- Never synced back to the vault (unless you explicitly choose to)
- Included by the main config via `Include ~/.ssh/local.d/config`

## Backup

iCloud syncs the sparsebundle across your Macs, but iCloud sync is not a backup.

```bash
# Back up to an external drive
ssh-vault backup /Volumes/Backup/ssh-vault.sparsebundle

# Restore on a fresh machine
ssh-vault restore /Volumes/Backup/ssh-vault.sparsebundle
./bootstrap ssh-canonical
```

The sparsebundle is already AES-256 encrypted, so you can store it anywhere you trust.

## Safety

- Refuses to operate if `~/.ssh` is a symlink
- Never silently deletes local keys — collisions are backed up with timestamps
- Heuristic host claims prevent concurrent vault mutations across machines
- CI enforces that no keys, certificates, or vault artifacts are tracked in git
- `known_hosts` stays local — it's machine-specific and not part of the vault

## Environment variables

| Variable | Default |
|---|---|
| `SSH_VAULT_STORAGE_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs/MacOSSSHVault` |
| `SSH_VAULT_BUNDLE_PATH` | `$SSH_VAULT_STORAGE_DIR/MacOSSSHVault.sparsebundle` |
| `SSH_VAULT_MOUNT_POINT` | `~/.macos-ssh-vault/mount` |
| `SSH_VAULT_LOCAL_SSH_DIR` | `~/.ssh` |
| `SSH_VAULT_VOLUME_NAME` | `MacOSSSHVault` |
| `SSH_VAULT_PASSPHRASE` | *(unset — for scripted/CI use only)* |
