#!/bin/sh
# Every case is run against a real daukle, because this plugin's output is
# node's and npm's, and a stub of daukle.exec would be testing the stub.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$root/test/.work"

daukle=${DAUKLE:-}
if [ -z "$daukle" ]; then
  for candidate in \
    "$root/.daukle/build/daukle" \
    "$root/.daukle/build/daukle.exe" \
    "$root/.daukle/build/Release/daukle.exe" \
    "$root/.daukle/build/Debug/daukle.exe"
  do
    [ -x "$candidate" ] && daukle=$candidate && break
  done
fi
if [ -z "$daukle" ] || [ ! -x "$daukle" ]; then
  echo "no daukle binary: set DAUKLE, or check out daukle/daukle into .daukle and build it" >&2
  exit 1
fi

passed=0
failed=0
skipped=0

fail() {
  echo "FAIL $1: $2" >&2
  failed=$((failed + 1))
}

# This plugin is multi-file, so the whole plugin directory is staged rather
# than the single plugin.lua the other repositories copy.
stage_plugin() {
  mkdir -p "$1/plugins/node"
  cp "$root/plugin.lua" "$1/plugins/node/plugin.lua"
  cp -R "$root/lib" "$1/plugins/node/lib"
}

# Every non-empty line of the file is one clause, all of which must be present
# when wanted is 1 and absent when it is 0. A multi-clause file is what lets a
# case assert that a message was ADDED TO rather than replaced.
assert_clauses() {
  clause_file=$1
  wanted=$2
  if [ ! -f "$clause_file" ]; then
    fail "$label" "$(basename "$clause_file") is missing, so this case asserts nothing"
    return 1
  fi
  any=0
  while IFS= read -r clause || [ -n "$clause" ]; do
    [ -z "$clause" ] && continue
    any=1
    if grep -qF "$clause" "$sandbox/stderr.txt" "$sandbox/stdout.txt"; then
      if [ "$wanted" -eq 0 ]; then
        fail "$label" "message carries what it must not: $clause"
        return 1
      fi
    elif [ "$wanted" -eq 1 ]; then
      fail "$label" "message does not carry: $clause"
      sed -n '1,40p' "$sandbox/stderr.txt" >&2
      return 1
    fi
  done < "$clause_file"
  if [ "$any" -eq 0 ]; then
    fail "$label" "the clause file is empty, so this case asserts nothing"
    return 1
  fi
  return 0
}

# The constraint this whole toolchain exists to satisfy, asserted after every
# case rather than in the one case that remembered to say it.
assert_root_is_clean() {
  for forbidden in node_modules package.json package-lock.json; do
    if [ -e "$sandbox/$forbidden" ]; then
      fail "$label" "the project root holds $forbidden"
      return 1
    fi
  done
  return 0
}

run_error_case() {
  if (cd "$sandbox" && "$daukle" sync "$manifest_name" >stdout.txt 2>stderr.txt); then
    fail "$label" "expected a failure, got success"
    return 1
  fi
  assert_clauses "$case_dir/expect-error.txt" 1
}

run_task_error_case() {
  if (cd "$sandbox" && "$daukle" "$task" >stdout.txt 2>stderr.txt); then
    fail "$label" "expected task $task to fail, got success"
    return 1
  fi
  assert_clauses "$case_dir/expect-task-error.txt" 1
}

run_task_case() {
  if ! (cd "$sandbox" && "$daukle" "$task" >stdout.txt 2>stderr.txt); then
    fail "$label" "task $task failed"
    sed -n '1,60p' "$sandbox/stderr.txt" >&2
    return 1
  fi
  assert_clauses "$case_dir/expect-output.txt" 1 || return 1
  assert_root_is_clean || return 1
  # Running it a second time must change nothing a case named, which is the
  # one assertion that catches an install that is not idempotent.
  [ -f "$case_dir/unchanged.txt" ] || return 0
  while IFS= read -r unchanged || [ -n "$unchanged" ]; do
    [ -z "$unchanged" ] && continue
    cp "$sandbox/$unchanged" "$sandbox/.before" || {
      fail "$label" "$unchanged was not produced"
      return 1
    }
    if ! (cd "$sandbox" && "$daukle" "$task" >stdout.txt 2>stderr.txt); then
      fail "$label" "the second $task failed"
      sed -n '1,40p' "$sandbox/stderr.txt" >&2
      return 1
    fi
    if ! cmp -s "$sandbox/.before" "$sandbox/$unchanged"; then
      fail "$label" "$unchanged changed on the second $task"
      return 1
    fi
  done < "$case_dir/unchanged.txt"
  return 0
}

compare_expected() {
  expected_root=$case_dir/expected
  # An empty expected/ would compare nothing and pass, which is the one way a
  # case can look green while asserting nothing at all.
  if [ -z "$(cd "$expected_root" && find . -type f)" ]; then
    fail "$1" "expected/ holds no files, so this case asserts nothing"
    return 1
  fi
  ok=0
  for expected in $(cd "$expected_root" && find . -type f); do
    if ! cmp -s "$expected_root/$expected" "$sandbox/$expected"; then
      fail "$1" "$expected differs"
      diff -u "$expected_root/$expected" "$sandbox/$expected" >&2 || true
      ok=1
    fi
  done
  return $ok
}

run_sync_case() {
  # Twice, because applying twice must equal applying once for every case,
  # not only for the one a test remembered to say it about.
  if ! (cd "$sandbox" && "$daukle" sync "$manifest_name" >stdout.txt 2>stderr.txt); then
    fail "$label" "sync failed"
    sed -n '1,40p' "$sandbox/stderr.txt" >&2
    return 1
  fi
  compare_expected "$label (first)" || return 1
  if ! (cd "$sandbox" && "$daukle" sync "$manifest_name" >stdout.txt 2>stderr.txt); then
    fail "$label" "second sync failed"
    return 1
  fi
  compare_expected "$label (second)" || return 1
  assert_root_is_clean
}

run_case() {
  case_dir=$1
  name=$(basename "$case_dir")

  for manifest in "$case_dir"/daukle*.toml; do
    manifest_name=$(basename "$manifest")
    label="$name/$manifest_name"

    # A node archive is around fifty megabytes and npm reaches the registry,
    # which no local run should pay for unasked. CI sets the variable on every
    # runner, because the per-platform archives and the resolver's behaviour on
    # the floor release are exercised by nothing else.
    if [ -f "$case_dir/needs-node" ] && [ "${DAUKLE_NODE_E2E:-}" != "1" ]; then
      echo "skip $label: set DAUKLE_NODE_E2E=1 to run it here" >&2
      skipped=$((skipped + 1))
      continue
    fi

    sandbox="$work/$name-$manifest_name"
    rm -rf "$sandbox"
    mkdir -p "$(dirname "$sandbox")"
    cp -R "$case_dir" "$sandbox"
    rm -rf "$sandbox/expected" "$sandbox/expect-error.txt" "$sandbox/task.txt" \
           "$sandbox/expect-task-error.txt" "$sandbox/expect-output.txt" \
           "$sandbox/unchanged.txt" "$sandbox/needs-node"
    stage_plugin "$sandbox"
    # Only the cases that run node get the module trees, so an ordinary sync
    # case's sandbox holds nothing but what its own directory carried.
    [ -f "$case_dir/needs-node" ] && cp -R "$root/test/fixtures" "$sandbox/fixtures"

    if [ -f "$case_dir/expect-error.txt" ]; then
      run_error_case && passed=$((passed + 1))
      continue
    fi

    if [ -f "$case_dir/task.txt" ]; then
      if [ "$manifest_name" != "daukle.toml" ]; then
        fail "$label" "a task case's manifest must be daukle.toml"
        continue
      fi
      task=$(cat "$case_dir/task.txt")
      if [ -f "$case_dir/expect-task-error.txt" ]; then
        run_task_error_case && passed=$((passed + 1))
        continue
      fi
      run_task_case && passed=$((passed + 1))
      continue
    fi

    run_sync_case && passed=$((passed + 1))
  done
  # A failing case must not end this function on a non-zero status: set -e
  # would then take a single red case for a broken runner and stop the suite.
  return 0
}

rm -rf "$work"
# examples/ runs under the same harness as test/cases/, so an example that
# stops working is a red suite rather than something noticed later.
for case_dir in "$root"/test/cases/*/ "$root"/examples/*/; do
  [ -d "$case_dir" ] || continue
  run_case "${case_dir%/}"
done

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
