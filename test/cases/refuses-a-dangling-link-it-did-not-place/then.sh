set -eu
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    cmd //c "rmdir node_modules"
    cmd //c "mklink /J node_modules elsewhere" >/dev/null
    ;;
  *)
    rm node_modules
    ln -s elsewhere node_modules
    ;;
esac
