#!/usr/bin/env bash
set -euo pipefail

version="${1:?Usage: write-manifest.sh <php-version> <dist-dir> <output-file>}"
dist_dir="${2:?Usage: write-manifest.sh <php-version> <dist-dir> <output-file>}"
output_file="${3:?Usage: write-manifest.sh <php-version> <dist-dir> <output-file>}"

ruby -rjson -rtime -e '
  version = ARGV.fetch(0)
  dist_dir = ARGV.fetch(1)
  output_file = ARGV.fetch(2)
  repo = ENV.fetch("GITHUB_REPOSITORY")

  common_exts = %w[bcmath bz2 calendar exif ffi ftp gd gettext intl opcache soap sockets sodium xsl zip]
  macos_exts  = common_exts + %w[pcntl shmop]

  manifest = {
    "schema" => 1,
    "generated_at" => Time.now.utc.iso8601,
    "runtimes" => { "php" => {} }
  }

  manifest["runtimes"]["php"][version] ||= {}

  # ------------------------------------------------------------------
  # macOS packages (.tar.gz)
  # ------------------------------------------------------------------
  macos_packages = Dir[File.join(dist_dir, "php-#{version}-macos-*.tar.gz")].sort
  unless macos_packages.empty?
    platforms = {}
    macos_packages.each do |package|
      base = File.basename(package)
      arch = base[/macos-(.+)\.tar\.gz\z/, 1]
      sha_file = "#{package}.sha256"
      sha = File.readable?(sha_file) ? File.read(sha_file).split.first : nil
      platforms[arch] = {
        "url" => "https://github.com/#{repo}/releases/download/php-#{version}-macos/#{base}",
        "sha256" => sha,
        "min_macos" => "12.0",
        "extensions" => macos_exts,
        "status" => "stable"
      }
    end
    manifest["runtimes"]["php"][version]["macos"] = platforms
  end

  # ------------------------------------------------------------------
  # Windows packages (.zip)
  # ------------------------------------------------------------------
  windows_packages = Dir[File.join(dist_dir, "php-#{version}-windows-*.zip")].sort
  unless windows_packages.empty?
    platforms = {}
    windows_packages.each do |package|
      base = File.basename(package)
      arch = base[/windows-(.+)\.zip\z/, 1]
      sha_file = "#{package}.sha256"
      sha = File.readable?(sha_file) ? File.read(sha_file).split.first : nil
      platforms[arch] = {
        "url" => "https://github.com/#{repo}/releases/download/php-#{version}-windows/#{base}",
        "sha256" => sha,
        "min_windows" => "10.0",
        "extensions" => common_exts,
        "status" => "stable"
      }
    end
    manifest["runtimes"]["php"][version]["windows"] = platforms
  end

  File.write(output_file, JSON.pretty_generate(manifest) + "\n")
' "$version" "$dist_dir" "$output_file"
