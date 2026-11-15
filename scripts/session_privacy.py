#!/usr/bin/env python3
"""Real center presentation profiles, with readers for frozen older session policies.

V3 keeps source mappings on the project host and leaves command/file results unchanged.
"""
from __future__ import annotations

import ipaddress
import base64
import json
import os
from pathlib import Path
import re
import stat
import sys
import hashlib
import uuid

METADATA_PATHS = ("/etc/timezone", "/etc/localtime", "/etc/hostname", "/etc/hosts",
                  "/etc/machine-id", "/etc/machine-info", "/var/lib/dbus/machine-id",
                  "/proc", "/sys/class/dmi/id", "/sys/devices/virtual/dmi/id")
HOST_ENV = ("HOSTNAME", "HOST", "SSH_TTY", "SSH_ORIGINAL_COMMAND")


def validate_timezone(value):
    if not isinstance(value, str) or len(value) > 128:
        raise ValueError("invalid session timezone")
    if value and (not re.fullmatch(r"[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*", value)
                  or not (Path("/usr/share/zoneinfo") / value).is_file()):
        raise ValueError("invalid session timezone")
    return value


def project_identity(encoded, timezone):
    if not encoded:
        # Direct/internal injection may provide only a timezone; never invent missing identities.
        return {"timezone": timezone}
    if len(encoded) > 8192:
        raise ValueError("project identity too large")
    data = json.loads(base64.b64decode(encoded, validate=True))
    return validate_identity(data, timezone)


def validate_identity(data, timezone=""):
    allowed = {"hostname", "ipv4", "ipv6", "machine_id", "timezone", "country", "region"}
    if not isinstance(data, dict) or data.keys() - allowed:
        raise ValueError("invalid project identity")
    for key, value in data.items():
        if not isinstance(value, str) or len(value) > 255 or any(ord(c) < 32 for c in value):
            raise ValueError("invalid project identity value")
        if value and key in ("ipv4", "ipv6"):
            if ipaddress.ip_address(value).version != (4 if key == "ipv4" else 6):
                raise ValueError("invalid project address family")
        elif value and key == "country" and not re.fullmatch(r"[A-Z]{2}", value):
            raise ValueError("invalid project country")
        elif value and key in ("hostname", "region") and not re.fullmatch(r"[A-Za-z0-9._-]+", value):
            raise ValueError("invalid project identity name")
        elif value and key == "machine_id" and not re.fullmatch(r"[0-9A-Fa-f-]+", value):
            raise ValueError("invalid project machine ID")
    validate_timezone(data.get("timezone", ""))
    if timezone and data.get("timezone") != timezone:
        raise ValueError("project identity timezone mismatch")
    return data


def capture_v2(path, timezone, mount=""):
    import socket
    import subprocess

    project = project_identity(os.environ.get("RH_PROJECT_IDENTITY_B64", ""), timezone)
    validate_timezone(timezone)
    identifiers = {}

    def add(value, kind):
        value = value.strip()
        if 4 <= len(value) <= 255 and not any(ord(c) < 32 for c in value):
            target_key = {"name": "hostname", "id": "machine_id"}.get(kind)
            if kind == "ip":
                target_key = "ipv4" if ipaddress.ip_address(value).version == 4 else "ipv6"
            target = project.get(target_key, "")
            if kind == "name" and "." not in value:
                target = target.split(".", 1)[0]
            if target:
                identifiers[value] = target
                if kind == "name":
                    identifiers[value.rstrip(".") + "."] = target

    def address(value):
        try:
            ip = ipaddress.ip_address(value.split("%", 1)[0])
        except ValueError:
            return
        if not (ip.is_loopback or ip.is_unspecified or ip.is_link_local):
            add(str(ip), "ip")
            add(ip.exploded, "ip")

    connection = os.environ.get("SSH_CONNECTION", "").split()
    if len(connection) == 4:
        address(connection[2])
    for value in (socket.gethostname(), os.environ.get("HOSTNAME", ""), os.environ.get("HOST", "")):
        add(value, "name")
        add(value.split(".", 1)[0], "name")
    # Local interface enumeration only: no DNS or external geolocation request.
    try:
        data = subprocess.check_output(["ip", "-j", "address", "show"], timeout=2,
                                       stderr=subprocess.DEVNULL)
        for interface in json.loads(data):
            for info in interface.get("addr_info", []):
                address(info.get("local", ""))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass  # SSH server address remains available on hosts without iproute2.
    for name, kind in (("/etc/hostname", "name"), ("/etc/machine-id", "id"),
                       ("/var/lib/dbus/machine-id", "id")):
        try:
            add(Path(name).read_text()[:255], kind)
        except OSError:
            pass
    zones = {os.environ.get("TZ", "").lstrip(":")}
    try:
        zones.add(Path("/etc/timezone").read_text().strip())
    except OSError:
        pass
    target = os.path.realpath("/etc/localtime")
    if "/zoneinfo/" in target:
        zones.add(target.split("/zoneinfo/", 1)[1])
    for zone in zones - {"", timezone}:
        if re.fullmatch(r"[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*", zone):
            # Unlabelled project data such as "Asia/Hong_Kong" must stay intact.
            for prefix in ("TZ=", "Timezone=", "Time zone: ", "/usr/share/zoneinfo/"):
                if timezone:
                    identifiers[prefix + zone] = prefix + timezone
    protected = (*METADATA_PATHS, str(Path(path).absolute().parent.parent))
    paths = sorted(set(protected) | {os.path.realpath(p) for p in protected})
    payload = {"version": 2, "timezone": timezone, "identifiers": identifiers, "deny_paths": paths,
               "project": project, "mount": os.path.realpath(mount) if mount else "",
               "metadata_paths": sorted(set(METADATA_PATHS) | {os.path.realpath(p) for p in METADATA_PATHS})}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(payload, stream)
    return Policy(path)  # Reject an unusable inventory before any agent/tool can start.


PROFILE_FIELDS = ("hostname", "ipv4", "ipv6", "machine_id", "timezone", "effective_tz", "effective_tzdir", "country", "region")


def profile_lines(profile):
    return "".join(f"{key.upper()}={profile.get(key, '')}\n" for key in PROFILE_FIELDS)


def validate_effective_timezone(value):
    """TZ file names, or POSIX std offset [dst [offset] [,start[/time],end[/time]]]."""
    if not isinstance(value, str) or len(value) > 255 or not re.fullmatch(r"[A-Za-z0-9_+<>/:,.-]*", value):
        raise ValueError("invalid effective center timezone")
    named = value[1:] if value.startswith(":") else value
    # A safe file name (including a custom TZDIR file) is ambiguous with a bare POSIX value.
    # The project cannot inspect center zone files, so preserve that original filename syntax.
    if not value or (re.fullmatch(r"[A-Za-z0-9_+/.-]+", named)):
        return value
    abbreviation = r"(?:[A-Za-z]{3,}|<[A-Za-z0-9+-]{3,}>)"
    clock = r"[+-]?\d{1,3}(?::\d{1,2}(?::\d{1,2})?)?"
    match = re.fullmatch(rf"({abbreviation})({clock})(?:({abbreviation})({clock})?(?:,([^,]+),([^,]+))?)?", named)
    if not match:
        raise ValueError("invalid POSIX timezone")

    def valid_clock(text, maximum):
        parts = text.lstrip("+-").split(":")
        return int(parts[0]) <= maximum and all(int(part) <= 59 for part in parts[1:])

    if not valid_clock(match[2], 24) or (match[4] and not valid_clock(match[4], 24)):
        raise ValueError("invalid POSIX timezone offset")
    for rule in (match[5], match[6]):
        if rule is None:
            continue
        date, *transition = rule.split("/")
        if len(transition) > 1 or (transition and (not re.fullmatch(clock, transition[0])
                                                  or not valid_clock(transition[0], 167))):
            raise ValueError("invalid POSIX transition time")
        month = re.fullmatch(r"M(\d{1,2})\.(\d)\.(\d)", date)
        if month:
            valid = 1 <= int(month[1]) <= 12 and 1 <= int(month[2]) <= 5 and int(month[3]) <= 6
        elif re.fullmatch(r"J?\d{1,3}", date):
            valid = (1 if date.startswith("J") else 0) <= int(date.lstrip("J")) <= 365
        else:
            valid = False
        if not valid:
            raise ValueError("invalid POSIX transition date")
    return value


def center_profile():
    """Capture the selected center, before session/daemon environment overlays. No DNS/geolocation."""
    import socket

    data = dict.fromkeys(PROFILE_FIELDS, "")
    data["hostname"] = socket.gethostname()
    for name in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            data["machine_id"] = Path(name).read_text().strip()
            break
        except OSError:
            pass
    zone = os.environ.get("TZ", "").lstrip(":")
    if "TZ" not in os.environ:
        link = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in link:
            zone = link.split("/zoneinfo/", 1)[1]
        else:
            try:
                candidate = Path("/etc/timezone").read_text().strip()
                validate_timezone(candidate)
                if Path("/etc/localtime").read_bytes() == (Path("/usr/share/zoneinfo") / candidate).read_bytes():
                    zone = candidate
            except (OSError, ValueError):
                zone = ""
    try:
        if not os.environ.get("TZDIR") or os.environ["TZDIR"] == "/usr/share/zoneinfo":
            data["timezone"] = validate_timezone(zone)
    except ValueError:
        pass  # An explicit POSIX TZ is effective even when there is no IANA conversion capability.
    data["effective_tz"] = os.environ.get("TZ", ":/etc/localtime")
    data["effective_tzdir"] = os.environ.get("TZDIR", "")
    connection = os.environ.get("SSH_CONNECTION", "").split()
    if len(connection) == 4:
        try:
            address = ipaddress.ip_address(connection[2])
            if not (address.is_loopback or address.is_unspecified or address.is_link_local):
                data[f"ipv{address.version}"] = str(address)
        except ValueError:
            pass
    # The SSH server endpoint is a verified presentation address; do not invent other interfaces.
    return validate_profile(data)


def decode_profile(encoded):
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) > 4096:
        raise ValueError("center profile too large")
    lines = raw.decode("ascii").splitlines(keepends=True)
    data = {}
    if len(lines) != len(PROFILE_FIELDS):
        raise ValueError("invalid center profile fields")
    for key, line in zip(PROFILE_FIELDS, lines):
        prefix = key.upper() + "="
        if not line.startswith(prefix) or not line.endswith("\n"):
            raise ValueError("invalid center profile record")
        data[key] = line[len(prefix):-1]
    return validate_profile(data)


def validate_profile(data):
    if not isinstance(data, dict) or set(data) != set(PROFILE_FIELDS):
        raise ValueError("invalid center profile fields")
    for key, value in data.items():
        if not isinstance(value, str) or not value.isascii():
            raise ValueError("invalid center profile value")
        if len(value) > 255 or any(ord(c) < 32 for c in value):
            raise ValueError("invalid center profile value")
        if key == "effective_tzdir":
            if value and (not value.startswith("/") or not re.fullmatch(r"[A-Za-z0-9_+/:,.-]+", value)):
                raise ValueError("unsupported center timezone directory")
        elif key == "effective_tz":
            validate_effective_timezone(value)
    validate_identity({key: value for key, value in data.items()
                       if key not in ("effective_tz", "effective_tzdir")})
    if not data["hostname"]:
        raise ValueError("center hostname unavailable")
    return data


def capture(path, timezone, mount=""):
    # Only existing frozen sessions retain v2 semantics; do not silently reverse that inventory.
    if os.environ.get("RH_PRESENTATION_POLICY") == "2":
        return capture_v2(path, timezone, mount)
    if timezone or os.environ.get("RH_SESSION_TZ") or os.environ.get("RH_PROJECT_IDENTITY_B64"):
        raise ValueError("v3 rejects legacy shared timezone/project identity; create a new session")
    encoded = os.environ.get("RH_CENTER_PROFILE_B64")
    profile = decode_profile(encoded) if encoded else center_profile()
    digest = hashlib.sha256(profile_lines(profile).encode()).hexdigest()
    summary = os.environ.get("RH_PRESENTATION_SUMMARY", "")
    binding = {}
    if summary:
        parts = summary.split(":")
        if len(parts) != 4 or any(not re.fullmatch(r"[0-9a-f]{64}", p) for p in parts):
            raise ValueError("invalid presentation binding")
        if parts[0] != digest:
            raise ValueError("center profile binding mismatch")
        binding = dict(zip(("center_profile_digest", "table_digest", "logical_digest", "registration_digest"), parts))
    protected = (*METADATA_PATHS, str(Path(path).absolute().parent.parent))
    payload = {"version": 3, "target_source": "agent_center", "execution_owner": "project_host",
               "target_profile": profile, "center_profile_digest": digest, "binding": binding,
               "presentation_id": str(uuid.uuid4()),
               "timezone": profile["timezone"], "mount": os.path.realpath(mount) if mount else "",
               "deny_paths": sorted(set(protected) | {os.path.realpath(p) for p in protected})}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(payload, stream)
    return Policy(path)


def private_directory(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("unsafe presentation storage")
    return path


def private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536:
            raise ValueError("unsafe presentation record")
        return json.load(stream)


def atomic_json(path, value):
    import tempfile

    path = Path(path)
    if path.is_symlink():
        raise ValueError("symlink presentation record")
    fd, temporary = tempfile.mkstemp(prefix=".profile.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def presentation_store(home):
    return private_directory(Path(home) / "presentation-v3")


def validate_presentation_id(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("invalid presentation ID")
    return value


def presentation_for_conversation(home, conversation):
    validate_presentation_id(conversation)
    store = presentation_store(home)
    alias = store / ("conversation-" + conversation + ".json")
    if alias.exists():
        return validate_presentation_id(private_json(alias)["presentation_id"])
    private_json(store / (conversation + ".json"))
    return conversation


def select_presentation(path, home, requested, agent):
    policy = Policy(path)
    if policy.version != 3:
        raise ValueError("cannot migrate a frozen legacy session")
    data = private_json(path)
    store = presentation_store(home)
    if requested != "new":
        identity = validate_presentation_id(requested)
        previous = private_json(store / (identity + ".json"))
        if previous.get("center_profile_digest") != data["center_profile_digest"]:
            raise ValueError("center identity changed; cannot resume this presentation")
        data["presentation_id"] = identity
        data["binding"] = previous["binding"]
        atomic_json(path, data)
    print("PRESENTATION_ID=" + data["presentation_id"])
    print("CENTER_PROFILE_B64=" + base64.b64encode(profile_lines(policy.project).encode()).decode())


def bind_presentation(path, home, summary, conversation=""):
    policy = Policy(path)
    parts = summary.split(":")
    if len(parts) != 4 or any(not re.fullmatch(r"[0-9a-f]{64}", p) for p in parts):
        raise ValueError("invalid presentation summary")
    data = private_json(path)
    binding = dict(zip(("center_profile_digest", "table_digest", "logical_digest", "registration_digest"), parts))
    if parts[0] != data["center_profile_digest"] or (data["binding"] and data["binding"] != binding):
        raise ValueError("presentation table binding changed")
    identity = validate_presentation_id(data["presentation_id"])
    store = presentation_store(home)
    record = {"version": 3, "presentation_id": identity, "target_profile": policy.project,
              "center_profile_digest": parts[0], "binding": binding}
    destination = store / (identity + ".json")
    if destination.exists() and private_json(destination) != record:
        raise ValueError("presentation record changed")
    if not destination.exists():
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream)
    data["binding"] = binding
    atomic_json(path, data)
    if conversation:
        conversation = validate_presentation_id(conversation)
        destination = Path(path).parent / "presentation-resume.env"
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(f"PRESENTATION_ID={identity}\nCONVERSATION_ID={conversation}\n")


def activate_presentation(path, home, agent):
    policy = Policy(path)
    if policy.version != 3:
        return
    data = private_json(path)
    if not data["binding"]:
        raise ValueError("project presentation table not bound")
    # No mount-wide "last" pointer: resume must name the exact conversation from its own marker.


def alias_presentation(home, conversation, identity):
    store = presentation_store(home)
    atomic_json(store / ("conversation-" + validate_presentation_id(conversation) + ".json"),
                {"presentation_id": validate_presentation_id(identity)})


class Policy:
    def __init__(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > 65536):
                raise ValueError("invalid privacy policy")
            data = json.load(stream)
        self.version = data.get("version")
        if self.version not in (1, 2, 3):
            raise ValueError("unsupported privacy policy")
        self.timezone = validate_timezone(data["timezone"])
        if self.version == 3:
            self.project = validate_profile(data["target_profile"])
            if (data.get("target_source") != "agent_center" or data.get("execution_owner") != "project_host"
                    or hashlib.sha256(profile_lines(self.project).encode()).hexdigest() != data.get("center_profile_digest")
                    or self.project["timezone"] != self.timezone
                    or "identifiers" in data or "project" in data):
                raise ValueError("invalid v3 center cache")
            validate_presentation_id(data["presentation_id"])
            binding = data.get("binding")
            if (not isinstance(binding, dict) or (binding and (
                    set(binding) != {"center_profile_digest", "table_digest", "logical_digest", "registration_digest"}
                    or any(not isinstance(v, str) or not re.fullmatch(r"[0-9a-f]{64}", v) for v in binding.values())
                    or binding["center_profile_digest"] != data["center_profile_digest"]))):
                raise ValueError("invalid v3 binding")
        else:
            self.project = validate_identity(data.get("project", {"timezone": self.timezone}), self.timezone)
        self.mount = data.get("mount", "")
        if not isinstance(self.mount, str) or self.mount and not os.path.isabs(self.mount):
            raise ValueError("invalid project mount")
        self.paths = data["deny_paths"]
        if not isinstance(self.paths, list) or any(not isinstance(p, str) or not p.startswith("/") for p in self.paths):
            raise ValueError("invalid privacy paths")
        self.paths = sorted(set(self.paths) | {os.path.realpath(p) for p in self.paths})
        self.metadata_paths = data.get("metadata_paths", list(METADATA_PATHS))
        if (not isinstance(self.metadata_paths, list)
                or any(not isinstance(p, str) or not os.path.isabs(p) for p in self.metadata_paths)):
            raise ValueError("invalid metadata sources")
        self.metadata_paths = set(self.metadata_paths) | {os.path.realpath(p) for p in self.metadata_paths}
        values = data.get("identifiers", {})
        if (not isinstance(values, dict) or len(values) > 512
                or any(not isinstance(k, str) or not 4 <= len(k) <= 512 or any(ord(c) < 32 for c in k)
                       or not isinstance(v, str) or len(v) > 128 for k, v in values.items())):
            raise ValueError("invalid privacy identifiers")
        # Version 1 inventories contain masking tokens, not verified counterparts. They are
        # readable for old wrapper environments, but must not be reused as replacement rules.
        self.values = {k.encode().lower(): v.encode() for k, v in values.items()} if data["version"] == 2 else {}
        parts = sorted(self.values, key=len, reverse=True)
        self.addresses = {}
        expressions = []
        for part in parts:
            try:
                address = ipaddress.ip_address(part.decode())
                self.addresses[address] = self.values[part]
            except ValueError:
                address = None
            boundary = rb"[\w.:]" if address and address.version == 6 else rb"[\w.-]"
            expressions.append(b"(?<!" + boundary + b")" + re.escape(part) + b"(?!" + boundary + b")")
        if any(ip.version == 6 for ip in self.addresses):
            expressions.append(rb"(?<![\w.:])[0-9a-f:.]{2,45}(?![\w.:])")
        self.pattern = re.compile(b"|".join(expressions), re.I) if expressions else None
        self.keep = max(45, max(map(len, parts), default=0)) + 1

    def replacement(self, match):
        value = self.values.get(match[0].lower())
        if value is not None:
            return value
        try:
            return self.addresses.get(ipaddress.ip_address(match[0].decode()), match[0])
        except ValueError:
            return match[0]

    def clean_bytes(self, data):
        return self.pattern.sub(self.replacement, data) if self.pattern else data

    def timestamp(self, value):
        if not self.timezone or not re.fullmatch(
                r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:?\d{2})", value):
            return value
        try:
            from datetime import datetime
            from zoneinfo import ZoneInfo
            instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return instant.astimezone(ZoneInfo(self.timezone)).isoformat(sep="T" if "T" in value else " ")
        except (ImportError, ValueError, KeyError):
            # Preserve the instant/offset when its interpretation or the zone is unavailable.
            return value

    def field(self, name, value):
        key = name.lower().replace("-", "_").replace(" ", "_")
        identity = {
            "hostname": "hostname", "host_name": "hostname", "server_hostname": "hostname",
            "agent_hostname": "hostname", "machine_id": "machine_id", "server_ip": "ipv4",
            "host_ip": "ipv4", "agent_ip": "ipv4", "primary_ipv4": "ipv4", "primary_ipv6": "ipv6",
            "tz": "timezone", "timezone": "timezone", "time_zone": "timezone",
            "country": "country", "country_code": "country", "region": "region",
        }.get(key)
        if identity:
            # Host/IP/ID counterparts apply only to values in the captured source inventory.
            if identity in ("ipv4", "ipv6"):
                try:
                    address = ipaddress.ip_address(value)
                except ValueError:
                    # A list or service endpoint needs a verified interface/port mapping of its
                    # own; replacing only its IP would invent an operational endpoint.
                    return value
                return self.addresses.get(address, value.encode()).decode()
            if identity in ("hostname", "machine_id"):
                return self.values.get(value.lower().encode(), value.encode()).decode()
            return self.project.get(identity) or value
        if key in ("timestamp", "server_time", "host_time", "current_time", "local_time"):
            return self.timestamp(value)
        if key in ("utc_offset", "timezone_offset", "timezone_abbr") and self.timezone:
            try:
                from datetime import datetime
                from zoneinfo import ZoneInfo
                now = datetime.now(ZoneInfo(self.timezone))
                if key == "timezone_abbr":
                    return now.tzname()
                offset = now.strftime("%z")
                return offset[:3] + ":" + offset[3:] if ":" in value else offset
            except (ImportError, KeyError):
                return value
        return value

    def clean(self, value, source="agent", field=""):
        if self.version == 3 or source != "agent":
            return value
        if isinstance(value, str):
            if field:
                replaced = self.field(field, value)
                if replaced != value:
                    return replaced
            if len(value) <= 256 * 1024 and value.lstrip().startswith(("{", "[")):
                try:
                    embedded = json.loads(value)
                except ValueError:
                    pass
                else:
                    if isinstance(embedded, (dict, list)):
                        updated = self.clean(embedded)
                        if updated != embedded:
                            return json.dumps(updated, ensure_ascii=False)
            # Only explicit metadata fields; ordinary prose, source code, email and business
            # values are not a trustworthy signal of a machine's location.
            pattern = r"(?m)^(?P<prefix>\s*(?P<key>[A-Za-z_][A-Za-z_ -]{0,30})\s*[:=]\s*)(?P<value>[^\r\n]*)$"
            return re.sub(pattern, lambda m: m["prefix"] + self.field(m["key"].strip(), m["value"]), value)
        if isinstance(value, list):
            return [self.clean(item) for item in value]
        if isinstance(value, dict):
            return {key: self.clean(item, field=key) for key, item in value.items()}
        return value

    def tool_result(self, event):
        if self.version == 3:
            return event.get("tool_response")
        # Routed shell and project files already report the real project host. Never rewrite them.
        name, args = event.get("tool_name"), event.get("tool_input", {})
        if name not in ("Read", "Grep") or not isinstance(args, dict):
            return event.get("tool_response")
        path = args.get("file_path") if name == "Read" else args.get("path", event.get("cwd"))
        if not isinstance(path, str) or not os.path.isabs(path):
            return event.get("tool_response")
        path = os.path.realpath(path)
        if self.mount and (path == self.mount or path.startswith(self.mount + "/")):
            return event.get("tool_response")
        if not any(path == root or path.startswith(root.rstrip("/") + "/") for root in self.metadata_paths):
            return event.get("tool_response")
        raw_field = next((field for filename, field in (
            ("/etc/timezone", "timezone"), ("/etc/hostname", "hostname"),
            ("/etc/machine-id", "machine_id"), ("/var/lib/dbus/machine-id", "machine_id"))
            if path == os.path.realpath(filename)), None)
        if raw_field and name == "Read":
            def contents(value, key=""):
                if isinstance(value, dict):
                    return {k: contents(v, k) for k, v in value.items()}
                if isinstance(value, list):
                    return [contents(item, key) for item in value]
                if isinstance(value, str) and key == "content":
                    return self.field(raw_field, value.strip()) + ("\n" if value.endswith("\n") else "")
                return value
            return contents(event.get("tool_response"))
        return self.clean(event.get("tool_response"))

    def stream(self, source="project"):
        return Passthrough() if source != "agent" else Stream(self)

    def environment(self, env):
        for key in HOST_ENV:
            env.pop(key, None)
        env.pop("RH_PROJECT_IDENTITY_B64", None)
        env.pop("RH_CENTER_PROFILE_B64", None)
        env.pop("RH_PRESENTATION_SUMMARY", None)
        if self.project.get("hostname"):
            env["HOSTNAME"] = env["HOST"] = self.project["hostname"]
        if "SSH_CONNECTION" in env:
            env["SSH_CONNECTION"] = "0.0.0.0 0 0.0.0.0 0"
        if "SSH_CLIENT" in env:
            env["SSH_CLIENT"] = "0.0.0.0 0 0"
        if self.version == 3:
            env.pop("TZDIR", None)
            if self.project["effective_tzdir"]:
                env["TZDIR"] = self.project["effective_tzdir"]
            env["TZ"] = self.project["effective_tz"]
        elif self.timezone:
            env.pop("TZDIR", None)
            env["TZ"] = self.timezone
        return env

    def local_search_allowed(self, argv, cwd):
        # A local fallback must not recursively scan a metadata tree or follow aliases into it.
        if any(a.split("=", 1)[0] in ("--follow", "--pre", "--hostname-bin")
               or (a.startswith("-") and not a.startswith("--") and "L" in a) for a in argv):
            return False
        candidates = [cwd]
        for arg in argv:
            value = arg.split("=", 1)[-1] if arg.startswith("--") else arg
            if value.startswith("-f") and len(value) > 2:
                value = value[2:]
            if not os.path.isabs(value):
                value = os.path.join(cwd, value)
            if os.path.exists(value):
                candidates.append(value)
        return all(self.path_allowed(value, cwd) for value in candidates)

    def path_allowed(self, value, cwd):
        actual = os.path.realpath(os.path.join(cwd, value))
        return all(actual != denied and not actual.startswith(denied + "/")
                   and not denied.startswith(actual.rstrip("/") + "/") for denied in self.paths)


class Passthrough:
    def feed(self, data, final=False):
        return data


class Stream:
    """Retain a bounded suffix so neither a chunk boundary nor truncation reveals a partial match."""
    def __init__(self, policy):
        self.policy = policy
        self.pending = b""
        self.previous = b""

    def feed(self, data, final=False):
        if not self.policy.pattern:
            return data
        self.pending += data
        # Registered values never contain newlines. Complete progress lines can pass immediately;
        # only a possibly incomplete match on the last line needs to wait for another chunk.
        cut = len(self.pending) if final else max(0, len(self.pending) - self.policy.keep,
                                                  self.pending.rfind(b"\n") + 1)
        source = self.previous + self.pending
        offset = len(self.previous)
        matches = list(self.policy.pattern.finditer(source))
        for match in matches:
            if match.start() < cut + offset < match.end():
                cut = max(0, match.start() - offset)
        end, pos, output = cut + offset, offset, []
        for match in matches:
            if match.start() >= pos and match.end() <= end:
                output += [source[pos:match.start()], self.policy.replacement(match)]
                pos = match.end()
        output.append(source[pos:end])
        if cut:
            self.previous = self.pending[cut - 1:cut]
        self.pending = self.pending[cut:]
        return b"".join(output)


def main():
    if sys.argv[1] == "center-profile":
        print(base64.b64encode(profile_lines(center_profile()).encode()).decode())
        return
    if sys.argv[1] == "select":
        select_presentation(*sys.argv[2:])
        return
    if sys.argv[1] == "bind":
        bind_presentation(*sys.argv[2:])
        return
    if sys.argv[1] == "activate":
        activate_presentation(*sys.argv[2:])
        return
    if sys.argv[1] in ("capture", "initialize"):
        policy = capture(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
        if sys.argv[1] == "initialize":
            marker = Path(sys.argv[2]).with_name("presentation-policy.json")
            fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump({"version": 1, "presentation_policy": policy.version}, stream)
            print(os.path.abspath(sys.executable))
        return
    policy = Policy(sys.argv[2])
    if sys.argv[1] == "launcher-env":
        import shlex

        print("project_hostname=" + shlex.quote(policy.project.get("hostname", "")))
        print("unset TZDIR || exit 125")
        print("export TZ=" + shlex.quote(policy.project.get("effective_tz", policy.timezone)))
        if policy.project.get("effective_tzdir"):
            print("export TZDIR=" + shlex.quote(policy.project["effective_tzdir"]))
        return
    if sys.argv[1] == "hostname":
        print(policy.project.get("hostname", ""))
        return
    if sys.argv[1] == "effective-tzdir":
        print(policy.project.get("effective_tzdir", ""))
        return
    if sys.argv[1] == "effective-tz":
        print(policy.project.get("effective_tz", policy.timezone))
        return
    event = json.load(sys.stdin)
    if sys.argv[1] == "post-tool":
        output = policy.tool_result(event)
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": output}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit("remote-harness: privacy policy unavailable")
