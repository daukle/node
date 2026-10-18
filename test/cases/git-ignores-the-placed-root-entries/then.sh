set -eu
git init -q
for entry in node_modules package.json; do
  git check-ignore -q "$entry" || { echo "git does not ignore the placed $entry"; exit 1; }
done
untracked=$(git status --porcelain -- node_modules package.json)
[ -z "$untracked" ] || { echo "git lists a placed entry: $untracked"; exit 1; }
