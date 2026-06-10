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
  exts = %w[bcmath bz2 calendar exif ffi ftp gd gettext intl opcache pcntl shmop soap sockets sodium xsl zip]
  platforms = {}

  Dir[File.join(dist_dir, "php-#{version}-macos-*.tar.gz")].sort.each do |package|
    base = File.basename(package)
    arch = base[/macos-(.+)\.tar\.gz\z/, 1]
    sha_file = "#{package}.sha256"
    sha = File.read(sha_file).split.first
    platforms[arch] = {
      "url" => "https://github.com/#{repo}/releases/download/php-#{version}/#{base}",
      "sha256" => sha,
      "min_macos" => "12.0",
      "extensions" => exts,
      "status" => "stable"
    }
  end

  manifest = {
    "schema" => 1,
    "generated_at" => Time.now.utc.iso8601,
    "runtimes" => {
      "php" => {
        version => {
          "macos" => platforms
        }
      }
    }
  }

  File.write(output_file, JSON.pretty_generate(manifest) + "\n")
' "$version" "$dist_dir" "$output_file"
