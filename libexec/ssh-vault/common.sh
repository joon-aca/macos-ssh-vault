#!/usr/bin/env bash

set -euo pipefail

SSH_VAULT_MARKER_FILE=".ssh-vault-profile"
SSH_VAULT_SENTINEL_FILE=".ssh-vault-volume"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

warn() {
  log "warning: $*"
}

# ---------------------------------------------------------------------------
# Platform & prereqs
# ---------------------------------------------------------------------------

ensure_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "ssh-vault requires macOS"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

host_id() {
  local value
  value="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  value="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  [ -n "$value" ] || die "unable to determine host name"
  printf '%s\n' "$value"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ---------------------------------------------------------------------------
# Paths — vault
# ---------------------------------------------------------------------------

icloud_root() {
  printf '%s\n' "${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
}

storage_dir() {
  printf '%s\n' "${SSH_VAULT_STORAGE_DIR:-$(icloud_root)/MacOSSSHVault}"
}

bundle_path() {
  printf '%s\n' "${SSH_VAULT_BUNDLE_PATH:-$(storage_dir)/MacOSSSHVault.sparsebundle}"
}

mount_point() {
  printf '%s\n' "${SSH_VAULT_MOUNT_POINT:-${HOME}/.macos-ssh-vault/mount}"
}

volume_name() {
  printf '%s\n' "${SSH_VAULT_VOLUME_NAME:-MacOSSSHVault}"
}

profiles_root() {
  printf '%s\n' "$(mount_point)/profiles"
}

profile_root() {
  printf '%s\n' "$(profiles_root)/$1"
}

profile_config() {
  printf '%s\n' "$(profile_root "$1")/config"
}

profile_conf_d() {
  printf '%s\n' "$(profile_root "$1")/conf.d"
}

profile_local_d() {
  printf '%s\n' "$(profile_root "$1")/local.d"
}

profile_iterm() {
  printf '%s\n' "$(profile_root "$1")/iterm-profiles.json"
}

state_dir() {
  printf '%s\n' "$(mount_point)/state"
}

active_claim_file() {
  printf '%s\n' "$(storage_dir)/active-host.env"
}

mounted_sentinel() {
  printf '%s\n' "$(mount_point)/${SSH_VAULT_SENTINEL_FILE}"
}

# ---------------------------------------------------------------------------
# Paths — local
# ---------------------------------------------------------------------------

local_ssh_dir() {
  printf '%s\n' "${SSH_VAULT_LOCAL_SSH_DIR:-${HOME}/.ssh}"
}

local_conf_d() {
  printf '%s\n' "$(local_ssh_dir)/conf.d"
}

local_local_d() {
  printf '%s\n' "$(local_ssh_dir)/local.d"
}

local_local_config() {
  printf '%s\n' "$(local_local_d)/config"
}

profile_marker_file() {
  printf '%s\n' "$(local_ssh_dir)/${SSH_VAULT_MARKER_FILE}"
}

backup_dir_root() {
  printf '%s\n' "$(local_ssh_dir)/.ssh-vault-backups"
}

# ---------------------------------------------------------------------------
# Parent directory helpers
# ---------------------------------------------------------------------------

ensure_parent_dirs() {
  mkdir -p "$(storage_dir)"
  mkdir -p "$(dirname "$(mount_point)")"
}

# ---------------------------------------------------------------------------
# Mount state
# ---------------------------------------------------------------------------

is_mounted() {
  [ -f "$(mounted_sentinel)" ]
}

require_mounted() {
  is_mounted || die "vault is not mounted; run ssh-vault mount"
}

# ---------------------------------------------------------------------------
# Host claim (heuristic multi-host guard)
# ---------------------------------------------------------------------------

write_claim() {
  cat >"$(active_claim_file)" <<EOF
HOST_ID=$(host_id)
CLAIMED_AT=$(utc_now)
EOF
}

clear_claim_if_owned() {
  local claimed
  [ -f "$(active_claim_file)" ] || return 0
  claimed="$(claim_value HOST_ID || true)"
  if [ -z "$claimed" ] || [ "$claimed" = "$(host_id)" ]; then
    rm -f "$(active_claim_file)"
  fi
}

claim_value() {
  local key line
  key="$1"
  [ -f "$(active_claim_file)" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "${key}"=*)
        printf '%s\n' "${line#*=}"
        return 0
        ;;
    esac
  done <"$(active_claim_file)"
  return 1
}

assert_local_claim() {
  local claimed
  claimed="$(claim_value HOST_ID || true)"
  if [ -n "$claimed" ] && [ "$claimed" != "$(host_id)" ]; then
    die "vault appears claimed by host ${claimed}; unmount there or clear the stale claim before mutating data"
  fi
}

# ---------------------------------------------------------------------------
# Sparsebundle lifecycle
# ---------------------------------------------------------------------------

create_sparsebundle() {
  local size
  size="$1"

  [ ! -e "$(bundle_path)" ] || die "bundle already exists at $(bundle_path)"

  ensure_parent_dirs
  if [ -n "${SSH_VAULT_PASSPHRASE:-}" ]; then
    printf '%s' "${SSH_VAULT_PASSPHRASE}" | hdiutil create \
      -size "$size" \
      -type SPARSEBUNDLE \
      -fs APFS \
      -volname "$(volume_name)" \
      -encryption AES-256 \
      -stdinpass \
      "$(bundle_path)" >/dev/null
  else
    hdiutil create \
      -size "$size" \
      -type SPARSEBUNDLE \
      -fs APFS \
      -volname "$(volume_name)" \
      -encryption AES-256 \
      "$(bundle_path)" >/dev/null
  fi
}

ensure_bundle_exists() {
  local size
  size="${1:-250m}"
  if [ -e "$(bundle_path)" ]; then
    return
  fi
  create_sparsebundle "$size"
}

attach_bundle() {
  local mp
  mp="$(mount_point)"

  if is_mounted; then
    return 0
  fi

  [ -e "$(bundle_path)" ] || die "bundle not found at $(bundle_path)"

  mkdir -p "$mp"
  if [ -n "${SSH_VAULT_PASSPHRASE:-}" ]; then
    printf '%s' "${SSH_VAULT_PASSPHRASE}" | hdiutil attach \
      "$(bundle_path)" \
      -stdinpass \
      -nobrowse \
      -owners on \
      -mountpoint "$mp" >/dev/null
  else
    hdiutil attach \
      "$(bundle_path)" \
      -nobrowse \
      -owners on \
      -mountpoint "$mp" >/dev/null
  fi

  [ -d "$mp" ] || die "mount failed unexpectedly"
  initialize_layout
  write_claim
}

detach_bundle() {
  local mp
  mp="$(mount_point)"
  is_mounted || die "vault is not mounted"
  hdiutil detach "$mp" >/dev/null
  clear_claim_if_owned
}

# ---------------------------------------------------------------------------
# Vault layout
# ---------------------------------------------------------------------------

initialize_layout() {
  mkdir -p "$(profiles_root)" "$(state_dir)"
  touch "$(mounted_sentinel)"

  local readme
  readme="$(mount_point)/README.txt"
  if [ ! -f "$readme" ]; then
    cat >"$readme" <<EOF
This volume is managed by macos-ssh-vault (ssh-vault).

It stores SSH profiles: config, conf.d host files, keys,
and optional iTerm profiles. Each profile is self-contained.
EOF
  fi
}

scaffold_profile() {
  local profile dir
  profile="$1"
  dir="$(profile_root "$profile")"

  mkdir -p "$dir/conf.d" "$dir/local.d"

  if [ ! -f "$dir/local.d/config.example" ]; then
    cat >"$dir/local.d/config.example" <<'EOF'
# Machine-local SSH overrides live here.
# This file is copied to ~/.ssh/local.d/config on first bootstrap if missing.
#
# Example:
# Include /Users/USERNAME/.colima/ssh_config
#
# Host my-laptop
#   HostName 192.168.x.x
#   User USERNAME
EOF
  fi
}

ensure_profile_layout() {
  [ -d "$(profile_root "$1")" ] || scaffold_profile "$1"
  [ -d "$(profile_conf_d "$1")" ] || mkdir -p "$(profile_conf_d "$1")"
  [ -d "$(profile_local_d "$1")" ] || mkdir -p "$(profile_local_d "$1")"
}

ensure_profile_exists() {
  [ -d "$(profile_root "$1")" ] || die "profile not found: $1"
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

assert_safe_local_ssh_dir() {
  local force ssh_dir nonlocal
  force="${1:-0}"
  ssh_dir="$(local_ssh_dir)"

  if [ -L "$ssh_dir" ]; then
    die "${ssh_dir} is a symlink; refusing to operate"
  fi

  if [ -e "$ssh_dir" ] && [ ! -d "$ssh_dir" ]; then
    die "${ssh_dir} exists but is not a directory"
  fi

  if [ ! -d "$ssh_dir" ]; then
    return 0
  fi

  if [ -f "$(profile_marker_file)" ] || [ "$force" = "1" ]; then
    return 0
  fi

  nonlocal="$(
    find "$ssh_dir" -mindepth 1 -maxdepth 1 \
      ! -name "local.d" \
      ! -name "${SSH_VAULT_MARKER_FILE}" \
      -print -quit 2>/dev/null || true
  )"

  [ -z "$nonlocal" ] || die "refusing to manage populated unmanaged ${ssh_dir}; rerun with --force to override"
}

# ---------------------------------------------------------------------------
# Collision handling
# ---------------------------------------------------------------------------

backup_colliding_file() {
  local backup_dir source target
  source="$1"
  target="$2"
  backup_dir="$3"

  [ -e "$target" ] || return 0

  if [ -f "$target" ] && cmp -s "$source" "$target"; then
    return 0
  fi

  mkdir -p "$backup_dir"
  mv "$target" "$backup_dir/$(basename "$target")"
  warn "moved existing ${target} to ${backup_dir}/"
}

backup_colliding_keys() {
  local backup_dir name profile source target
  profile="$1"
  backup_dir="$(backup_dir_root)/$(date -u +%Y%m%dT%H%M%SZ)"

  while IFS= read -r -d '' source; do
    name="$(basename "$source")"
    target="$(local_ssh_dir)/${name}"
    backup_colliding_file "$source" "$target" "$backup_dir"
  done < <(find "$(profile_root "$profile")" -mindepth 1 -maxdepth 1 -type f \
    ! -name 'config' \
    ! -name 'iterm-profiles.json' \
    -print0 | sort -z)
}

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

normalize_key_permissions() {
  local path root
  root="$1"
  [ -d "$root" ] || return 0

  chmod 700 "$root"

  while IFS= read -r -d '' path; do
    chmod 700 "$path"
  done < <(find "$root" -type d -print0)

  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in
      *.pub|known_hosts|authorized_keys)
        chmod 644 "$path"
        ;;
      *)
        chmod 600 "$path"
        ;;
    esac
  done < <(find "$root" -type f -print0)
}

normalize_local_ssh_permissions() {
  local path ssh_dir
  ssh_dir="$(local_ssh_dir)"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [ -d "$(local_conf_d)" ]; then
    chmod 700 "$(local_conf_d)"
    while IFS= read -r -d '' path; do
      chmod 600 "$path"
    done < <(find "$(local_conf_d)" -type f -print0)
  fi

  if [ -d "$(local_local_d)" ]; then
    chmod 700 "$(local_local_d)"
    if [ -f "$(local_local_config)" ]; then
      chmod 600 "$(local_local_config)"
    fi
  fi

  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in
      *.pub|known_hosts|authorized_keys)
        chmod 644 "$path"
        ;;
      config|config~|${SSH_VAULT_MARKER_FILE})
        chmod 600 "$path"
        ;;
      *)
        chmod 600 "$path"
        ;;
    esac
  done < <(find "$ssh_dir" -mindepth 1 -maxdepth 1 -type f -print0)
}

# ---------------------------------------------------------------------------
# Exclude patterns for key sync
# ---------------------------------------------------------------------------

local_key_exclude_args() {
  cat <<'EOF'
--exclude
config
--exclude
config~
--exclude
conf.d
--exclude
local.d
--exclude
known_hosts
--exclude
known_hosts.old
--exclude
agent
--exclude
*.sock
--exclude
control-*
--exclude
.DS_Store
--exclude
.ssh-vault-profile
--exclude
.ssh-vault-backups
--exclude
authorized_keys
--exclude
iterm-profiles.json
EOF
}

# ---------------------------------------------------------------------------
# Deploy: vault -> local
# ---------------------------------------------------------------------------

deploy_config() {
  local profile ssh_dir backup_dir
  profile="$1"
  ssh_dir="$(local_ssh_dir)"
  backup_dir="$(backup_dir_root)/$(date -u +%Y%m%dT%H%M%SZ)"

  mkdir -p "$ssh_dir"

  # Deploy config file
  if [ -f "$(profile_config "$profile")" ]; then
    backup_colliding_file "$(profile_config "$profile")" "$ssh_dir/config" "$backup_dir"
    cp "$(profile_config "$profile")" "$ssh_dir/config"
  fi

  # Deploy conf.d
  if [ -d "$(profile_conf_d "$profile")" ]; then
    mkdir -p "$(local_conf_d)"
    rsync -a --delete "$(profile_conf_d "$profile")/" "$(local_conf_d)/"
  fi

  # Deploy local.d/config from example if missing
  mkdir -p "$(local_local_d)"
  if [ ! -f "$(local_local_config)" ] && [ -f "$(profile_local_d "$profile")/config.example" ]; then
    cp "$(profile_local_d "$profile")/config.example" "$(local_local_config)"
  fi
}

deploy_keys() {
  local profile
  local -a rsync_args
  profile="$1"

  ensure_profile_layout "$profile"
  mkdir -p "$(local_ssh_dir)"
  backup_colliding_keys "$profile"

  rsync_args=(-a)
  while IFS= read -r arg; do
    rsync_args+=("$arg")
  done < <(local_key_exclude_args)

  rsync "${rsync_args[@]}" "$(profile_root "$profile")/" "$(local_ssh_dir)/"
}

deploy_iterm() {
  local profile dest
  profile="$1"
  dest="$(local_ssh_dir)/iterm-profiles.json"

  if [ -f "$(profile_iterm "$profile")" ]; then
    cp "$(profile_iterm "$profile")" "$dest"
    log "deployed iterm-profiles.json to ${dest}"
  fi
}

write_profile_marker() {
  local profile
  profile="$1"
  cat >"$(profile_marker_file)" <<EOF
PROFILE=${profile}
DEPLOYED_AT=$(utc_now)
HOST_ID=$(host_id)
EOF
  chmod 600 "$(profile_marker_file)"
}

sanity_check_ssh_config() {
  if ! ssh -G github.com >/dev/null 2>&1; then
    warn "ssh config sanity check failed; inspect ~/.ssh/config and included files"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Sync: local -> vault
# ---------------------------------------------------------------------------

sync_config_to_vault() {
  local profile ssh_dir
  profile="$1"
  ssh_dir="$(local_ssh_dir)"

  ensure_profile_layout "$profile"

  # Sync config file
  if [ -f "$ssh_dir/config" ]; then
    cp "$ssh_dir/config" "$(profile_config "$profile")"
  fi

  # Sync conf.d
  if [ -d "$(local_conf_d)" ]; then
    rsync -a --delete "$(local_conf_d)/" "$(profile_conf_d "$profile")/"
  fi
}

sync_keys_to_vault() {
  local profile
  local -a rsync_args
  profile="$1"

  [ -d "$(local_ssh_dir)" ] || die "local ssh directory not found at $(local_ssh_dir)"
  ensure_profile_layout "$profile"

  rsync_args=(-a --delete)
  while IFS= read -r arg; do
    rsync_args+=("$arg")
  done < <(local_key_exclude_args)

  rsync "${rsync_args[@]}" "$(local_ssh_dir)/" "$(profile_root "$profile")/"
  normalize_key_permissions "$(profile_root "$profile")"
}

sync_iterm_to_vault() {
  local profile source
  profile="$1"
  source="$(local_ssh_dir)/iterm-profiles.json"

  if [ -f "$source" ]; then
    cp "$source" "$(profile_iterm "$profile")"
    log "synced iterm-profiles.json to vault"
  fi
}

sync_local_example_to_vault() {
  local profile source dest
  profile="$1"
  source="$(local_local_d)/config.example"
  dest="$(profile_local_d "$profile")/config.example"

  if [ -f "$source" ]; then
    cp "$source" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# Backup & restore
# ---------------------------------------------------------------------------

backup_vault() {
  local target bp
  target="$1"
  bp="$(bundle_path)"

  [ -e "$bp" ] || die "no vault found at ${bp}"

  if is_mounted; then
    die "vault is currently mounted; unmount before backing up"
  fi

  mkdir -p "$(dirname "$target")"

  log "backing up vault to ${target}..."
  rsync -a --progress "$bp" "$target"
  log "backup complete: ${target}"
}

restore_vault() {
  local source bp
  source="$1"
  bp="$(bundle_path)"

  [ -e "$source" ] || die "backup source not found: ${source}"

  if is_mounted; then
    die "vault is currently mounted; unmount before restoring"
  fi

  if [ -e "$bp" ]; then
    die "vault already exists at ${bp}; move or remove it before restoring"
  fi

  ensure_parent_dirs

  log "restoring vault from ${source}..."
  rsync -a --progress "$source" "$bp"
  log "restore complete"
}

# ---------------------------------------------------------------------------
# Bootstrap (full deploy)
# ---------------------------------------------------------------------------

bootstrap_profile() {
  local force keep_mounted profile size
  profile="$1"
  keep_mounted="${2:-0}"
  force="${3:-0}"
  size="${SSH_VAULT_BOOTSTRAP_SIZE:-250m}"

  ensure_macos
  require_command hdiutil
  require_command rsync
  require_command ssh

  ensure_bundle_exists "$size"
  attach_bundle
  assert_local_claim
  ensure_profile_exists "$profile"
  assert_safe_local_ssh_dir "$force"

  deploy_config "$profile"
  deploy_keys "$profile"
  deploy_iterm "$profile"
  normalize_local_ssh_permissions
  write_profile_marker "$profile"
  sanity_check_ssh_config

  if [ "$keep_mounted" != "1" ]; then
    detach_bundle
  fi
}

# ---------------------------------------------------------------------------
# Sync (full push to vault)
# ---------------------------------------------------------------------------

sync_profile() {
  local keep_mounted profile
  profile="$1"
  keep_mounted="${2:-0}"

  ensure_macos
  require_command hdiutil
  require_command rsync

  attach_bundle
  assert_local_claim
  ensure_profile_layout "$profile"

  sync_config_to_vault "$profile"
  sync_keys_to_vault "$profile"
  sync_iterm_to_vault "$profile"

  if [ "$keep_mounted" != "1" ]; then
    detach_bundle
  fi
}

# ---------------------------------------------------------------------------
# List & status
# ---------------------------------------------------------------------------

list_profiles() {
  require_mounted
  find "$(profiles_root)" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

status_summary() {
  local marker claimed

  printf 'bundle_path=%s\n' "$(bundle_path)"
  printf 'mount_point=%s\n' "$(mount_point)"
  printf 'mounted=%s\n' "$(is_mounted && printf yes || printf no)"
  printf 'local_ssh_dir=%s\n' "$(local_ssh_dir)"

  claimed="$(claim_value HOST_ID || true)"
  printf 'active_host_claim=%s\n' "${claimed:-none}"

  marker="$(profile_marker_file)"
  if [ -f "$marker" ]; then
    printf 'local_profile_marker=%s\n' "$marker"
  else
    printf 'local_profile_marker=none\n'
  fi

  if is_mounted; then
    printf 'profiles='
    list_profiles | paste -sd ',' -
    printf '\n'
  fi
}
