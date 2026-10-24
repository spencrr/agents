"""Install complete preference files; never merge or silently replace user content."""

import argparse
import os
from pathlib import Path
import stat
import sys
import tempfile
import uuid


DATA = Path(__file__).parent / "data"
AGENTS = ("ghcp", "claude", "codex")


def absolute_path(value: str) -> Path:
    if not value or any(character in value for character in "\r\n\t"):
        raise ValueError("Paths must be nonempty and cannot contain tabs or newlines.")
    path = Path(value)
    if not path.is_absolute():
        raise ValueError(f"Use an absolute path: {value}")
    return Path(os.path.abspath(path))


def check_path(path: Path, *, file_allowed: bool = False) -> None:
    """Reject redirected paths, special files, and non-directory ancestors."""
    for index, current in enumerate((path, *path.parents)):
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or (
            getattr(info, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
        ):
            raise ValueError(f"Refusing symlink or reparse point: {current}")
        if stat.S_ISDIR(info.st_mode) and not (index == 0 and file_allowed):
            continue
        if index == 0 and file_allowed and stat.S_ISREG(info.st_mode):
            continue
        raise ValueError(f"Unexpected file type: {current}")


def build_targets(agents: list[str], home: Path, isolated: bool) -> dict[Path, Path]:
    def agent_home(variable: str, default: str) -> Path:
        value = "" if isolated else os.environ.get(variable, "")
        return absolute_path(value) if value else home / default

    targets = {}
    shared_skill = home / ".agents" / "skills" / "python-development" / "SKILL.md"
    for agent in agents:
        if agent == "ghcp":
            root = agent_home("COPILOT_HOME", ".copilot")
            legacy = root / "instructions" / "python_development.instructions.md"
            check_path(legacy, file_allowed=True)
            if legacy.exists():
                raise ValueError(
                    f"Move the legacy Python instruction out of discovery first: {legacy}"
                )
            targets[root / "copilot-instructions.md"] = DATA / "constitution.md"
            targets[shared_skill] = DATA / "python-development" / "SKILL.md"
        elif agent == "claude":
            root = agent_home("CLAUDE_CONFIG_DIR", ".claude")
            targets[root / "CLAUDE.md"] = DATA / "constitution.md"
            targets[root / "skills" / "python-development" / "SKILL.md"] = (
                DATA / "python-development" / "SKILL.md"
            )
        else:
            root = agent_home("CODEX_HOME", ".codex")
            override = root / "AGENTS.override.md"
            check_path(override, file_allowed=True)
            if override.exists() and override.stat().st_size:
                raise ValueError(f"Codex global override would hide the constitution: {override}")
            targets[root / "AGENTS.md"] = DATA / "constitution.md"
            targets[shared_skill] = DATA / "python-development" / "SKILL.md"
    return targets


def install(args: argparse.Namespace) -> None:
    agents = list(AGENTS) if args.agents == "all" else args.agents.split(",")
    if not agents or any(agent not in AGENTS for agent in agents):
        raise ValueError("Choose --agents ghcp,claude,codex (any subset), or all.")
    agents = list(dict.fromkeys(agents))
    home = absolute_path(args.home if args.home is not None else str(Path.home()))
    check_path(home)
    targets = build_targets(agents, home, args.home is not None)
    backups = home / ".spencrr-agents" / "backups"
    check_path(backups)
    plan = []
    for destination, source in targets.items():
        check_path(destination, file_allowed=True)
        desired = source.read_bytes()
        if not desired:
            raise ValueError(f"Empty bundled source: {source}")
        previous = destination.read_bytes() if destination.exists() else None
        action = "CREATE" if previous is None else "UNCHANGED" if previous == desired else "REPLACE"
        if action == "REPLACE" and not args.force:
            raise ValueError(f"Conflicting file: {destination}. Review it, then use --force to back up and replace.")
        plan.append((destination, desired, previous, action))

    for destination, desired, previous, action in plan:
        print(f"{action} {destination}")
        if args.dry_run or action == "UNCHANGED":
            continue
        check_path(destination, file_allowed=True)
        current = destination.read_bytes() if destination.exists() else None
        if current != previous:
            raise ValueError(f"File changed during installation: {destination}")
        if previous is not None:
            check_path(backups)
            backups.mkdir(parents=True, exist_ok=True)
            backup = backups / f"{destination.name}.{uuid.uuid4().hex}.bak"
            with backup.open("xb") as stream:
                stream.write(previous)
            if backup.read_bytes() != previous:
                raise OSError(f"Backup verification failed: {backup}")
            print(f"BACKUP {destination} -> {backup}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(desired)
            if previous is not None:
                temporary.chmod(stat.S_IMODE(destination.stat().st_mode))
            temporary.replace(destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        if destination.read_bytes() != desired:
            raise OSError(f"Installed content verification failed: {destination}")
    print("Dry run: no files changed." if args.dry_run else "Installed files verified. Start a new agent session to verify loading.")


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
        print(f"ERROR: {error}\nInstallation stopped; inspect any reported changes and backups.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
