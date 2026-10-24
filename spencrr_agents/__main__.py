"""Install complete preference files; never merge or silently replace user content."""

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import stat
import sys
import tempfile
import uuid


DATA = Path(__file__).parent / "data"
AGENTS = {
    "ghcp": ("COPILOT_HOME", ".copilot", "copilot-instructions.md"),
    "claude": ("CLAUDE_CONFIG_DIR", ".claude", "CLAUDE.md"),
    "codex": ("CODEX_HOME", ".codex", "AGENTS.md"),
}


@dataclass(frozen=True)
class Change:
    destination: Path
    desired: bytes
    previous: bytes | None

    @property
    def action(self) -> str:
        if self.previous is None:
            return "CREATE"
        return "UNCHANGED" if self.previous == self.desired else "REPLACE"


def absolute_path(value: str) -> Path:
    if not value or any(character in value for character in "\r\n\t"):
        raise ValueError("Paths must be nonempty and cannot contain tabs or newlines.")
    path = Path(value)
    if not path.is_absolute():
        raise ValueError(f"Use an absolute path: {value}")
    return Path(os.path.abspath(path))


def check_path(path: Path, *, file_allowed: bool = False) -> None:
    """Reject redirected paths, special files, and non-directory ancestors."""
    for current in (path, *path.parents):
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or (
            getattr(info, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
        ):
            raise ValueError(f"Refusing symlink or reparse point: {current}")
        expected_type = stat.S_ISREG if current == path and file_allowed else stat.S_ISDIR
        if not expected_type(info.st_mode):
            raise ValueError(f"Unexpected file type: {current}")


def read_optional(path: Path) -> bytes | None:
    return path.read_bytes() if path.exists() else None


def build_targets(agents: list[str], home: Path, isolated: bool) -> dict[Path, Path]:
    targets: dict[Path, Path] = {}
    shared_skill = home / ".agents" / "skills" / "python-development" / "SKILL.md"
    for agent in agents:
        variable, directory, filename = AGENTS[agent]
        configured_home = "" if isolated else os.environ.get(variable, "")
        root = absolute_path(configured_home) if configured_home else home / directory

        if agent == "ghcp":
            legacy = root / "instructions" / "python_development.instructions.md"
            check_path(legacy, file_allowed=True)
            if legacy.exists():
                raise ValueError(
                    f"Move the legacy Python instruction out of discovery first: {legacy}"
                )
        elif agent == "codex":
            override = root / "AGENTS.override.md"
            check_path(override, file_allowed=True)
            if override.exists() and override.stat().st_size:
                raise ValueError(f"Codex global override would hide the constitution: {override}")
        skill = root / "skills" / "python-development" / "SKILL.md" if agent == "claude" else shared_skill
        targets[root / filename] = DATA / "constitution.md"
        targets[skill] = DATA / "python-development" / "SKILL.md"
    return targets


def preflight(targets: dict[Path, Path], force: bool) -> list[Change]:
    plan = []
    for destination, source in targets.items():
        check_path(destination, file_allowed=True)
        desired = source.read_bytes()
        if not desired:
            raise ValueError(f"Empty bundled source: {source}")
        change = Change(destination, desired, read_optional(destination))
        if change.action == "REPLACE" and not force:
            raise ValueError(
                f"Conflicting file: {destination}. "
                "Review it, then use --force to back up and replace."
            )
        plan.append(change)
    return plan


def write_change(change: Change, backups: Path) -> None:
    destination = change.destination
    check_path(destination, file_allowed=True)
    if read_optional(destination) != change.previous:
        raise ValueError(f"File changed during installation: {destination}")

    if change.previous is not None:
        check_path(backups)
        backups.mkdir(parents=True, exist_ok=True)
        backup = backups / f"{destination.name}.{uuid.uuid4().hex}.bak"
        with backup.open("xb") as stream:
            stream.write(change.previous)
        if backup.read_bytes() != change.previous:
            raise OSError(f"Backup verification failed: {backup}")
        print(f"BACKUP {destination} -> {backup}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(change.desired)
        if change.previous is not None:
            temporary.chmod(stat.S_IMODE(destination.stat().st_mode))
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    if destination.read_bytes() != change.desired:
        raise OSError(f"Installed content verification failed: {destination}")


def install(args: argparse.Namespace) -> None:
    agents = list(AGENTS) if args.agents == "all" else args.agents.split(",")
    if not agents or any(agent not in AGENTS for agent in agents):
        raise ValueError("Choose --agents ghcp,claude,codex (any subset), or all.")
    agents = list(dict.fromkeys(agents))
    home = absolute_path(args.home if args.home is not None else str(Path.home()))
    check_path(home)
    targets = build_targets(agents, home, isolated=args.home is not None)
    backups = home / ".spencrr-agents" / "backups"
    check_path(backups)
    plan = preflight(targets, args.force)

    for change in plan:
        print(f"{change.action} {change.destination}")
        if args.dry_run or change.action == "UNCHANGED":
            continue
        write_change(change, backups)
    if args.dry_run:
        print("Dry run: no files changed.")
    else:
        print("Installed files verified. Start a new agent session to verify loading.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agents", required=True, help="Comma-separated ghcp,claude,codex, or all")
    parser.add_argument("--home", help="Absolute home directory; ignores agent-home environment overrides")
    parser.add_argument("--dry-run", action="store_true", help="Preflight and print actions without writing")
    parser.add_argument("--force", action="store_true", help="Back up and replace conflicting complete files")
    args = parser.parse_args()
    try:
        install(args)
    except (OSError, ValueError) as error:
        print(
            f"ERROR: {error}\nInstallation stopped; inspect any reported changes and backups.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
