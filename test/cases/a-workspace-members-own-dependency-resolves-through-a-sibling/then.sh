set -eu

[ -e packages/a/node_modules/ms/package.json ] || {
  echo "packages/a/node_modules does not hold the member's own dependency after its sibling's install" >&2
  exit 1
}
