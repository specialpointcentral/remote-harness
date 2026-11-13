#!/usr/bin/env python3
"""Build an isolated `orca` test CLI from an orcad bundle that an Orca desktop pushed to this host.

usage: orca_bundle.py <bundle-dir> <work-dir>

The bundle (for example ~/.orca-remote/orcad-0.1.0+<build>) is copied into <work-dir>, so the
test server never writes readiness or PID files into a bundle that a live server is using. The
printed CLI supports only `--version` and `serve --no-pairing --port N`. It requires
ORCA_USER_DATA_PATH under $HOME, so a test cannot start a server on the user's real profile.
"""
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


def main():
    bundle = Path(sys.argv[1]).expanduser().resolve(strict=True)
    work = Path(sys.argv[2]).resolve()
    runtime_id = (bundle / ".runtime-node").read_text(encoding="utf8").strip()
    runtime = bundle.parent / "runtimes" / f"node-{runtime_id}"
    node = runtime / "bin" / "node"
    for required in (bundle / "orcad.js", bundle / "out" / "cli" / "index.js", node):
        if not required.is_file():
            sys.exit(f"orca_bundle: {required} is missing; pass an orcad bundle directory.")
    copy = work / "bundles" / bundle.name
    if not copy.exists():
        shutil.copytree(bundle, copy, symlinks=True,
                        ignore=shutil.ignore_patterns(".orcad-*", "*.log"))
    # orcad finds its pinned Node runtime beside the bundle and refuses to start without it.
    link = work / "bundles" / "runtimes" / runtime.name
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.is_symlink():
        link.symlink_to(runtime, target_is_directory=True)
    version = subprocess.check_output([str(node), str(copy / "out" / "cli" / "index.js"), "--version"],
                                      text=True, timeout=30).strip()
    build = bundle.name[len("orcad-"):] if bundle.name.startswith("orcad-") else bundle.name
    cli = work / f"orca-{version}"
    cli.write_text(f"""#!/bin/sh
# Test stand-in for `orca`, built by tests/fixtures/orca_bundle.py from {bundle}.
unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE ELECTRON_RUN_AS_NODE ORCA_ORCAD_MANAGED_ACTIVATION_ROOT
node={shlex.quote(str(node))}
bundle={shlex.quote(str(copy))}
case "${{1:-}}" in
  --version) exec "$node" "$bundle/out/cli/index.js" --version ;;
  serve)
    [ "$#" -eq 4 ] && [ "$2" = --no-pairing ] && [ "$3" = --port ] || {{ echo "unsupported: $*" >&2; exit 2; }}
    case "${{ORCA_USER_DATA_PATH:-}}" in
      "$HOME"/?*) ;;
      *) echo "ORCA_USER_DATA_PATH must be a test profile under HOME" >&2; exit 2 ;;
    esac
    export ORCA_USER_DATA="$ORCA_USER_DATA_PATH" ORCA_VERSION={shlex.quote(build)}
    exec "$node" --disable-wasm-trap-handler --wasm-max-mem-pages=1024 --max-semi-space-size=8 \\
      "$bundle/orcad.js" --json --bind 127.0.0.1 --port "$4" ;;
  *) echo "unsupported: $*" >&2; exit 2 ;;
esac
""", encoding="utf8")
    cli.chmod(0o700)
    print(cli)


if __name__ == "__main__":
    main()
