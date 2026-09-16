#!/usr/bin/env bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
exec bash "./install-ovms-local-workshop.sh" "$@"
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
exec bash "./install-ovms-local-workshop.sh" "$@"
