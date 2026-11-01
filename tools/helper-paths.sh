#!/bin/bash
# Shared with the installer path regression checks.
# Reject writable or symlinked ancestors before installing or executing a root
# helper. Securing only the executable does not protect a replaceable parent.
assert_secure_directory() {
  local dir="$1" owner mode
  [[ -d "$dir" && ! -L "$dir" ]] || die "unsafe helper directory: $dir"
  owner="$(/usr/bin/stat -f '%u' "$dir")"
  mode="$(/usr/bin/stat -f '%Lp' "$dir")"
  [[ "$owner" == 0 ]] || die "helper directory is not root-owned: $dir"
  (( (8#$mode & 022) == 0 )) || die "helper directory is writable by another user: $dir"
  if /bin/ls -lde "$dir" | /usr/bin/grep -Eq 'allow .*(write|delete|add_file|add_subdirectory|chown)'; then
    die "helper directory has a writable ACL: $dir"
  fi
}

prepare_helper_directory() {
  assert_secure_directory /
  assert_secure_directory /Library
  [[ ! -L "$HELPER_DIR" ]] || die "helper directory is a symlink"
  if [[ ! -e "$HELPER_DIR" ]]; then
    /usr/bin/install -d -o root -g wheel -m 0755 "$HELPER_DIR"
  fi
  assert_secure_directory "$HELPER_DIR"
  assert_secure_directory /Library/LaunchDaemons
  [[ ! -L "$BIN" && ! -L "$PLIST" ]] || die "helper or launch plist is a symlink"
}

