# Personal agent preferences

One constitution and an on-demand Python development skill for GitHub Copilot,
Claude Code, and Codex. Installs at **user scope**, never into working repositories.

Four independent, dependency-free runtime implementations share the same content
and command-line contract. Pick one; there is no need to run all four.
No Rulesync, plugin manager, symlinks, agent CLI, or network access is required
after cloning.

## Install

Clone this public MIT-licensed repository and review the content and the
installer you choose. Nothing is published to PyPI or npm.

```text
git clone https://github.com/spencrr/agents.git
cd agents
```

Preview first:

| Implementation | Runtime | Command from this checkout |
| --- | --- | --- |
| POSIX shell | `sh` and standard utilities including `mktemp` | `sh ./install.sh --agents all --dry-run` |
| PowerShell | PowerShell 7.4+ on Windows, macOS, or Linux | `pwsh -NoProfile -File ./install.ps1 --agents all --dry-run` |
| Python | Python 3.10+, standard library only | `python -m spencrr_agents --agents all --dry-run` |
| Node/npm | Node.js 22+, built-in modules only | `node ./install.mjs --agents all --dry-run` |

Use `python3` instead of `python` where appropriate. Remove `--dry-run` after
reviewing the proposed destinations. Select individual agents with
`--agents ghcp,claude` or `--agents codex`.

To use the packaged entry points from a reviewed local checkout:

```text
uvx --from . spencrr-agents --agents all --dry-run
npm exec --package=. -- spencrr-agents --agents all --dry-run
```

The uvx command builds an isolated Python package; it requires no Node or
PowerShell. The npm command uses Node only, not Python. Initial package
preparation may fetch build tooling. Neither command publishes a package.
Use a reviewed tag or commit when distributing this checkout, rather than a
remote script piped into a shell.

After reviewing a revision, the packaged installers can also run directly from
GitHub. Replace `REV` with its full commit SHA:

```text
uvx --from "git+https://github.com/spencrr/agents.git@REV" spencrr-agents --agents all --dry-run
npm exec --package="github:spencrr/agents#REV" -- spencrr-agents --agents all --dry-run
```

## Targets

`~` below means the current user's home directory.

| Agent | Constitution | Python skill |
| --- | --- | --- |
| `ghcp` | `~/.copilot/copilot-instructions.md` | `~/.agents/skills/python-development/SKILL.md` |
| `claude` | `~/.claude/CLAUDE.md` | `~/.claude/skills/python-development/SKILL.md` |
| `codex` | `~/.codex/AGENTS.md` | `~/.agents/skills/python-development/SKILL.md` |

Copilot and Codex share the documented user-level `.agents/skills` location,
so selecting both writes that skill only once. The constitution is plain
Markdown; the skill has standard `name` and `description` frontmatter.
On-demand activation can be implicit when the task matches the description:
it is not a manual-only switch.

`COPILOT_HOME`, `CLAUDE_CONFIG_DIR`, and `CODEX_HOME` override their respective
agent configuration directories. The shared skill location remains under the
user's home. Environment overrides must be absolute paths.

`--home ABSOLUTE_PATH` overrides the user home and **ignores all three agent-home
environment overrides**. This is useful for isolated tests or preparing another
home directory. No runtime scans for agents or installs to unselected agents.

## Safety and existing preferences

- All sources, destinations, conflicts, and known shadowing files are preflighted
  before any installation writes.
- Identical files are left untouched, including their timestamps.
- Differing files cause a nonzero exit. Review and merge valuable existing rules
  into the source yourself before using `--force`: it replaces **whole files**,
  not just a managed section.
- `--force` saves the exact previous bytes under
  `~/.spencrr-agents/backups/`, outside native instruction and skill directories.
  Each replacement prints the destination-to-backup mapping. Backups are never
  pruned automatically.
- `--dry-run --force` previews replacements without creating files or backups.
- Existing files in other skills, instruction directories, or repositories are
  never swept or deleted.
- Symlinked destinations or ancestors are refused. Node and PowerShell also
  reject Windows junctions; use physical paths for configured homes.
- A nonempty Codex `AGENTS.override.md` is a blocker: it would hide the installed
  global constitution. `--force` does not bypass it.
- The old Copilot `instructions/python_development.instructions.md` from this
  setup is also a blocker. Review and move it outside discovery before installing
  the equivalent skill, to avoid double-loading the same guidance. Other duplicate
  copies or host-specific configuration are not automatically detected.

There is no unattended merging, automatic deletion, or uninstall command.
To undo, restore the exact files from the printed backups; remove newly installed
files only after checking that you have not edited them. Do not remove parent
directories or unrelated agent configuration.

Writes use temporary files in each destination directory, followed by rename
and byte-for-byte verification. This is **not a multi-file transaction**:
an I/O failure can leave earlier successful writes in place. Errors exit nonzero;
inspect the action log and backups before retrying. Do not run multiple installers
against the same home concurrently.

Paths containing tabs or newlines are unsupported. The shell installer additionally
requires normalized absolute paths without `.` or `..` components. Its Windows
support is through a POSIX environment such as Git Bash or WSL, not `cmd.exe`.

## Verify activation

Installation success means the expected files exist, not that a model followed
them. Start a fresh session in each selected agent and inspect its instruction
and skill diagnostics. Verify a main-agent task and a delegated task separately.
Remote containers and cloud agents use their own homes; this installer does not
propagate your local files to them.

Native references:

- [Copilot personal instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
- [Copilot personal skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)
- [Claude user instructions](https://code.claude.com/docs/en/memory)
- [Claude skills](https://code.claude.com/docs/en/skills)
- [Codex global instructions](https://developers.openai.com/codex/guides/agents-md)
- [Codex personal skills](https://developers.openai.com/codex/skills)
- [Agent Skills format](https://agentskills.io/specification)

## Development

Canonical content lives in [spencrr_agents/data](spencrr_agents/data); all installers
read the same files. The Python package includes them as package data, and the npm
package includes them through its explicit file list.

```text
uv run --locked python -m unittest discover -s tests -v
npm run check
uv build
npm pack --dry-run
```

Tests execute every available installer against temporary homes, checking exact
output, idempotency, backups, dry runs, conflicts, selected targets, environment
overrides, shadowing, and symlink refusal. Missing runtimes are reported as skips.
CI requires all four runtimes and runs on Windows, macOS, and Linux.
Windows symlink tests are skipped only if the OS denies symlink creation.

Keep behavior aligned across all four implementations; do not add a runtime
dependency on another implementation. MIT licensed; see [LICENSE](LICENSE).
