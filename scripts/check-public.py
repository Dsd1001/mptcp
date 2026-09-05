#!/usr/bin/env python3
"""Check a reviewed source tree or release archive before publication."""
import argparse
import ipaddress
import pathlib
import re
import tarfile

ROOT_FILES = {".gitignore", ".gitattributes", "README.md", "README.zh-CN.md", "install.sh"}
ROOT_DIRS = {"bin", "lib", "systemd", "examples", "tunnel", "tests", "scripts", "docs", "payload"}
PATTERNS = (
    rb"-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----",
    rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
    rb"AKIA[A-Z0-9]{16}",
    rb"(?i)(?:password|passwd|api[_-]?key|access[_-]?token)\s*[:=]\s*[\"']?[^\s\"']{8,}",
    rb"/(?:Users|home)/[A-Za-z0-9_.-]+/",
    rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
)
DOC_NETS = tuple(ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))


def inspect(name, data):
    p = pathlib.PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or not p.parts:
        raise ValueError("unsafe path")
    if name not in ROOT_FILES and p.parts[0] not in ROOT_DIRS:
        raise ValueError("path outside publication allowlist")
    if p.name.startswith("._") or p.name == ".DS_Store":
        raise ValueError("platform metadata")
    for pattern in PATTERNS:
        if re.search(pattern, data):
            raise ValueError("credential, personal path or contact pattern")
    if data.startswith(b"\x7fELF"):
        return
    text = data.decode("utf-8")
    for candidate in re.findall(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", text.replace(r"\.", ".")):
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue  # Deliberately invalid parser-test inputs.
        if address.is_unspecified or address.is_loopback or any(address in net for net in DOC_NETS):
            continue
        raise ValueError("non-documentation network address")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=pathlib.Path)
    args = parser.parse_args()
    count = 0
    errors = []

    def check(name, data):
        nonlocal count
        count += 1
        try:
            inspect(name, data)
        except (ValueError, UnicodeError) as exc:
            errors.append(f"{name}: {exc}")

    if args.path.is_dir():
        for path in sorted(args.path.rglob("*")):
            if path.is_symlink():
                errors.append(f"{path.relative_to(args.path)}: symlink not allowed")
            elif path.is_file():
                check(path.relative_to(args.path).as_posix(), path.read_bytes())
    else:
        with tarfile.open(args.path, "r:gz") as archive:
            for member in archive:
                if member.isdir():
                    continue
                if not member.isfile() or member.pax_headers:
                    errors.append(f"{member.name}: link or archive metadata not allowed")
                    continue
                with archive.extractfile(member) as stream:
                    check(member.name.removeprefix("./"), stream.read())
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Publication scan passed: {count} files")


if __name__ == "__main__":
    main()
