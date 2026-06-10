#!/usr/bin/env bash
set -euo pipefail

version="${1:?Usage: verify-macos-runtime.sh <php-version>}"
install_dir="/tmp/php-package/${version}"
bundle_dir="$install_dir/lib/envora-dylibs"

required_extensions=(
  bcmath
  bz2
  calendar
  exif
  ffi
  ftp
  gd
  gettext
  intl
  opcache
  pcntl
  shmop
  soap
  sockets
  sodium
  xsl
  zip
)

runtime_files=()
for bin in "$install_dir/bin/php" "$install_dir/bin/php-cgi" "$install_dir/sbin/php-fpm"; do
  [[ -f "$bin" ]] && runtime_files+=("$bin")
done
while IFS= read -r -d '' file; do
  runtime_files+=("$file")
done < <(find "$install_dir/lib/php/extensions" "$bundle_dir" \( -name "*.so" -o -name "*.dylib" \) -type f -print0 2>/dev/null)

remaining_refs=""
for file in "${runtime_files[@]}"; do
  refs="$(otool -L "$file" | awk 'NR > 1 { print $1 }' | grep -E '^(/opt/homebrew|/usr/local|@rpath)/' || true)"
  [[ -n "$refs" ]] && remaining_refs+="$file"$'\n'"$refs"$'\n'
done

if [[ -n "$remaining_refs" ]]; then
  echo "Found unbundled or unresolved dylib references:"
  printf "%s" "$remaining_refs"
  exit 1
fi

"$install_dir/bin/php" -v
"$install_dir/bin/php-cgi" -v
"$install_dir/sbin/php-fpm" -v

"$install_dir/bin/php" -m | grep -iE "curl|mbstring|mysqli|mysqlnd|openssl|pdo|opcache"

extension_dir="$(find "$install_dir/lib/php/extensions" -mindepth 1 -maxdepth 1 -type d -print -quit)"
for extension in "${required_extensions[@]}"; do
  test -f "$extension_dir/$extension.so"
done

for extension in "${required_extensions[@]}"; do
  if [[ "$extension" == "opcache" ]]; then
    "$install_dir/bin/php" \
      -n \
      -d "extension_dir=$extension_dir" \
      -d "zend_extension=$extension" \
      -m >/dev/null
  else
    "$install_dir/bin/php" \
      -n \
      -d "extension_dir=$extension_dir" \
      -d "extension=$extension" \
      -m >/dev/null
  fi
done

echo "Runtime verification passed for PHP ${version}."
