# Agents

Personal [instructions](spencrr_agents/data/constitution.md) and a
[Python skill](spencrr_agents/data/python-development/SKILL.md) for Copilot,
Claude Code, and Codex. Installs in your home directory, not your projects.

## Install

```sh
git clone https://github.com/spencrr/agents.git
cd agents
```

Pick one. Each installer runs independently.

```sh
sh ./install.sh --agents all --dry-run
pwsh -NoProfile -File ./install.ps1 --agents all --dry-run
python -m spencrr_agents --agents all --dry-run
node ./install.mjs --agents all --dry-run
```

Requires POSIX sh, PowerShell 7.4+, Python 3.10+, or Node 22+, respectively.
Python and Node also have packaged commands:

```sh
uvx --from . spencrr-agents --agents all --dry-run
npm exec --package=. -- spencrr-agents --agents all --dry-run
```

Remove `--dry-run` to install. Replace `all` with `ghcp`, `claude`, `codex`,
or a comma-separated list.

## Files

| Agent | Instructions | Python skill |
| --- | --- | --- |
| `ghcp` | `~/.copilot/copilot-instructions.md` | `~/.agents/skills/python-development/SKILL.md` |
| `claude` | `~/.claude/CLAUDE.md` | `~/.claude/skills/python-development/SKILL.md` |
| `codex` | `~/.codex/AGENTS.md` | `~/.agents/skills/python-development/SKILL.md` |

- Existing files must match or installation stops. `--force` backs them up to
  `~/.spencrr-agents/backups/`, then replaces them entirely. No merging.
- Agent directories honor `COPILOT_HOME`, `CLAUDE_CONFIG_DIR`, and `CODEX_HOME`.
  `--home ABSOLUTE_PATH` overrides the home directory and ignores those variables.
- Symlinked paths, nonempty Codex `AGENTS.override.md`, and the old Copilot
  `instructions/python_development.instructions.md` block installation, even with
  `--force`. Move conflicting files out of discovery first.
- Failed installs can leave partial changes. Check the output and backups before
  retrying. Unrelated files are never removed.

Start a new agent session after installing. Check that instructions and the skill
load; subagent inheritance depends on the agent.

## Test

```sh
uv run --locked python -m unittest discover -s tests -v
```

The same tests run against all four installers on Linux, macOS, and Windows.

[MIT](LICENSE)
