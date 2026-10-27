#!/usr/bin/env sh
# Route an encoded command to the project host, or execute its internal dispatch mode there.
set -eu

fail() {
  printf 'remote-harness: %s\n' "$*" >&2
  exit 2
}

# Probed once here: decode_b64 runs inside $(...), where a lazily cached flag would be lost.
if base64 --decode </dev/null >/dev/null 2>&1; then
  BASE64_DECODE_FLAG=--decode
elif base64 -d </dev/null >/dev/null 2>&1; then
  BASE64_DECODE_FLAG=-d
else
  BASE64_DECODE_FLAG=-D
fi

decode_b64() {
  printf '%s' "$1" | base64 "$BASE64_DECODE_FLAG"
}

encode_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

safe_relative_dir() {
  case "$1" in
    ""|.) return 0 ;;
    /*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

reject_direct_agent_launch() {
  printf '%s\n' "$1" | grep -Eq '(^|[;&|()]|[[:space:]])(command[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+|exec[[:space:]]+|nohup[[:space:]]+|sudo[[:space:]]+|time[[:space:]]+)?([^;&|()[:space:]]*/)?(claude|codex|opencode)([[:space:];&|()]|$)'
}

make_agent_guard_path() {
  _mag_dir=$(mktemp -d "${TMPDIR:-/tmp}/remote-harness-no-agent.XXXXXX") \
    || fail "could not create the local no-agent guard"
  for _mag_name in claude codex opencode; do  # printf is a builtin: no process per stub
    printf '%s\n' '#!/usr/bin/env sh' \
      "printf 'remote-harness: Agent processes must run on the remote agent host.\\n' >&2" \
      'exit 126' > "$_mag_dir/$_mag_name"
  done
  chmod +x "$_mag_dir/claude" "$_mag_dir/codex" "$_mag_dir/opencode"
  printf '%s' "$_mag_dir"
}

# Both dispatch verbs: drop AI credentials, shadow agent CLIs with $guard_path, and always remove it.
# A signal ends the dispatcher: carrying on after the guard is gone would run without it.
start_agent_guard() {
  scrub_agent_credentials
  guard_path=$(make_agent_guard_path)
  trap cleanup_dispatch EXIT
  trap 'cleanup_dispatch; exit 129' HUP
  trap 'cleanup_dispatch; exit 130' INT
  trap 'cleanup_dispatch; exit 143' TERM
}

cleanup_dispatch() {
  rm -rf "$guard_path"
  [ -z "$snapshot_work" ] || rm -rf "$snapshot_work"
  [ -z "$snapshot_lock" ] || rmdir "$snapshot_lock" 2>/dev/null || true
}

finish_agent_guard() {  # $1 = exit status
  cleanup_dispatch
  trap - EXIT HUP INT TERM
  exit "$1"
}

resolve_target() {  # $1=project root b64 $2=relative cwd b64 -> target_physical
  project_root=$(decode_b64 "$1") || fail "could not decode project root"
  relative_cwd=$(decode_b64 "$2") || fail "could not decode relative working directory"
  case "$project_root" in /*) ;; *) fail "project root must be absolute" ;; esac
  safe_relative_dir "$relative_cwd" || fail "invalid relative working directory"
  root_physical=$(cd "$project_root" 2>/dev/null && pwd -P) || fail "project root is unavailable"
  if [ -n "$relative_cwd" ]; then
    target_physical=$(cd "$root_physical/$relative_cwd" 2>/dev/null && pwd -P) \
      || fail "mapped working directory is unavailable"
  else
    target_physical=$root_physical
  fi
  case "$target_physical" in
    "$root_physical"|"$root_physical"/*) ;;
    *) fail "mapped working directory escapes the project root" ;;
  esac
}

AGENT_CREDENTIAL_VARS="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR OPENAI_API_KEY CODEX_API_KEY CODEX_HOME"

scrub_agent_credentials() {
  # shellcheck disable=SC2086 # a fixed list of names.
  unset $AGENT_CREDENTIAL_VARS 2>/dev/null || true
}

# Start "$@" in its own process group when the host offers a way to (setsid on Linux, perl on
# macOS); otherwise it shares ours and only the process-tree walk below can reach its children.
run_in_new_group() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  elif [ -x /usr/bin/perl ]; then
    exec /usr/bin/perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' "$@"
  fi
  exec "$@"
}

process_tree() {  # $1=root pid -> root and every current descendant
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2; seen[NR] = $1 }
    END {
      found[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i in seen) {
          pid = seen[i]
          if (!(pid in found) && (parent[pid] in found)) { found[pid] = 1; changed = 1 }
        }
      }
      for (pid in found) print pid
    }'
}

# Stop a command and everything it started: TERM to its process group and process tree, then KILL
# whatever is still there after five seconds.
terminate_tree() {  # $1=root pid
  _tt_targets=$(process_tree "$1")
  kill -s TERM -- "-$1" 2>/dev/null || true
  for _tt_pid in $_tt_targets; do kill -s TERM "$_tt_pid" 2>/dev/null || true; done
  _tt_i=0
  while [ "$_tt_i" -lt 5 ]; do
    _tt_alive=0
    for _tt_pid in $_tt_targets; do kill -0 "$_tt_pid" 2>/dev/null && _tt_alive=1; done
    [ "$_tt_alive" = 1 ] || return 0
    sleep 1
    _tt_i=$((_tt_i + 1))
  done
  _tt_targets="$_tt_targets $(process_tree "$1")"
  kill -s KILL -- "-$1" 2>/dev/null || true
  for _tt_pid in $_tt_targets; do kill -s KILL "$_tt_pid" 2>/dev/null || true; done
}

stdin_is_channel() { [ -p /dev/stdin ] || [ -S /dev/stdin ]; }

# Run "$@" with stdin from /dev/null while the SSH channel (our stdin) stays open. The caller holds
# the channel open for exactly as long as it wants the command; EOF means it was cancelled, timed
# out, or lost the connection, so the command's whole process tree is stopped. Exits with the
# command's status.
run_watched() {
  exec 3<&0
  ( run_in_new_group "$@" ) </dev/null 3<&- &
  watched_pid=$!
  ( cat <&3 >/dev/null 2>&1; terminate_tree "$watched_pid" ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  exec 3<&-
  watched_status=0
  wait "$watched_pid" || watched_status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  return "$watched_status"
}

# Run "$@" with stdin from /dev/null in its own process group and stop its whole tree after $1
# seconds. A timeout creates $2, since the exit status alone could be the command's own.
run_with_timeout() {  # $1=seconds $2=timeout marker, then the command
  _rwt_seconds=$1 _rwt_marker=$2
  shift 2
  ( run_in_new_group "$@" ) </dev/null &
  _rwt_pid=$!
  ( _rwt_sleep=""
    trap '[ -z "$_rwt_sleep" ] || kill "$_rwt_sleep" 2>/dev/null; exit 0' TERM
    sleep "$_rwt_seconds" &
    _rwt_sleep=$!
    wait "$_rwt_sleep" || exit 0
    : > "$_rwt_marker" 2>/dev/null || true
    terminate_tree "$_rwt_pid" ) </dev/null >/dev/null 2>&1 &
  _rwt_timer=$!
  _rwt_status=0
  wait "$_rwt_pid" || _rwt_status=$?
  kill "$_rwt_timer" 2>/dev/null || true
  wait "$_rwt_timer" 2>/dev/null || true
  return "$_rwt_status"
}

# --- Login shell snapshot -------------------------------------------------------------------------
# A routed command needs the environment the user's login profile builds (PATH entries from Homebrew,
# nvm, conda, ...), but a login shell per command re-runs that profile, which takes 200+ ms on some
# hosts: as long as the SSH round trip itself. So a session captures, once, what a login bash or zsh
# leaves behind (exported variables, functions, shell options, umask, soft resource limits) into a
# snapshot in its gateway session directory, checks that the snapshot loads silently and completely,
# and runs later commands with `$SHELL -c` after loading it. A snapshot is replaced once it is older
# than SNAPSHOT_MAX_AGE_MIN (startup files may source files nobody watches) or a startup file changes.
# Everything else (another shell, a failed or timed-out capture, a snapshot that does not load cleanly,
# unsafe permissions, a capture already running for another command) starts a login shell for the
# command, exactly as without a snapshot.
SNAPSHOT_MAX_AGE_MIN=10
SNAPSHOT_RETRY_MIN=10            # a failed capture is retried after this, or once a startup file changes
SNAPSHOT_CAPTURE_SECONDS=30
SNAPSHOT_CHECK_SECONDS=10
SNAPSHOT_LOCK_STALE_MIN=2        # longer than any capture with its checks
# Never restored: values that belong to one connection or process, and credentials commands never get.
SNAPSHOT_SKIP_VARS="PWD OLDPWD SHLVL _ IFS SSH_CLIENT SSH_CONNECTION SSH_TTY SSH_ORIGINAL_COMMAND"
SNAPSHOT_SKIP_VARS="$SNAPSHOT_SKIP_VARS XDG_SESSION_ID KRB5CCNAME RH_GATEWAY_SESSION_DIR $AGENT_CREDENTIAL_VARS"
snapshot_dir="" snapshot_file="" snapshot_work="" snapshot_lock="" shell_kind=""

# The capture scripts run as `<shell> -lc <script> remote-harness <output> <names to skip> <shell>`,
# after the profile. They write only to <output> (with `>|`, as the profile may set noclobber) and end
# it with a marker, so a truncated snapshot never loads as complete.
snapshot_capture_bash() {
  cat <<'EOF'
__rh_snap_opts=$(builtin set +o) __rh_snap_shopts=$(builtin shopt -p)
builtin set +e +u +x +v
__rh_snap_skip=" $2 " __rh_snap_ro=" "
while IFS= builtin read -r __rh_snap_line; do
  case $__rh_snap_line in
    "declare -"*" "*) __rh_snap_line=${__rh_snap_line#declare -* }; __rh_snap_ro="$__rh_snap_ro${__rh_snap_line%%=*} " ;;
  esac
done <<__RH_SNAP_EOF
$(builtin readonly -p)
__RH_SNAP_EOF
{
  builtin printf '# remote-harness shell snapshot: %s\n' "$3"
  builtin printf 'umask %s\n' "$(builtin umask)"
  for __rh_snap_l in n c s u; do
    __rh_snap_v=$(builtin ulimit -S -"$__rh_snap_l" 2>/dev/null) || continue
    case $__rh_snap_v in unlimited) ;; ""|*[!0-9]*) continue ;; esac
    builtin printf 'ulimit -S -%s %s 2>/dev/null\n' "$__rh_snap_l" "$__rh_snap_v"
  done
  for __rh_snap_n in $(builtin compgen -e); do
    case $__rh_snap_skip in *" $__rh_snap_n "*) continue ;; esac
    case $__rh_snap_n in ""|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    case " BASHOPTS SHELLOPTS EUID PPID UID " in *" $__rh_snap_n "*) continue ;; esac
    builtin printf 'export %s=%q\n' "$__rh_snap_n" "${!__rh_snap_n}"
    case $__rh_snap_ro in *" $__rh_snap_n "*) builtin printf 'readonly %s\n' "$__rh_snap_n" ;; esac
  done
  # Functions parse with extglob on whatever the profile left it at; the options follow them.
  builtin printf '%s\n' 'shopt -s extglob'
  builtin declare -f
  while IFS= builtin read -r __rh_snap_line; do
    case $__rh_snap_line in "declare -fx "*) builtin printf 'export -f %q\n' "${__rh_snap_line#declare -fx }" ;; esac
  done <<__RH_SNAP_EOF
$(builtin declare -F)
__RH_SNAP_EOF
  while IFS= builtin read -r __rh_snap_line; do
    case $__rh_snap_line in "shopt -"[su]" login_shell"|"shopt -"[su]" restricted_shell") continue ;; esac
    builtin printf '%s\n' "$__rh_snap_line"
  done <<__RH_SNAP_EOF
$__rh_snap_shopts
__RH_SNAP_EOF
  builtin printf '%s\n' "$__rh_snap_opts" '__rh_snapshot_complete=1'
} >| "$1"
EOF
}

snapshot_capture_zsh() {
  cat <<'EOF'
__rh_snap_setopt=$(setopt)
__rh_snap_capture() {
  emulate -L zsh
  local __rh_snap_skip=" $2 " __rh_snap_ro __rh_snap_n __rh_snap_l __rh_snap_v
  __rh_snap_ro=" ${(j: :)${(f)"$(typeset +r)"}} "
  {
    print -r -- "# remote-harness shell snapshot: $3"
    print -r -- "umask $(umask)"
    for __rh_snap_l in n c s u; do
      __rh_snap_v=$(ulimit -S -$__rh_snap_l 2>/dev/null) || continue
      [[ $__rh_snap_v == unlimited || $__rh_snap_v == <-> ]] || continue
      print -r -- "ulimit -S -$__rh_snap_l $__rh_snap_v 2>/dev/null"
    done
    for __rh_snap_n in ${(f)"$(typeset +x)"}; do
      [[ $__rh_snap_skip == *" $__rh_snap_n "* ]] && continue
      [[ $__rh_snap_n == [A-Za-z_]* && $__rh_snap_n != *[^A-Za-z0-9_]* ]] || continue
      print -r -- "export $__rh_snap_n=${(qq)${(P)__rh_snap_n}}"
      [[ $__rh_snap_ro == *" $__rh_snap_n "* ]] && print -r -- "readonly $__rh_snap_n"
    done
    print -r -- "fpath=( ${(qq)fpath[@]} )"
    typeset -f
    print -r -- 'unfunction __rh_snap_capture 2>/dev/null'
    # Options that differ from the defaults, minus those that describe how this shell was started.
    for __rh_snap_n in ${(f)__rh_snap_setopt}; do
      case $__rh_snap_n in
        (login|interactive|shinstdin|monitor|zle|privileged|restricted|singlecommand) ;;
        ([a-z]*) print -r -- "setopt $__rh_snap_n" ;;
      esac
    done
    print -r -- '__rh_snapshot_complete=1'
  } >| "$1"
}
__rh_snap_capture "$@"
EOF
}

# True when a file that a login bash or zsh reads (directly, through /etc/profile.d, or through macOS
# path_helper) changed after $1. -H follows dotfiles that are symlinks into a dotfiles repository.
startup_files_changed() {  # $1=reference file
  _sfc_ref=$1
  set -- "$shell"
  for _sfc_file in /etc/environment /etc/profile /etc/profile.d /etc/bash.bashrc /etc/bashrc \
      /etc/zshenv /etc/zprofile /etc/zlogin /etc/zsh /etc/paths /etc/paths.d; do
    if [ -e "$_sfc_file" ]; then set -- "$@" "$_sfc_file"; fi
  done
  if [ -n "${HOME:-}" ]; then
    for _sfc_file in .profile .bash_profile .bash_login .bashrc .zshenv .zprofile .zlogin; do
      if [ -e "$HOME/$_sfc_file" ]; then set -- "$@" "$HOME/$_sfc_file"; fi
    done
  fi
  _sfc_out=$(find -H "$@" -newer "$_sfc_ref" -print 2>/dev/null) || :
  [ -n "$_sfc_out" ]
}

older_than() {  # $1=path $2=minutes
  _ot_out=$(find "$1" -prune -mmin +"$2" -print 2>/dev/null) || return 1
  [ -n "$_ot_out" ]
}

# Every path is owned by this user, is not a symlink, and is writable by nobody else.
private_paths() {
  for _pp_path in "$@"; do
    [ -O "$_pp_path" ] && [ ! -L "$_pp_path" ] || return 1
  done
  _pp_out=$(find "$@" -prune \( -perm -020 -o -perm -002 \) -print 2>/dev/null) || return 1
  [ -z "$_pp_out" ]
}

# The per-command check: a private snapshot of this shell, recent, and newer than every startup file.
snapshot_usable() {  # $1=snapshot
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -O "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] \
    || return 1
  _su_out=$(find "$snapshot_dir" "$1" -prune \( -perm -020 -o -perm -002 \
    -o \( -type f -mmin +"$SNAPSHOT_MAX_AGE_MIN" \) \) -print 2>/dev/null) || return 1
  [ -z "$_su_out" ] || return 1
  IFS= read -r _su_head < "$1" || return 1
  [ "$_su_head" = "# remote-harness shell snapshot: $shell" ] || return 1
  ! startup_files_changed "$1"
}

snapshot_reason() {  # $1=work dir $2=reason; adds the first lines the login shell wrote to stderr
  { printf '%s\n' "$2"; sed -n '1,5p' "$1/capture.err" 2>/dev/null || true; } > "$1/reason" 2>/dev/null \
    || true
}

# Capture into work dir $1: $1/snapshot when it loads silently and completely, else $1/reason. The
# snapshot gets the capture's start time, so a startup file edited during the capture is newer.
capture_snapshot() {
  _cs_work=$1
  : > "$_cs_work/stamp"
  case $shell_kind in
    bash) _cs_script=$(snapshot_capture_bash) ;;
    zsh) _cs_script=$(snapshot_capture_zsh) ;;
    *) snapshot_reason "$_cs_work" "unsupported shell: $shell"; return 1 ;;
  esac
  _cs_status=0
  run_with_timeout "$SNAPSHOT_CAPTURE_SECONDS" "$_cs_work/timed-out" "$shell" -lc "$_cs_script" \
    remote-harness "$_cs_work/snapshot" "$SNAPSHOT_SKIP_VARS" "$shell" \
    >/dev/null 2>"$_cs_work/capture.err" || _cs_status=$?
  if [ -f "$_cs_work/timed-out" ]; then
    snapshot_reason "$_cs_work" "the login shell did not finish within ${SNAPSHOT_CAPTURE_SECONDS}s"
    return 1
  fi
  if [ "$_cs_status" != 0 ] || [ ! -s "$_cs_work/snapshot" ]; then
    snapshot_reason "$_cs_work" "the login shell exited with status $_cs_status"
    return 1
  fi
  chmod 600 "$_cs_work/snapshot" 2>/dev/null || true
  # Loading must print exactly what the same shell prints without it. Output goes to files: a
  # daemon started from a startup file would hold a pipe open past the timeout.
  run_with_timeout "$SNAPSHOT_CHECK_SECONDS" "$_cs_work/timed-out" \
    "$shell" -c 'printf %s RH_SNAPSHOT_OK' >"$_cs_work/plain.out" 2>&1 || _cs_status=$?
  run_with_timeout "$SNAPSHOT_CHECK_SECONDS" "$_cs_work/timed-out" "$shell" -c \
    '. "$1" && [ "${__rh_snapshot_complete:-}" = 1 ] && printf %s RH_SNAPSHOT_OK' \
    remote-harness "$_cs_work/snapshot" >"$_cs_work/load.out" 2>&1 || _cs_status=$?
  if [ "$_cs_status" != 0 ] || [ -f "$_cs_work/timed-out" ] \
      || ! cmp -s "$_cs_work/plain.out" "$_cs_work/load.out"; then
    snapshot_reason "$_cs_work" "the snapshot did not load silently and completely"
    return 1
  fi
  touch -r "$_cs_work/stamp" "$_cs_work/snapshot"
}

# Replace $snapshot_dir/shell-snapshot.sh with a new capture. One command captures at a time; the
# others start a login shell meanwhile. A failure is recorded in shell-snapshot.failed (its reason,
# timed like the attempt) so later commands skip straight to a login shell until it may be retried.
refresh_snapshot() {
  _rs_target="$snapshot_dir/shell-snapshot.sh"
  _rs_failed="$snapshot_dir/shell-snapshot.failed"
  _rs_lock="$snapshot_dir/shell-snapshot.lock"
  [ -d "$snapshot_dir" ] && private_paths "$snapshot_dir" || return 1
  [ ! -d "$_rs_target" ] || [ -L "$_rs_target" ] || return 1
  if [ -f "$_rs_failed" ] && ! older_than "$_rs_failed" "$SNAPSHOT_RETRY_MIN" \
      && ! startup_files_changed "$_rs_failed"; then
    return 1
  fi
  if ! mkdir "$_rs_lock" 2>/dev/null; then
    # A lock older than any capture was left by a killed dispatcher. Two commands breaking it at
    # once only means two captures; each renames a complete snapshot into place.
    older_than "$_rs_lock" "$SNAPSHOT_LOCK_STALE_MIN" && rmdir "$_rs_lock" 2>/dev/null \
      && mkdir "$_rs_lock" 2>/dev/null || return 1
  fi
  snapshot_lock=$_rs_lock
  _rs_status=0
  if snapshot_work=$(mktemp -d "$snapshot_dir/.shell-snapshot.XXXXXX"); then
    capture_snapshot "$snapshot_work" || _rs_status=$?
  else
    snapshot_work=""
    _rs_status=1
  fi
  if [ "$_rs_status" = 0 ]; then
    if mv -f "$snapshot_work/snapshot" "$_rs_target"; then
      rm -f "$_rs_failed"
    else
      _rs_status=1
    fi
  elif [ -n "$snapshot_work" ]; then
    [ -s "$snapshot_work/reason" ] || printf '%s\n' "the capture could not run" > "$snapshot_work/reason"
    touch -r "$snapshot_work/stamp" "$snapshot_work/reason" 2>/dev/null || true
    mv -f "$snapshot_work/reason" "$_rs_failed" 2>/dev/null || true
  fi
  [ -z "$snapshot_work" ] || rm -rf "$snapshot_work"
  snapshot_work=""
  rmdir "$_rs_lock" 2>/dev/null || true
  snapshot_lock=""
  return "$_rs_status"
}

# Sets snapshot_file when this command can load a current snapshot instead of starting a login shell.
# RH_SHELL_SNAPSHOT=off at launch leaves shell-snapshot.off in the session directory.
select_shell_snapshot() {
  snapshot_file=""
  [ -n "$snapshot_dir" ] && [ -d "$snapshot_dir" ] || return 0
  case "${shell##*/}" in bash|zsh) shell_kind=${shell##*/} ;; *) return 0 ;; esac
  [ ! -e "$snapshot_dir/shell-snapshot.off" ] || return 0
  _sss_file="$snapshot_dir/shell-snapshot.sh"
  if snapshot_usable "$_sss_file" || { refresh_snapshot && snapshot_usable "$_sss_file"; }; then
    snapshot_file=$_sss_file
  fi
  return 0
}

dispatch() {
  # The gateway names this session's directory, which holds the snapshot; commands never see it.
  snapshot_dir=${RH_GATEWAY_SESSION_DIR:-}
  unset RH_GATEWAY_SESSION_DIR
  [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || fail "internal dispatch needs project root, cwd, and command"
  watch_mode=0
  if [ "$#" -eq 4 ]; then
    [ "$4" = watch ] || fail "unsupported dispatch mode"
    watch_mode=1
  fi
  command=$(decode_b64 "$3") || fail "could not decode command"
  if reject_direct_agent_launch "$command"; then
    fail "Agent processes must run on the remote agent host"
  fi
  resolve_target "$1" "$2"

  shell=${SHELL:-/bin/sh}
  case "$shell" in /*) ;; *) shell=/bin/sh ;; esac
  [ -x "$shell" ] || shell=/bin/sh
  export GIT_OPTIONAL_LOCKS=0
  start_agent_guard
  cd "$root_physical"
  select_shell_snapshot
  cd "$target_physical"
  # Credentials are dropped again after the profile (or zsh's .zshenv), which may export them.
  quoted_guard=$(sq "$guard_path")
  loaded=""
  guard="unset $AGENT_CREDENTIAL_VARS; PATH=$quoted_guard:\$PATH; export PATH;"
  if [ -n "$snapshot_file" ]; then
    # $loaded stays empty unless the snapshot loads completely, also when the shell dies loading it.
    # The command has not started then; the snapshot is dropped so the next command captures anew.
    loaded="$guard_path/snapshot-loaded"
    shell_flag=-c
    guarded_command=": >| $quoted_guard/snapshot-loaded; . $(sq "$snapshot_file") && [ \"\${__rh_snapshot_complete:-}\" = 1 ] && printf ok >| $quoted_guard/snapshot-loaded || { printf '%s\\n' 'remote-harness: the login shell snapshot did not load and was discarded; run the command again' >&2; exit 125; }; unset __rh_snapshot_complete; $guard $command"
  else
    shell_flag=-lc
    guarded_command="$guard $command"
  fi
  status=0
  if [ "$watch_mode" = 1 ] && stdin_is_channel; then
    run_watched "$shell" "$shell_flag" "$guarded_command" || status=$?
  else
    "$shell" "$shell_flag" "$guarded_command" || status=$?
  fi
  if [ -n "$snapshot_file" ] && [ -f "$loaded" ] && [ ! -s "$loaded" ]; then
    rm -f "$snapshot_file"
  fi
  finish_agent_guard "$status"
}

# Fixed tool path for direct tool dispatch. A forced-command SSH session has a minimal PATH and no
# login shell, so use the usual package-manager locations instead of sourcing user profiles. The same
# list finds the tool and becomes its PATH, so helpers git spawns (git-lfs, ...) resolve alike.
PROJECT_TOOL_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin"
PROJECT_TOOL_PATH="$PROJECT_TOOL_PATH:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
PROJECT_TOOL_PATH="$PROJECT_TOOL_PATH:$HOME/.nix-profile/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/sbin:/sbin"

find_project_tool() {  # $1=tool name
  _fpt_ifs=$IFS
  IFS=:
  for _fpt_dir in $PROJECT_TOOL_PATH; do
    IFS=$_fpt_ifs
    [ -x "$_fpt_dir/$1" ] && [ ! -d "$_fpt_dir/$1" ] || continue
    # macOS /usr/bin/git is a stub that only works once the Command Line Tools are installed.
    # xcode-select exists only on macOS; `command -v` is a builtin, so Linux pays no process here.
    if [ "$_fpt_dir/$1" = /usr/bin/git ] && command -v xcode-select >/dev/null 2>&1 \
        && ! xcode-select -p >/dev/null 2>&1; then
      continue
    fi
    printf '%s' "$_fpt_dir/$1"
    return 0
  done
  IFS=$_fpt_ifs
  return 1
}

# Run one allowlisted read-heavy tool (git or rg) directly, without a shell or login profile. Each
# argument arrives as base64("x" + arg), comma-separated, so empty arguments and trailing newlines
# survive. When stdin is the SSH channel, closing it (the agent-side caller was cancelled or the
# connection dropped) terminates the tool instead of leaving it scanning the project.
dispatch_tool() {
  [ "$#" -eq 4 ] || fail "internal tool dispatch needs project root, cwd, tool, and arguments"
  resolve_target "$1" "$2"
  tool=$3
  case "$tool" in git|rg) ;; *) fail "unsupported project tool" ;; esac
  spec=$4
  case "$spec" in -) ;; ""|*[!A-Za-z0-9+/=,]*) fail "invalid tool argument encoding" ;; esac

  set -f
  set --
  if [ "$spec" != - ]; then
    saved_ifs=$IFS
    IFS=,
    for encoded in $spec; do
      IFS=$saved_ifs
      [ -n "$encoded" ] || fail "invalid tool argument encoding"
      value=$(decode_b64 "$encoded"; printf .)
      value=${value%.}
      case "$value" in x*) value=${value#x} ;; *) fail "invalid tool argument framing" ;; esac
      set -- "$@" "$value"
      IFS=,
    done
    IFS=$saved_ifs
  fi
  set +f

  tool_path=$(find_project_tool "$tool") || {
    printf 'remote-harness: %s is not installed on the project host\n' "$tool" >&2
    exit 127
  }
  export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  start_agent_guard
  PATH="$guard_path:$PROJECT_TOOL_PATH"
  export PATH
  cd "$target_physical"

  status=0
  if stdin_is_channel; then
    run_watched "$tool_path" "$@" || status=$?
  else
    "$tool_path" "$@" </dev/null || status=$?
  fi
  finish_agent_guard "$status"
}

# Launch-time preflight on the project host: report where the tool verb would find $2.
if [ "${1:-}" = "--find-tool" ]; then
  [ "$#" -eq 2 ] || fail "--find-tool needs a tool name"
  find_project_tool "$2"
  exit
fi
if [ "${1:-}" = "--dispatch" ]; then
  shift
  dispatch "$@"
fi
if [ "${1:-}" = "--dispatch-tool" ]; then
  shift
  dispatch_tool "$@"
fi

# Multiplexing socket paths must stay short (Unix sockets allow ~104-108 bytes and OpenSSH appends a
# 17-byte temporary suffix while creating the master) and must not contain ssh_config tokens.
control_path_usable() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ "${#1}" -le 86 ]
}

ssh_config=""
alias_name=""
project_root=""
project_root_b64=""
relative_cwd=""
command_b64=""
tool=""
tool_args=""
control_path=""
use_mux=1
watch_command=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-config) [ "$#" -ge 2 ] || fail "missing --ssh-config value"; ssh_config=$2; shift 2 ;;
    --alias) [ "$#" -ge 2 ] || fail "missing --alias value"; alias_name=$2; shift 2 ;;
    --project-root) [ "$#" -ge 2 ] || fail "missing --project-root value"; project_root=$2; shift 2 ;;
    --project-root-b64) [ "$#" -ge 2 ] || fail "missing --project-root-b64 value"; project_root_b64=$2; shift 2 ;;
    --cwd-relative-b64) [ "$#" -ge 2 ] || fail "missing --cwd-relative-b64 value"; relative_cwd=$2; shift 2 ;;
    --command-b64) [ "$#" -ge 2 ] || fail "missing --command-b64 value"; command_b64=$2; shift 2 ;;
    --tool) [ "$#" -ge 2 ] || fail "missing --tool value"; tool=$2; shift 2 ;;
    --args-b64) [ "$#" -ge 2 ] || fail "missing --args-b64 value"; tool_args=$2; shift 2 ;;
    --control-path) [ "$#" -ge 2 ] || fail "missing --control-path value"; control_path=$2; shift 2 ;;
    --no-mux) use_mux=0; shift ;;
    --watch) watch_command=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -f "$ssh_config" ] || fail "session SSH config is unavailable"
case "$alias_name" in ""|-*|*[!A-Za-z0-9._-]*) fail "unsafe SSH alias" ;; esac
case "$project_root" in /*) ;; *) fail "project root must be absolute" ;; esac
relative_decoded=$(decode_b64 "$relative_cwd") || fail "could not decode relative working directory"
safe_relative_dir "$relative_decoded" || fail "invalid relative working directory"

# Callers may pass the root pre-encoded (it never changes within a session) to skip a base64 here; the
# project host checks the decoded root against the registered one either way.
[ -n "$project_root_b64" ] || project_root_b64=$(encode_b64 "$project_root")
case "$project_root_b64" in *[!A-Za-z0-9+/=]*) fail "invalid project root encoding" ;; esac
if [ -n "$tool" ]; then
  case "$tool" in git|rg) ;; *) fail "unsupported project tool" ;; esac
  case "$tool_args" in -) ;; ""|*[!A-Za-z0-9+/=,]*) fail "invalid tool argument encoding" ;; esac
  remote_command="remote-harness-tool $project_root_b64 $relative_cwd $tool $tool_args"
else
  [ -n "$command_b64" ] || command_b64=$(encode_b64 "")
  remote_command="remote-harness-exec $project_root_b64 $relative_cwd $command_b64"
  # The caller (channel-guard.py) holds stdin open for the command's lifetime; ask the project host
  # to stop the command tree when that channel closes.
  [ "$watch_command" = 0 ] || remote_command="$remote_command watch"
fi

# Per-connection tuning. Command-line -o values take precedence over the session ssh_config.
# ServerAlive detects a dead reverse tunnel in ~30s, so a wedged multiplexing master exits instead of
# hanging every later call; ControlPersist lets an idle master exit on its own even if session cleanup
# never runs (cleanup stops it at session end; an hour keeps it across normal pauses, since reopening
# it costs a full SSH handshake on every first call after the idle period). A stale socket left by a killed master is unlinked automatically by ControlMaster=auto.
set -- -F "$ssh_config" -T \
  -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 \
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o Compression=yes
if [ "$use_mux" = 1 ] && [ -n "$control_path" ] && control_path_usable "$control_path"; then
  set -- "$@" -o ControlMaster=auto -o "ControlPath=$control_path" -o ControlPersist=3600
else
  set -- "$@" -o ControlMaster=no -o ControlPath=none
fi
exec ssh "$@" "$alias_name" "$remote_command"
