#!/usr/bin/env bash
set -euo pipefail

# Ensure gems are installed before running any command
cd /app/gem
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
  rake)
    # Run rake tasks
    exec bundle exec "$@"
    ;;
  bin/*)
    # Run bin scripts
    exec bundle exec "$@"
    ;;
  *)
    # Default: treat as bundle exec command
    exec bundle exec "$@"
    ;;
esac