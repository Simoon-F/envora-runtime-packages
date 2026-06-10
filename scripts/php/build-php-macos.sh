#!/usr/bin/env bash
set -euo pipefail

version="${1:?Usage: build-php-macos.sh <php-version>}"

deps=(
  autoconf
  bison
  re2c
  pkg-config
  openssl@3
  oniguruma
  curl
  sqlite
  zlib
  bzip2
  freetype
  gettext
  icu4c
  jpeg-turbo
  libffi
  libpng
  libsodium
  libzip
  brotli
)
missing=()

for dep in "${deps[@]}"; do
  if ! brew list --formula "$dep" >/dev/null 2>&1; then
    missing+=("$dep")
  fi
done

if (( ${#missing[@]} > 0 )); then
  brew install "${missing[@]}"
else
  echo "All PHP build dependencies are already installed."
fi

brew_prefix="$(brew --prefix)"
brew_opt="$brew_prefix/opt"
sdkroot="$(xcrun --sdk macosx --show-sdk-path)"
work_dir="/tmp/php-build-${version}"
source_dir="$work_dir/php-${version}"
install_dir="/tmp/php-package/${version}"

rm -rf "$work_dir" "/tmp/php-package"
mkdir -p "$work_dir" "$install_dir"

curl -fsSL "https://www.php.net/distributions/php-${version}.tar.gz" -o "$work_dir/php-${version}.tar.gz"
tar -xzf "$work_dir/php-${version}.tar.gz" -C "$work_dir"

export TERM=dumb
export PATH="$brew_opt/bison/bin:$brew_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CFLAGS="-I$sdkroot/usr/include -I$brew_prefix/include -I$brew_opt/zlib/include -I$brew_opt/bzip2/include -I$brew_opt/gettext/include"
export CPPFLAGS="-I$sdkroot/usr/include -I$brew_prefix/include -I$brew_opt/zlib/include -I$brew_opt/bzip2/include -I$brew_opt/gettext/include"
export LDFLAGS="-L$brew_prefix/lib -L$brew_opt/zlib/lib -L$brew_opt/bzip2/lib -L$brew_opt/gettext/lib -Wl,-headerpad_max_install_names"
export LIBS="-lintl"
export LIBXML_CFLAGS="-I$sdkroot/usr/include/libxml2"
export LIBXML_LIBS="-lxml2"
export XSL_CFLAGS="-I$sdkroot/usr/include/libxml2"
export XSL_LIBS="-lxslt -lxml2"
export EXSLT_CFLAGS="-I$sdkroot/usr/include/libxml2"
export EXSLT_LIBS="-lexslt -lxslt -lxml2"

pkg_config_path="$brew_prefix/lib/pkgconfig"
for pkg in openssl@3 curl oniguruma sqlite zlib bzip2 freetype gettext icu4c jpeg-turbo libffi libpng libsodium libzip; do
  path="$brew_opt/$pkg/lib/pkgconfig"
  [[ -d "$path" ]] && pkg_config_path="$pkg_config_path:$path"
done
export PKG_CONFIG_PATH="$pkg_config_path"

cd "$source_dir"
./configure \
  --prefix="$install_dir" \
  --with-config-file-path="$install_dir/lib" \
  --with-config-file-scan-dir="$install_dir/etc/conf.d" \
  --with-openssl \
  --with-curl \
  --with-zlib \
  --with-iconv="$sdkroot/usr" \
  --with-bz2=shared,"$brew_opt/bzip2" \
  --enable-mbstring \
  --enable-bcmath=shared \
  --enable-calendar=shared \
  --enable-exif=shared \
  --enable-ftp=shared \
  --enable-gd=shared \
  --with-jpeg \
  --with-freetype \
  --with-gettext=shared,"$brew_opt/gettext" \
  --enable-intl=shared \
  --enable-pcntl=shared \
  --enable-shmop=shared \
  --with-sodium=shared,"$brew_opt/libsodium" \
  --enable-soap=shared \
  --enable-sockets=shared \
  --with-ffi=shared,"$brew_opt/libffi" \
  --with-xsl=shared \
  --with-zip=shared,"$brew_opt/libzip" \
  --enable-fpm \
  --with-pdo-mysql=mysqlnd \
  --with-mysqli=mysqlnd \
  --with-libxml \
  --enable-opcache=shared

make -j"$(sysctl -n hw.ncpu)"
make install
