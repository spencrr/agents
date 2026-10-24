import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "spencrr_agents" / "data"
OVERRIDES = ("COPILOT_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME")
TARGETS = {
    ".copilot/copilot-instructions.md": DATA / "constitution.md",
    ".claude/CLAUDE.md": DATA / "constitution.md",
    ".codex/AGENTS.md": DATA / "constitution.md",
    ".agents/skills/python-development/SKILL.md": DATA / "python-development" / "SKILL.md",
    ".claude/skills/python-development/SKILL.md": DATA / "python-development" / "SKILL.md",
}


def shell_path(path: Path) -> str:
    return path.as_posix()


def commands() -> dict[str, list[str] | None]:
    shell = shutil.which("sh")
    if not shell and os.name == "nt":
        candidate = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "sh.exe"
        if candidate.exists():
            shell = str(candidate)
    node = shutil.which("node")
    pwsh = shutil.which("pwsh")
    return {
        "python": [sys.executable, "-m", "spencrr_agents"],
        "node": [node, str(ROOT / "install.mjs")] if node else None,
        "pwsh": [pwsh, "-NoProfile", "-File", str(ROOT / "install.ps1")] if pwsh else None,
        "sh": [shell, shell_path(ROOT / "install.sh")] if shell else None,
    }


class InstallerCases:
    command: list[str]
    runtime: str

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agents parity ")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.home = self.directory / "home with spaces"
        self.env = {key: value for key, value in os.environ.items() if key not in OVERRIDES}
        runtime_home = self.directory / "runtime home"
        runtime_home.mkdir()
        self.env["HOME"] = str(runtime_home)
        self.env["USERPROFILE"] = str(runtime_home)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
        self.env["NO_COLOR"] = "1"

    def run_installer(self, *args, success=True, explicit_home=True):
        home_args = ["--home", shell_path(self.home) if self.runtime == "sh" else str(self.home)] if explicit_home else []
        env = self.env.copy()
        if not explicit_home:
            env["HOME"] = str(self.home)
            env["USERPROFILE"] = str(self.home)
        result = subprocess.run(
            [*self.command, *home_args, *args],
            cwd=ROOT,
            env=env,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=30,
        )
        message = f"{self.runtime}: {result.returncode}\n{result.stdout}\n{result.stderr}"
        if success:
            self.assertEqual(result.returncode, 0, message)
        else:
            self.assertNotEqual(result.returncode, 0, message)
            self.assertIn("error", result.stderr.lower(), message)
        return result

    def write(self, relative, content=b"original user preferences\n"):
        target = self.home / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        return target

    def snapshot(self):
        if not self.home.exists():
            return {}
        return {
            str(path.relative_to(self.home)): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in self.home.rglob("*")
            if path.is_file() and not path.is_symlink()
        }

    def test_all_exact_content_and_idempotency(self):
        self.run_installer("--agents", "all")
        files = {path.relative_to(self.home).as_posix() for path in self.home.rglob("*") if path.is_file()}
        self.assertEqual(files, set(TARGETS))
        for relative, source in TARGETS.items():
            self.assertEqual((self.home / relative).read_bytes(), source.read_bytes())
        before = self.snapshot()
        result = self.run_installer("--agents", "all")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(result.stdout.count("UNCHANGED "), 5)
        self.assertFalse((self.home / ".spencrr-agents").exists())

    def test_selected_agent_and_duplicate_selection(self):
        self.run_installer("--agents", "codex,codex")
        self.assertTrue((self.home / ".codex" / "AGENTS.md").exists())
        self.assertTrue((self.home / ".agents" / "skills" / "python-development" / "SKILL.md").exists())
        self.assertFalse((self.home / ".claude").exists())
        self.assertFalse((self.home / ".copilot").exists())

    def test_dry_run_creates_nothing(self):
        result = self.run_installer("--agents", "all", "--dry-run")
        self.assertFalse(self.home.exists())
        self.assertEqual(result.stdout.count("CREATE "), 5)

    def test_conflict_preflight_prevents_partial_install(self):
        self.write(".codex/AGENTS.md")
        before = self.snapshot()
        self.run_installer("--agents", "all", success=False)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / ".copilot").exists())

    def test_force_backups_and_preserves_unrelated_files(self):
        original = b"\xef\xbb\xbfExisting preferences\r\n\x00binary preserved"
        self.write(".claude/CLAUDE.md", original)
        self.write(".agents/skills/unrelated/SKILL.md", b"unrelated\n")
        self.run_installer("--agents", "all", "--force")
        backups = list((self.home / ".spencrr-agents" / "backups").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual((self.home / ".agents/skills/unrelated/SKILL.md").read_bytes(), b"unrelated\n")
        self.assertEqual((self.home / ".claude/CLAUDE.md").read_bytes(), (DATA / "constitution.md").read_bytes())

    def test_force_dry_run_writes_no_backups(self):
        self.write(".claude/CLAUDE.md")
        before = self.snapshot()
        self.run_installer("--agents", "all", "--force", "--dry-run")
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / ".spencrr-agents").exists())
        self.assertFalse((self.home / ".copilot").exists())

    def test_empty_existing_file_is_backed_up(self):
        self.write(".claude/CLAUDE.md", b"")
        self.run_installer("--agents", "claude", success=False)
        self.run_installer("--agents", "claude", "--force")
        backups = list((self.home / ".spencrr-agents" / "backups").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b"")

    def test_shadowing_override_is_not_bypassed_by_force(self):
        self.write(".codex/AGENTS.override.md")
        before = self.snapshot()
        result = self.run_installer("--agents", "all", "--force", success=False)
        self.assertIn("override", result.stderr.lower())
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / ".copilot").exists())

    def test_empty_override_is_allowed(self):
        self.write(".codex/AGENTS.override.md", b"")
        self.run_installer("--agents", "codex")
        self.assertTrue((self.home / ".codex/AGENTS.md").exists())

    def test_legacy_python_instruction_requires_explicit_migration(self):
        self.write(".copilot/instructions/python_development.instructions.md")
        before = self.snapshot()
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / ".agents").exists())

    def test_directory_collision_is_rejected(self):
        (self.home / ".codex/AGENTS.md").mkdir(parents=True)
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertFalse((self.home / ".copilot").exists())

    def test_file_as_parent_is_rejected(self):
        self.write(".claude/skills", b"not a directory")
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertFalse((self.home / ".copilot").exists())

    def test_symlink_destination_is_rejected(self):
        outside = self.directory / "outside.md"
        outside.write_bytes(b"do not touch")
        destination = self.home / ".codex/AGENTS.md"
        destination.parent.mkdir(parents=True)
        try:
            destination.symlink_to(outside)
        except OSError as error:
            if os.name == "nt" and error.winerror == 1314:
                self.skipTest("Creating file symlinks requires Windows Developer Mode or privilege.")
            raise
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertEqual(outside.read_bytes(), b"do not touch")
        self.assertTrue(destination.is_symlink())
        self.assertFalse((self.home / ".copilot").exists())

    def test_symlink_parent_is_rejected(self):
        outside = self.directory / "outside"
        outside.mkdir()
        self.home.mkdir()
        try:
            (self.home / ".codex").symlink_to(outside, target_is_directory=True)
        except OSError as error:
            if os.name == "nt" and error.winerror == 1314:
                self.skipTest("Creating directory symlinks requires Windows Developer Mode or privilege.")
            raise
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.home / ".copilot").exists())

    def test_environment_home_overrides(self):
        roots = {variable: self.directory / variable.lower() for variable in OVERRIDES}
        for variable, root in roots.items():
            self.env[variable] = shell_path(root) if self.runtime == "sh" else str(root)
        self.run_installer("--agents", "all", explicit_home=False)
        for variable, filename in zip(OVERRIDES, ("copilot-instructions.md", "CLAUDE.md", "AGENTS.md")):
            self.assertEqual((roots[variable] / filename).read_bytes(), (DATA / "constitution.md").read_bytes())
        self.assertFalse((self.home / ".copilot").exists())
        self.assertTrue((self.home / ".agents/skills/python-development/SKILL.md").exists())

    @unittest.skipUnless(os.name == "nt", "Windows junction behavior")
    def test_windows_junction_parent_is_rejected(self):
        outside = self.directory / "outside junction"
        outside.mkdir()
        self.home.mkdir()
        junction = self.home / ".codex"
        result = subprocess.run(
            [os.environ["ComSpec"], "/c", "mklink", "/J", str(junction), str(outside)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.addCleanup(lambda: os.rmdir(junction))
        self.run_installer("--agents", "all", "--force", success=False)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.home / ".copilot").exists())

    def test_explicit_home_ignores_environment_overrides(self):
        outside = self.directory / "do not touch"
        self.env.update(dict.fromkeys(OVERRIDES, str(outside)))
        self.run_installer("--agents", "all")
        self.assertFalse(outside.exists())
        self.assertTrue((self.home / ".copilot/copilot-instructions.md").exists())

    def test_invalid_input_never_writes(self):
        for arguments in (
            (), ("--agents", "unknown"), ("--agents", "claude,"), ("--agents", ""),
            ("--agents", "all", "--surprise"), ("--agents",),
            ("--agents", "all", "--home", "relative-home"),
        ):
            with self.subTest(arguments=arguments):
                self.run_installer(*arguments, success=False)
                self.assertFalse(self.home.exists())

    def test_help_never_writes(self):
        self.run_installer("--help")
        self.assertFalse(self.home.exists())


for runtime, command in commands().items():
    if command is None and os.environ.get("REQUIRE_ALL_INSTALLERS") == "1":
        raise RuntimeError(f"Required runtime not found: {runtime}")
    cls = type(f"Test_{runtime}", (InstallerCases, unittest.TestCase), {"command": command, "runtime": runtime})
    if command is None:
        cls = unittest.skip(f"Runtime not found: {runtime}")(cls)
    globals()[cls.__name__] = cls
del cls


if __name__ == "__main__":
    unittest.main()
