#!/usr/bin/env python3
"""Test-only command boundary: no real Docker, sudo, downloads or cron changes."""
import gzip
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile

ROOT = Path(os.environ["CCC_TEST_ROOT"]).resolve()
STATE = ROOT / "state.json"
state = json.loads(STATE.read_text())


def record(command, args, elevated=False):
    with (ROOT / "calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": command, "args": args, "elevated": elevated,
                                 "scope": os.environ.get("CCC_TEST_SCOPE", "host")}) + "\n")


def mapped(arg):
    for prefix in ("/var/ssl", "/var/www/challenges", "/opt/gitea", "/etc/aria2",
                   "/etc/gost", "/etc/systemd/system", "/usr/local/bin"):
        if arg == prefix or arg.startswith(prefix + "/"):
            return str(ROOT / "fs" / arg.lstrip("/"))
    return arg


def container_script(args):
    script = args[args.index("-c") + 1]
    (ROOT / "container-command.sh").write_text(script)
    if not state.get("execute_container"):
        return 0
    env = dict(os.environ, CCC_TEST_SCOPE="container")
    directory = ROOT / "container"
    directory.mkdir(exist_ok=True)
    return subprocess.run(["/bin/sh" if "sh" in args else "/bin/bash", "-c", script],
                          cwd=directory, env=env).returncode


def docker(args):
    if args[0] == "info":
        return int(state.get("docker_unavailable", False))
    if args[:2] == ["container", "inspect"]:
        return 0 if args[2] in state.get("containers", []) else 1
    if args[:2] == ["volume", "inspect"]:
        return 0 if args[2] in state.get("volumes", []) else 1
    if args[:2] == ["volume", "create"]:
        state.setdefault("volumes", []).append(args[2])
        STATE.write_text(json.dumps(state))
        return 0
    if args[:2] == ["network", "inspect"]:
        return 0
    if args[0] == "ps":
        if state.get("nginx_backend", "docker") == "docker":
            print("nginx1")
        return 0
    if args[0] == "run":
        if state.get("run_failure"):
            return 125
        if "-c" in args:
            return container_script(args)
        print("test-container-id")
        return 0
    if args[:3] == ["exec", "nginx1", "nginx"]:
        return nginx(args[3:])
    if args[0] == "exec":
        return container_script(args) if "-c" in args else 0
    if args[0] == "logs":
        return 0
    raise RuntimeError("Unexpected Docker command: " + repr(args))


def nginx(args):
    return int((args == ["-t"] and state.get("nginx_test_failure", False)) or
               (args == ["-s", "reload"] and state.get("nginx_reload_failure", False)))


def download(args):
    if state.get("download_failure"):
        return 1
    url = next(arg for arg in args if arg.startswith("https://"))
    target = Path(mapped(args[args.index("-O") + 1] if "-O" in args else url.rsplit("/", 1)[1]))
    if "acme_tiny.py" in url:
        target.write_text(
            "import os, pathlib, sys\n"
            "root = pathlib.Path(os.environ['CCC_TEST_ROOT'])\n"
            "(root / 'acme.executed').touch()\n"
            "print((root / 'issued.crt').read_text())\n"
            "sys.exit(int(os.environ.get('CCC_ACME_FAILURE', '0')))\n")
    elif target.name.endswith(".tar.gz"):
        with tarfile.open(target, "w:gz") as archive:
            item = tarfile.TarInfo(target.name.removesuffix(".tar.gz") + "/frps")
            data = b"#!/bin/sh\nexit 0\n"
            item.size = len(data)
            item.mode = 0o755
            archive.addfile(item, io.BytesIO(data))
    elif target.name.endswith(".gz"):
        target.write_bytes(gzip.compress(b"#!/bin/sh\nexit 0\n"))
    else:
        target.write_text("# fixture configuration\n")
    return 0


def sudo(args):
    command, args = args[0], args[1:]
    record(command, args, elevated=True)
    if state.get("sudo_fail_command") == command:
        return 1
    if command in {"apt", "systemctl"}:
        return 0
    if command == "docker":
        return docker(args)
    if command == "nginx":
        return nginx(args)
    if command == "wget":
        return download(args)
    if command == "tee":
        data = sys.stdin.read()
        Path(mapped(args[0])).write_text(data)
        sys.stdout.write(data)
        return 0
    if command == "sh" and args[:2] == ["-c", 'LC_ALL=C crontab -l 2>"$1"']:
        error = Path(mapped(args[-1]))
        if state.get("cron_read_failure"):
            error.write_text("crontab: permission denied\n")
            return 1
        if not (ROOT / "crontab").exists():
            error.write_text("no crontab for test\n")
            return 1
        error.write_text("")
        sys.stdout.write((ROOT / "crontab").read_text())
        return 0
    if command == "crontab" and args == ["-"]:
        (ROOT / "crontab").write_text(sys.stdin.read())
        return 0
    if command == "sh":
        assert args[:2] == ["-c", 'umask 022; exec /usr/bin/python3 "$@"'], args
    else:
        assert command in {"test", "install", "mktemp", "openssl", "chmod", "chown", "ln",
                           "rm", "cp", "mv", "grep", "mkdir", "touch", "tar"}, command
    args = [mapped(arg) for arg in args]
    if command == "install":
        # Tests run without privileges; preserve modes, omit ownership changes.
        for flag in ("-o", "-g"):
            if flag in args:
                index = args.index(flag)
                del args[index:index + 2]
    if command == "rm":
        for arg in args:
            if not arg.startswith("-"):
                assert Path(arg).resolve().is_relative_to(ROOT), arg
    # Emulate sudo access to a fixture directory that the ordinary shell cannot write.
    protected = ROOT / "protected"
    mode = protected.stat().st_mode & 0o777 if protected.exists() else None
    try:
        if mode is not None:
            protected.chmod(mode | 0o700)
        return subprocess.run([command, *args]).returncode
    finally:
        if mode is not None:
            protected.chmod(mode)


def main():
    command = Path(sys.argv[0]).name
    args = sys.argv[1:]
    if command == "sudo":
        return sudo(args)
    record(command, args)
    if command in {"apt", "systemctl"}:
        return 77  # Host administration requires sudo in these tests.
    if command == "wget":
        return download(args)
    if command in {"apt-get", "git", "npm", "python3"}:
        action = next((arg for arg in args if not arg.startswith("-")), "")
        stage = command + (":" + action if action else "")
        return 1 if state.get("fail_stage") == stage else 0
    if command == "curl":
        if state.get("download_failure"):
            return 22
        target = Path(args[args.index("-o") + 1])
        if any(arg.endswith("/ccc.sh") for arg in args):
            target.write_text(state.get("upgrade_payload", "#!/bin/bash\nprintf 'updated\\n'\n"))
            return 0
        target.write_text('printf "%s" "$CCC_TEST_SCOPE" > "$CCC_TEST_ROOT/installer.scope"\n')
        return 0
    raise RuntimeError("Unexpected direct command: " + command)


if __name__ == "__main__":
    sys.exit(main())
