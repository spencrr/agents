#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const data = path.join(path.dirname(fileURLToPath(import.meta.url)), "spencrr_agents", "data");
const supported = ["ghcp", "claude", "codex"];
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

function same(left, right) {
  return left === undefined ? right === undefined : right !== undefined && left.equals(right);
}

function main(argv) {
  const options = { dryRun: false, force: false };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      console.log(usage);
      return;
    }
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--force") options.force = true;
    else if (arg === "--agents" || arg === "--home") {
      const value = argv[++index];
      if (!value || value.startsWith("--")) throw new Error(`Missing value for ${arg}`);
      options[arg.slice(2)] = value;
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  const agents = options.agents === "all" ? supported : options.agents?.split(",");
  if (!agents?.length || agents.some((agent) => !supported.includes(agent))) {
    throw new Error(usage);
  }
  const home = absolutePath(options.home ?? os.homedir());
  checkPath(home);
  const agentHome = (variable, fallback) =>
    options.home !== undefined || !process.env[variable]
      ? path.join(home, fallback)
      : absolutePath(process.env[variable]);
  const targets = new Map();
  const add = (destination, source) => targets.set(destination, path.join(data, source));
  const sharedSkill = path.join(home, ".agents", "skills", "python-development", "SKILL.md");
  for (const agent of new Set(agents)) {
    if (agent === "ghcp") {
      const root = agentHome("COPILOT_HOME", ".copilot");
      const legacy = path.join(root, "instructions", "python_development.instructions.md");
      checkPath(legacy, true);
      if (statOrMissing(legacy)) throw new Error(`Move the legacy Python instruction out of discovery first: ${legacy}`);
      add(path.join(root, "copilot-instructions.md"), "constitution.md");
      add(sharedSkill, "python-development/SKILL.md");
    } else if (agent === "claude") {
      const root = agentHome("CLAUDE_CONFIG_DIR", ".claude");
      add(path.join(root, "CLAUDE.md"), "constitution.md");
      add(path.join(root, "skills", "python-development", "SKILL.md"), "python-development/SKILL.md");
    } else {
      const root = agentHome("CODEX_HOME", ".codex");
      const override = path.join(root, "AGENTS.override.md");
      checkPath(override, true);
      if (statOrMissing(override)?.size) throw new Error(`Codex global override would hide the constitution: ${override}`);
      add(path.join(root, "AGENTS.md"), "constitution.md");
      add(sharedSkill, "python-development/SKILL.md");
    }
  }
  const backups = path.join(home, ".spencrr-agents", "backups");
  checkPath(backups);
  const plan = [...targets].map(([destination, source]) => {
    checkPath(destination, true);
    const desired = fs.readFileSync(source);
    if (!desired.length) throw new Error(`Empty bundled source: ${source}`);
    const previous = readOptional(destination);
    const action = previous === undefined ? "CREATE" : same(previous, desired) ? "UNCHANGED" : "REPLACE";
    if (action === "REPLACE" && !options.force) {
      throw new Error(`Conflicting file: ${destination}. Review it, then use --force to back up and replace.`);
    }
    return { destination, desired, previous, action };
  });
  for (const { destination, desired, previous, action } of plan) {
    console.log(`${action} ${destination}`);
    if (options.dryRun || action === "UNCHANGED") continue;
    checkPath(destination, true);
    if (!same(readOptional(destination), previous)) throw new Error(`File changed during installation: ${destination}`);
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
    if (!fs.readFileSync(destination).equals(desired)) throw new Error(`Installed content verification failed: ${destination}`);
  }
  console.log(options.dryRun ? "Dry run: no files changed." : "Installed files verified. Start a new agent session to verify loading.");
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(`ERROR: ${error.message}\nInstallation stopped; inspect any reported changes and backups.`);
  process.exitCode = 1;
}
