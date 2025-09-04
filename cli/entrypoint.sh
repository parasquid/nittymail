#!/usr/bin/env bash
set -euo pipefail

# Ensure gems are installed before running any command
cd /app/cli
bundle config set path /usr/local/bundle >/dev/null
if ! bundle check >/dev/null 2>&1; then
  echo "Installing gems (bundle install)..."
  bundle install
fi

# No args: drop into a shell
if [ "$#" -eq 0 ]; then
  exec bash
fi

case "${1:-}" in
  bash|sh)
    exec "$@"
    ;;
  ruby|bundle)
    # Allow direct ruby/bundle usage
    exec "$@"
    ;;
  ./cli.rb|cli.rb)
    # Run the CLI entry with bundler
    shift
    exec bundle exec ruby ./cli.rb "$@"
    ;;
  *)
    # Convenience: treat args as subcommands to cli.rb
    exec bundle exec ruby ./cli.rb "$@"
    ;;
esac
