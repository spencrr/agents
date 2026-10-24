#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const data = path.join(path.dirname(fileURLToPath(import.meta.url)), "spencrr_agents", "data");
const agents = new Map([
  ["ghcp", { environment: "COPILOT_HOME", directory: ".copilot", filename: "copilot-instructions.md" }],
  ["claude", { environment: "CLAUDE_CONFIG_DIR", directory: ".claude", filename: "CLAUDE.md" }],
  ["codex", { environment: "CODEX_HOME", directory: ".codex", filename: "AGENTS.md" }],
]);
const usage = "Usage: spencrr-agents --agents ghcp,claude,codex|all [--home ABSOLUTE_PATH] [--dry-run] [--force]";

function absolutePath(value) {
  if (!value || /[\r\n\t]/.test(value) || !path.isAbsolute(value)) {
    throw new Error(`Use an absolute path without tabs or newlines: ${value}`);
  }
  return path.resolve(value);
}

function statOrMissing(filename) {
  try {
    return fs.lstatSync(filename);
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}

function checkPath(filename, fileAllowed = false) {
  let current = filename;
  for (;;) {
    const info = statOrMissing(current);
    if (info) {
      if (info.isSymbolicLink()) throw new Error(`Refusing symlink or junction: ${current}`);
      const valid = current === filename && fileAllowed ? info.isFile() : info.isDirectory();
      if (!valid) throw new Error(`Unexpected file type: ${current}`);
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
}

function readOptional(filename) {
  return statOrMissing(filename) ? fs.readFileSync(filename) : undefined;
}

function sameBytes(left, right) {
  if (left === undefined || right === undefined) return left === right;
  return left.equals(right);
}

function parseOptions(argv) {
  const options = { dryRun: false, force: false };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      console.log(usage);
      return undefined;
    }
    if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "--force") {
      options.force = true;
    } else if (arg === "--agents" || arg === "--home") {
      const value = argv[++index];
      if (!value || value.startsWith("--")) throw new Error(`Missing value for ${arg}`);
      options[arg.slice(2)] = value;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  const selected = options.agents === "all" ? [...agents.keys()] : options.agents?.split(",");
  if (!selected?.length || selected.some((agent) => !agents.has(agent))) {
    throw new Error(usage);
  }
  options.agents = [...new Set(selected)];
  return options;
}

function buildTargets(selected, home, isolated) {
  const targets = new Map();
  const sharedSkill = path.join(home, ".agents", "skills", "python-development", "SKILL.md");
  for (const agent of selected) {
    const { environment, directory, filename } = agents.get(agent);
    const override = isolated ? undefined : process.env[environment];
    const root = override ? absolutePath(override) : path.join(home, directory);

    if (agent === "ghcp") {
      const legacy = path.join(root, "instructions", "python_development.instructions.md");
      checkPath(legacy, true);
      if (statOrMissing(legacy)) {
        throw new Error(`Move the legacy Python instruction out of discovery first: ${legacy}`);
      }
    } else if (agent === "codex") {
      const override = path.join(root, "AGENTS.override.md");
      checkPath(override, true);
      if (statOrMissing(override)?.size) {
        throw new Error(`Codex global override would hide the constitution: ${override}`);
      }
    }
    const skill = agent === "claude"
      ? path.join(root, "skills", "python-development", "SKILL.md")
      : sharedSkill;
    targets.set(path.join(root, filename), path.join(data, "constitution.md"));
    targets.set(skill, path.join(data, "python-development", "SKILL.md"));
  }
  return targets;
}

function preflight(targets, force) {
  return [...targets].map(([destination, source]) => {
    checkPath(destination, true);
    const desired = fs.readFileSync(source);
    if (!desired.length) throw new Error(`Empty bundled source: ${source}`);
    const previous = readOptional(destination);
    let action = "CREATE";
    if (previous !== undefined) action = sameBytes(previous, desired) ? "UNCHANGED" : "REPLACE";
    if (action === "REPLACE" && !force) {
      throw new Error(`Conflicting file: ${destination}. Review it, then use --force to back up and replace.`);
    }
    return { destination, desired, previous, action };
  });
}

function writeChange({ destination, desired, previous }, backups) {
  checkPath(destination, true);
  if (!sameBytes(readOptional(destination), previous)) {
    throw new Error(`File changed during installation: ${destination}`);
  }

  if (previous !== undefined) {
    checkPath(backups);
    fs.mkdirSync(backups, { recursive: true });
    const backup = path.join(backups, `${path.basename(destination)}.${randomUUID()}.bak`);
    fs.writeFileSync(backup, previous, { flag: "wx", mode: 0o600 });
    if (!fs.readFileSync(backup).equals(previous)) throw new Error(`Backup verification failed: ${backup}`);
    console.log(`BACKUP ${destination} -> ${backup}`);
  }

  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const temporary = path.join(path.dirname(destination), `.spencrr-agents-${randomUUID()}`);
  try {
    fs.writeFileSync(temporary, desired, { flag: "wx", mode: 0o600 });
    if (previous !== undefined) fs.chmodSync(temporary, fs.statSync(destination).mode & 0o777);
    fs.renameSync(temporary, destination);
  } finally {
    if (statOrMissing(temporary)) fs.unlinkSync(temporary);
  }
  if (!fs.readFileSync(destination).equals(desired)) {
    throw new Error(`Installed content verification failed: ${destination}`);
  }
}

function main(argv) {
  const options = parseOptions(argv);
  if (!options) return;
  const home = absolutePath(options.home ?? os.homedir());
  checkPath(home);
  const targets = buildTargets(options.agents, home, options.home !== undefined);
  const backups = path.join(home, ".spencrr-agents", "backups");
  checkPath(backups);
  const plan = preflight(targets, options.force);

  for (const change of plan) {
    console.log(`${change.action} ${change.destination}`);
    if (options.dryRun || change.action === "UNCHANGED") continue;
    writeChange(change, backups);
  }
  if (options.dryRun) {
    console.log("Dry run: no files changed.");
  } else {
    console.log("Installed files verified. Start a new agent session to verify loading.");
  }
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(`ERROR: ${error.message}\nInstallation stopped; inspect any reported changes and backups.`);
  process.exitCode = 1;
}
