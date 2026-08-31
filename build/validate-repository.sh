#!/bin/bash

set -Eeuo pipefail

validation_error() {
  local status=$?
  echo "ERROR: repository validation failed at line $1 (exit $status): $2" >&2
  exit "$status"
}
trap 'validation_error "$LINENO" "$BASH_COMMAND"' ERR

repository=${REPOSITORY_DIR:-/repository}
scope=${PACKAGE_SCOPE:-/config/aarch64-packages}
public_key=${PUBLIC_KEY:-/public/omarchy-aarch64.gpg}

# Keep archive inspection inside the Arch build image. GitHub's Ubuntu host
# does not provide bsdtar by default, while the image already does.
echo "Validating repository database inventory..."
[[ -s $repository/omarchy.db.tar.zst ]] || {
  echo "ERROR: repository database is missing or empty" >&2
  exit 1
}
database_filenames=$(bsdtar -xOf "$repository/omarchy.db.tar.zst" '*/desc' |
  awk '$0 == "%FILENAME%" { getline; print }')
[[ -n $database_filenames ]] || {
  echo "ERROR: repository database contains no package filenames" >&2
  exit 1
}
while IFS= read -r filename; do
  [[ -f $repository/$filename ]] || {
    echo "ERROR: database references missing asset: $filename" >&2
    exit 1
  }
  [[ -f $repository/$filename.sig ]] || {
    echo "ERROR: database package lacks signature: $filename" >&2
    exit 1
  }
done <<< "$database_filenames"

echo "Loading the repository signing key..."
pacman-key --add "$public_key"

cat >> /etc/pacman.conf <<EOF

[omarchy]
SigLevel = Required TrustAll
Server = file://$repository
EOF

echo "Synchronizing package databases..."
pacman -Syy --noconfirm

echo "Resolving the maintained AArch64 package scope..."
mapfile -t packages < <(sed -E '/^[[:space:]]*(#|$)/d' "$scope")
for package in "${packages[@]}"; do
  pacman -Si "$package" >/dev/null || {
    echo "ERROR: pacman cannot resolve scoped package: $package" >&2
    exit 1
  }
done

# Resolve the complete transaction without installing it. This catches missing
# dependencies while keeping validation fast and side-effect free.
pacman -Sp --noconfirm "${packages[@]}" >/dev/null
echo "Repository validation complete."
