#!/usr/bin/env bash
set -euo pipefail

version="${1:?Usage: package-macos-runtime.sh <php-version> <arch>}"
arch="${2:?Usage: package-macos-runtime.sh <php-version> <arch>}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
brew_prefix="$(brew --prefix)"
package_root="/tmp/php-package"
install_dir="$package_root/${version}"
bundle_dir="$install_dir/lib/envora-dylibs"
package="$package_root/php-${version}-macos-${arch}.tar.gz"

mkdir -p "$install_dir/etc/conf.d" "$install_dir/var/run" "$install_dir/var/log" "$bundle_dir"

if [[ -f "$repo_root/assets/php.ini.default" ]]; then
  cp "$repo_root/assets/php.ini.default" "$install_dir/lib/php.ini"
fi

runtime_files=()
for bin in "$install_dir/bin/php" "$install_dir/bin/php-cgi" "$install_dir/sbin/php-fpm"; do
  [[ -f "$bin" ]] && runtime_files+=("$bin")
done
while IFS= read -r -d '' so; do
  runtime_files+=("$so")
done < <(find "$install_dir/lib/php/extensions" -name "*.so" -type f -print0 2>/dev/null)

for file in "${runtime_files[@]}"; do
  strip "$file" || true
done

dylib_name() {
  basename "$1"
}

should_bundle_dylib() {
  case "$(dylib_name "$1")" in
    libiconv.2.dylib)
      return 1
      ;;
  esac
  return 0
}

find_system_dylib() {
  local name="$1"
  local candidate

  if [[ -f "/usr/lib/$name" ]]; then
    printf "%s" "/usr/lib/$name"
    return 0
  fi

  candidate="$(find -L "$brew_prefix/opt" "$brew_prefix/Cellar" -name "$name" -type f -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf "%s" "$candidate"
    return 0
  fi

  return 1
}

copy_dylib_by_name() {
  local name="$1"
  local source
  local target="$bundle_dir/$name"

  should_bundle_dylib "$name" || return 1
  [[ -f "$target" ]] && return 1

  source="$(find_system_dylib "$name")"
  if [[ -n "$source" && -f "$source" ]]; then
    cp -L "$source" "$target"
    chmod u+w "$target"
    return 0
  fi

  return 1
}

copy_homebrew_deps() {
  local copied=0
  local scan_files=("${runtime_files[@]}")

  if compgen -G "$bundle_dir/*.dylib" >/dev/null; then
    for dylib in "$bundle_dir"/*.dylib; do
      scan_files+=("$dylib")
    done
  fi

  for file in "${scan_files[@]}"; do
    while IFS= read -r dep; do
      case "$dep" in
        /opt/homebrew/*|/usr/local/*)
          if [[ -f "$dep" ]] && should_bundle_dylib "$dep"; then
            local target="$bundle_dir/$(dylib_name "$dep")"
            if [[ ! -f "$target" ]]; then
              cp -L "$dep" "$target"
              chmod u+w "$target"
              copied=1
            fi
          fi
          ;;
        @rpath/*|@loader_path/*)
          if copy_dylib_by_name "$(dylib_name "$dep")"; then
            copied=1
          fi
          ;;
      esac
    done < <(otool -L "$file" | awk 'NR > 1 { print $1 }')
  done

  if (( copied == 1 )); then
    return 0
  fi
  return 1
}

for _ in {1..12}; do
  if copy_homebrew_deps; then
    :
  else
    break
  fi
done

patch_load_commands() {
  local file="$1"
  local prefix

  case "$file" in
    "$install_dir/bin/"*|"$install_dir/sbin/"*)
      prefix="@loader_path/../lib/envora-dylibs"
      ;;
    "$install_dir/lib/php/extensions/"*)
      prefix="@loader_path/../../../envora-dylibs"
      ;;
    "$bundle_dir/"*)
      prefix="@loader_path"
      install_name_tool -id "$prefix/$(basename "$file")" "$file" || true
      ;;
    *)
      prefix="@loader_path/../lib/envora-dylibs"
      ;;
  esac

  while IFS= read -r dep; do
    local name
    name="$(dylib_name "$dep")"
    if [[ "$name" == "libiconv.2.dylib" && "$dep" != "/usr/lib/libiconv.2.dylib" ]]; then
      install_name_tool -change "$dep" "/usr/lib/libiconv.2.dylib" "$file" || true
    elif should_bundle_dylib "$name" && [[ -f "$bundle_dir/$name" && "$dep" != "$prefix/$name" ]]; then
      install_name_tool -change "$dep" "$prefix/$name" "$file" || true
    fi
  done < <(otool -L "$file" | awk 'NR > 1 { print $1 }')
}

for file in "${runtime_files[@]}"; do
  patch_load_commands "$file"
done
if compgen -G "$bundle_dir/*.dylib" >/dev/null; then
  for dylib in "$bundle_dir"/*.dylib; do
    patch_load_commands "$dylib"
  done
fi

for file in "${runtime_files[@]}"; do
  codesign --force --sign - "$file" || true
done
if compgen -G "$bundle_dir/*.dylib" >/dev/null; then
  for dylib in "$bundle_dir"/*.dylib; do
    codesign --force --sign - "$dylib" || true
  done
fi

"$repo_root/scripts/php/verify-macos-runtime.sh" "$version"

cd "$package_root"
tar -czf "$package" "$version"
shasum -a 256 "$package" > "$package.sha256"
ls -lh "$package" "$package.sha256"
