#!/bin/sh
# Every case is run against a real daukle, because this plugin's output is
# node's and npm's, and a stub of daukle.exec would be testing the stub.
# The migrate cases also need curl and python3 (or python), which every GitHub
# ubuntu, macOS and windows runner carries.
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

# On Windows python3 can be the WindowsApps stub that only opens the Store, so
# a candidate counts only once it has run.
working_python() {
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys' >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  return 1
}

# Port 0 lets the system pick, because a fixed port can fall in a range Windows
# reserves for Hyper-V and refuses to bind.
PLUGIN_SERVER='
import functools, http.server, os, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(sys.argv[2] + ".tmp", "w") as out:
    out.write(str(server.server_port))
os.replace(sys.argv[2] + ".tmp", sys.argv[2])
server.serve_forever()
'

# The catalog's asset is pinned by url and sha256, and core takes only https or
# loopback http for it, so the staged plugin is packed exactly as publish.yml
# packs it and served from 127.0.0.1.
serve_plugin() {
  [ -n "${catalog:-}" ] && return 0
  if [ -n "${server_broken:-}" ]; then
    echo "skip $label: the plugin server did not start" >&2
    skipped=$((skipped + 1))
    return 1
  fi
  server_broken=1
  python=$(working_python) || { fail "$label" "no python3 or python that runs"; return 1; }
  asset_dir="$work/asset"
  mkdir -p "$asset_dir"
  # COPYFILE_DISABLE and ustar keep macOS bsdtar from adding AppleDouble or pax
  # members, and core's tar reader takes only regular files and directories.
  (cd "$root" && COPYFILE_DISABLE=1 tar --format=ustar -cf "$asset_dir/plugin.lua" plugin.lua lib/*.lua)
  digest=$(sha256sum "$asset_dir/plugin.lua" 2>/dev/null | cut -d' ' -f1)
  [ -n "$digest" ] || digest=$(shasum -a 256 "$asset_dir/plugin.lua" | cut -d' ' -f1)
  port_file="$work/server-port"
  rm -f "$port_file"
  "$python" -c "$PLUGIN_SERVER" "$asset_dir" "$port_file" >"$work/server.log" 2>&1 &
  server=$!
  trap 'kill "$server" 2>/dev/null || true' EXIT
  port=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$port_file" ] && port=$(cat "$port_file") &&
      curl -fsS "http://127.0.0.1:$port/plugin.lua" -o /dev/null 2>/dev/null && break
    port=
    kill -0 "$server" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$port" ]; then
    fail "$label" "the plugin server did not start, so no migrate case can run: $(cat "$work/server.log")"
    return 1
  fi
  server_broken=
  catalog="$work/catalog.json"
  "$python" -c 'import json,sys; c=json.load(open(sys.argv[1])); c.update(id="node", asset={"url":sys.argv[2],"sha256":sys.argv[3]}); json.dump({"plugins":[c]}, open(sys.argv[4],"w"))' \
    "$root/catalog.json" "http://127.0.0.1:$port/plugin.lua" "$digest" "$catalog"
}

grep_clauses_in() {
  file=$1; clauses=$2
  [ -f "$clauses" ] || return 0
  while IFS= read -r clause || [ -n "$clause" ]; do
    [ -z "$clause" ] && continue
    grep -qF "$clause" "$file" || { fail "$label" "$(basename "$file") does not carry: $clause"; return 1; }
  done < "$clauses"
}

run_migrate_case() {
  serve_plugin || return 1
  status=0
  (cd "$sandbox" && "$daukle" migrate --catalog "$catalog" >stdout.txt 2>stderr.txt) || status=$?
  wanted=$(cat "$case_dir/expect-exit.txt")
  if [ "$status" -ne "$wanted" ]; then
    fail "$label" "migrate exited $status, wanted $wanted"
    echo "--- stdout" >&2
    tail -n 30 "$sandbox/stdout.txt" >&2
    echo "--- stderr" >&2
    tail -n 30 "$sandbox/stderr.txt" >&2
    return 1
  fi
  cat "$sandbox/stdout.txt" "$sandbox/stderr.txt" > "$sandbox/both.txt"
  grep_clauses_in "$sandbox/both.txt" "$case_dir/expect-output.txt" || return 1
  grep_clauses_in "$sandbox/daukle.toml" "$case_dir/expect-manifest.txt" || return 1
  if [ -f "$case_dir/expect-gone.txt" ]; then
    while IFS= read -r gone || [ -n "$gone" ]; do
      [ -z "$gone" ] && continue
      [ -e "$sandbox/$gone" ] && { fail "$label" "$gone is still in the project"; return 1; }
    done < "$case_dir/expect-gone.txt"
  fi
  if [ -f "$case_dir/expect-present.txt" ]; then
    while IFS= read -r present || [ -n "$present" ]; do
      [ -z "$present" ] && continue
      [ -e "$sandbox/$present" ] || { fail "$label" "$present is no longer in the project"; return 1; }
    done < "$case_dir/expect-present.txt"
  fi
  if [ -f "$case_dir/expect-kept.txt" ]; then
    while IFS= read -r kept || [ -n "$kept" ]; do
      [ -z "$kept" ] && continue
      [ -e "$sandbox/build/daukle/migrate/old/$kept" ] || { fail "$label" "$kept was not kept"; return 1; }
    done < "$case_dir/expect-kept.txt"
  fi
  if [ -f "$case_dir/task-after.txt" ]; then
    task=$(cat "$case_dir/task-after.txt")
    (cd "$sandbox" && "$daukle" "$task" >stdout.txt 2>stderr.txt) || { fail "$label" "$task failed after migrating"; sed -n '1,40p' "$sandbox/stderr.txt" >&2; return 1; }
    cat "$sandbox/stdout.txt" "$sandbox/stderr.txt" > "$sandbox/both.txt"
    grep_clauses_in "$sandbox/both.txt" "$case_dir/expect-task-output.txt" || return 1
  fi
  return 0
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

# What a failure must NOT say, which is the only way to assert that something
# did not happen: a sequence that stops at its first failing step is otherwise
# indistinguishable from one that ran every step and reported the last.
assert_absent_clauses() {
  [ -f "$case_dir/expect-absent.txt" ] || return 0
  assert_clauses "$case_dir/expect-absent.txt" 0
}

run_error_case() {
  if (cd "$sandbox" && "$daukle" sync "$manifest_name" >stdout.txt 2>stderr.txt); then
    fail "$label" "expected a failure, got success"
    return 1
  fi
  assert_clauses "$case_dir/expect-error.txt" 1 || return 1
  assert_absent_clauses
}

run_task_error_case() {
  if (cd "$sandbox" && "$daukle" "$task" >stdout.txt 2>stderr.txt); then
    fail "$label" "expected task $task to fail, got success"
    return 1
  fi
  assert_clauses "$case_dir/expect-task-error.txt" 1 || return 1
  assert_absent_clauses
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

  if [ -f "$case_dir/migrate" ]; then
    label="$name/migrate"
    if [ -f "$case_dir/needs-node" ] && [ "${DAUKLE_NODE_E2E:-}" != "1" ]; then
      echo "skip $label: set DAUKLE_NODE_E2E=1 to run it here" >&2
      skipped=$((skipped + 1))
      return 0
    fi
    sandbox="$work/$name-migrate"
    rm -rf "$sandbox"
    mkdir -p "$(dirname "$sandbox")"
    cp -R "$case_dir" "$sandbox"
    (cd "$sandbox" && rm -f migrate needs-node expect-*.txt task-after.txt)
    run_migrate_case && passed=$((passed + 1))
    return 0
  fi

  # daukle.lua is included because core accepts one as the PRIMARY manifest when
  # no daukle.toml sits beside it, and the chunk that registers a task per
  # script has to survive a format daukle.parse refuses to run.
  for manifest in "$case_dir"/daukle*.toml "$case_dir"/daukle.lua; do
    [ -f "$manifest" ] || continue
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
           "$sandbox/unchanged.txt" "$sandbox/needs-node" \
           "$sandbox/expect-tasks.txt" "$sandbox/expect-no-tasks.txt" \
           "$sandbox/expect-absent.txt"
    stage_plugin "$sandbox"
    # Only the cases that run node get the module trees, so an ordinary sync
    # case's sandbox holds nothing but what its own directory carried.
    [ -f "$case_dir/needs-node" ] && cp -R "$root/test/fixtures" "$sandbox/fixtures"

    if [ -f "$case_dir/expect-error.txt" ]; then
      run_error_case && passed=$((passed + 1))
      continue
    fi

    # What `daukle tasks` NAMES. A task is registered when the chunk loads, long
    # before anything is provisioned, so this needs no node and runs on every
    # host rather than only where a 50 MB archive has been downloaded.
    if [ -f "$case_dir/expect-tasks.txt" ]; then
      if ! (cd "$sandbox" && "$daukle" tasks >stdout.txt 2>stderr.txt); then
        fail "$label" "daukle tasks failed"
        sed -n '1,40p' "$sandbox/stderr.txt" >&2
        continue
      fi
      assert_clauses "$case_dir/expect-tasks.txt" 1 || continue
      # A presence-only assertion cannot catch a task that should NOT be there,
      # which is how a boundary stays a sentence rather than a check.
      if [ -f "$case_dir/expect-no-tasks.txt" ]; then
        assert_clauses "$case_dir/expect-no-tasks.txt" 0 || continue
      fi
      passed=$((passed + 1))
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
for case_dir in "$root"/test/cases/*/; do
  [ -d "$case_dir" ] || continue
  run_case "${case_dir%/}"
done

# Pure Lua, run inside daukle through a staged plugin that requires the real
# lib/, because the sandbox is the only Lua these modules ever run in.
run_unit() {
  label=unit
  sandbox="$work/unit"
  mkdir -p "$sandbox/plugins/unit"
  cp "$root/test/unit/plugin.lua" "$sandbox/plugins/unit/plugin.lua"
  cp -R "$root/test/unit/tests" "$sandbox/plugins/unit/tests"
  cp -R "$root/lib" "$sandbox/plugins/unit/lib"
  printf 'schema = 1\nproject = "daukle/node-unit"\nversion = "1.0.0"\n\n[modules]\n\n[plugins]\nunit = "./plugins/unit"\n\n[toolchains.unit]\n' \
    > "$sandbox/daukle.toml"
  if (cd "$sandbox" && "$daukle" unit:test >stdout.txt 2>stderr.txt); then
    passed=$((passed + 1))
  else
    fail unit "$(sed -n '1,60p' "$sandbox/stderr.txt")"
  fi
}

run_unit

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
