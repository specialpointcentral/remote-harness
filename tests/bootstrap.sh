#!/usr/bin/env bash
# Hermetic checks of helper transfer and the documented download-before-execute commands.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/rh-bootstrap.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$fixture/bin" "$fixture/source/scripts" "$fixture/home"
cp "$ROOT/scripts/simple-bootstrap.sh" "$fixture/source/scripts/"
for helper in _common.sh simple-laptop-setup.sh laptop-setup.sh mount-project.sh inject-rule.sh run-on-project-host.sh project-host-gateway.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/source/scripts/$helper"
done
cat > "$fixture/source/scripts/simple-dispatch.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${BOOTSTRAP_MARKER:?}"
SH
cat > "$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'connection\n' >> "${BOOTSTRAP_CONNECTIONS:?}"
# The source alias owns the trusted host identity. Reject options that erase or weaken it.
case " $* " in
  *UserKnownHostsFile=*|*GlobalKnownHostsFile=*|*StrictHostKeyChecking=accept-new*) exit 90;;
esac
case " $* " in *StrictHostKeyChecking=yes*) ;; *) exit 90;; esac
case " $* " in *UpdateHostKeys=no*) ;; *) exit 90;; esac
has_n=0
for arg in "$@"; do [ "$arg" != -n ] || has_n=1; done
[ "$has_n" = 1 ] || cat >/dev/null
remote_cmd="${!#}"
if [[ "$remote_cmd" == cat\ * ]]; then
  case "${BOOTSTRAP_FAULT:-}" in
    outer-empty) exit 0;;
    outer-failure|outer-syntax)
      printf 'printf executed > "${BOOTSTRAP_MARKER:?}"\n'
      [ "$BOOTSTRAP_FAULT" != outer-failure ] || exit 255
      printf 'if\n'; exit 0;;
  esac
  PATH="$BOOTSTRAP_SERVER_PATH" RH_HOME="$BOOTSTRAP_SOURCE" bash -c "$remote_cmd"
  exit $?
fi
PATH="$BOOTSTRAP_SERVER_PATH" RH_HOME="$BOOTSTRAP_SOURCE" bash -c "$remote_cmd" > "$BOOTSTRAP_ARCHIVE"
case "${BOOTSTRAP_FAULT:-}" in
  transfer-failure) cat "$BOOTSTRAP_ARCHIVE"; exit 255;;
  truncated) head -c 1024 "$BOOTSTRAP_ARCHIVE"; exit 0;;
  digest|extra|symlink|bootstrap-change)
    python3 - "$BOOTSTRAP_ARCHIVE" "$BOOTSTRAP_FAULT" <<'PY'
import io
import os
import sys
import tarfile

path, mode = sys.argv[1:]
with tarfile.open(path) as source, tarfile.open(path + '.new', 'w') as target:
    for member in source:
        content = source.extractfile(member).read()
        if mode == 'symlink' and member.name == '_common.sh':
            member.type, member.linkname, member.size = tarfile.SYMTYPE, '../outside', 0
            target.addfile(member)
            continue
        if mode in ('digest', 'bootstrap-change') and member.name == ('_common.sh' if mode == 'digest' else 'simple-bootstrap.sh'):
            content += b'\n# changed\n'
            member.size = len(content)
        if mode == 'bootstrap-change' and member.name == 'SHA256SUMS':
            # An internally valid bundle from another bootstrap revision must still fail.
            import hashlib
            body = open(os.environ['BOOTSTRAP_SOURCE'] + '/scripts/simple-bootstrap.sh', 'rb').read() + b'\n# changed\n'
            rows = content.decode().splitlines()
            rows[0] = hashlib.sha256(body).hexdigest() + '  simple-bootstrap.sh'
            content = ('\n'.join(rows) + '\n').encode()
            member.size = len(content)
        target.addfile(member, io.BytesIO(content))
    if mode == 'extra':
        member = tarfile.TarInfo('../outside')
        member.size = 1
        target.addfile(member, io.BytesIO(b'x'))
os.replace(path + '.new', path)
PY
    ;;
esac
cat "$BOOTSTRAP_ARCHIVE"
SH
chmod +x "$fixture/bin/ssh"
export PATH="$fixture/bin:$PATH" HOME="$fixture/home" RH_VIA=testbox
export BOOTSTRAP_SERVER_PATH="$PATH"
export RH_SIMPLE_CACHE="$fixture/cache" BOOTSTRAP_SOURCE="$fixture/source"
export BOOTSTRAP_MARKER="$fixture/started" BOOTSTRAP_CONNECTIONS="$fixture/connections"
export BOOTSTRAP_ARCHIVE="$fixture/archive.tar"

# Exercise the actual documented command with only its terminal prompt replaced by a test target.
for document in SKILL.md SKILL.cn.md reference/reverse.md reference/reverse.cn.md; do
  python3 - "$ROOT/$document" "$fixture/outer.sh" <<'PY'
import re
import sys

document = open(sys.argv[1], encoding='utf-8').read()
command = next(block for block in re.findall(r'```bash\n(.*?)```', document, re.S) if 'fetch.XXXXXX' in block)
begin, end = command.index("p='"), command.index('mkdir -p')
command = command[:begin] + "h='testbox'\n" + command[end:]
open(sys.argv[2], 'w').write(command.replace('<lang>', 'en').replace('<launch>', 'codex'))
PY
  rm -f "$BOOTSTRAP_MARKER" "$BOOTSTRAP_CONNECTIONS"
  bash "$fixture/outer.sh" > "$fixture/out" 2> "$fixture/err"
  [ "$(cat "$BOOTSTRAP_MARKER")" = '--mode reverse --launch codex --source-via testbox' ] || fail "$document handoff"
  [ "$(wc -l < "$BOOTSTRAP_CONNECTIONS" | tr -d ' ')" = 2 ] || fail "$document should use one bootstrap and one bundle transfer"
done
# The earlier published form pipes the bootstrap into `bash -s`, where BASH_SOURCE is unset.
rm -f "$BOOTSTRAP_MARKER"
bash -s -- --mode reverse --launch codex < "$BOOTSTRAP_SOURCE/scripts/simple-bootstrap.sh" \
  > "$fixture/out" 2> "$fixture/err" || fail "piped bootstrap failed: $(cat "$fixture/err")"
[ "$(cat "$BOOTSTRAP_MARKER")" = '--mode reverse --launch codex --source-via testbox' ] || fail 'piped bootstrap handoff'
# macOS uses shasum while the Linux server commonly uses sha256sum: manifests must agree.
if command -v shasum >/dev/null 2>&1; then
  mkdir "$fixture/shasum-bin"
  for tool in bash ssh mkdir mktemp rm cat sed tail grep mv chmod tar sort cmp awk shasum; do
    ln -s "$(command -v "$tool")" "$fixture/shasum-bin/$tool"
  done
  rm -f "$BOOTSTRAP_MARKER"
  PATH="$fixture/shasum-bin" bash "$fixture/outer.sh" > "$fixture/out" 2> "$fixture/err"
  [ -e "$BOOTSTRAP_MARKER" ] || fail 'shasum client could not validate sha256sum server manifest'
fi
for fault in outer-empty outer-failure outer-syntax transfer-failure truncated digest extra symlink bootstrap-change; do
  rm -f "$BOOTSTRAP_MARKER" "$BOOTSTRAP_CONNECTIONS"
  if BOOTSTRAP_FAULT="$fault" bash "$fixture/outer.sh" > "$fixture/out" 2> "$fixture/err"; then
    fail "$fault was accepted"
  fi
  [ ! -e "$BOOTSTRAP_MARKER" ] || fail "$fault executed downloaded code"
done
[ ! -e "$fixture/home/.remote-harness/.sessions/outside" ] || fail 'archive escaped its directory'
[ -z "$(find "$fixture/home/.remote-harness/.sessions" -mindepth 1 -print -quit)" ] || fail 'local staging not cleaned'
[ -z "$(find "$fixture/source/.sessions" -mindepth 1 -print -quit)" ] || fail 'remote staging not cleaned'
