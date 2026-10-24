#!/bin/sh
set -eu
umask 077

die() { printf 'ERROR: %s\nInstallation stopped; inspect any reported changes and backups.\n' "$*" >&2; exit 1; }
usage='Usage: sh install.sh --agents ghcp,claude,codex|all [--home ABSOLUTE_PATH] [--dry-run] [--force]'
tab=$(printf '\t')
cr=$(printf '\r')
newline='
'
check_absolute() {
    case "$1" in
        ''|*"$tab"*|*"$cr"*|*"$newline"*) die "Paths must be nonempty and cannot contain tabs or newlines." ;;
    esac
    case "$1" in /*|[A-Za-z]:/*) ;; *) die "Use an absolute path: $1" ;; esac
    case "/$1/" in */../*|*/./*) die "Use a normalized absolute path: $1" ;; esac
}
check_path() {
    checked=$1
    file_allowed=${2:-false}
    first=true
    while :; do
        [ ! -L "$checked" ] || die "Refusing symlink: $checked"
        if [ -e "$checked" ]; then
            if [ "$first" = true ] && [ "$file_allowed" = true ]; then
                [ -f "$checked" ] || die "Unexpected file type: $checked"
            else
                [ -d "$checked" ] || die "Unexpected file type: $checked"
            fi
        fi
        parent=$(dirname "$checked")
        [ "$parent" != "$checked" ] || break
        checked=$parent
        first=false
    done
}

selected=
explicit_home=false
dry_run=false
force=false
home=${HOME:-}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) printf '%s\n' "$usage"; exit 0 ;;
        --agents|--home)
            option=$1
            [ "$#" -ge 2 ] || die "Missing value for $option"
            case "$2" in --*) die "Missing value for $option" ;; esac
            if [ "$option" = --agents ]; then selected=$2
            else home=$2; explicit_home=true; fi
            shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --force) force=true; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
case "$selected" in
    all) selected=ghcp,claude,codex ;;
    ''|,*|*,|*,,*) die "$usage" ;;
esac
check_absolute "$home"
check_path "$home"
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
data=$root/spencrr_agents/data
check_absolute "$data"
plan=
add_target() {
    record=$1$tab$2
    case "$newline$plan" in *"$newline$record$newline"*) return ;; esac
    plan=$plan$record$newline
}
agent_home() {
    if [ "$explicit_home" = true ] || [ -z "$1" ]; then agent_root=$home/$2
    else agent_root=$1; fi
    check_absolute "$agent_root"
}
remaining=$selected
while [ -n "$remaining" ]; do
    agent=${remaining%%,*}
    if [ "$remaining" = "$agent" ]; then remaining=; else remaining=${remaining#*,}; fi
    case "$agent" in
        ghcp)
            agent_home "${COPILOT_HOME:-}" .copilot
            legacy=$agent_root/instructions/python_development.instructions.md
            check_path "$legacy" true
            [ ! -e "$legacy" ] || die "Move the legacy Python instruction out of discovery first: $legacy"
            add_target "$data/constitution.md" "$agent_root/copilot-instructions.md"
            add_target "$data/python-development/SKILL.md" "$home/.agents/skills/python-development/SKILL.md" ;;
        claude)
            agent_home "${CLAUDE_CONFIG_DIR:-}" .claude
            add_target "$data/constitution.md" "$agent_root/CLAUDE.md"
            add_target "$data/python-development/SKILL.md" "$agent_root/skills/python-development/SKILL.md" ;;
        codex)
            agent_home "${CODEX_HOME:-}" .codex
            override=$agent_root/AGENTS.override.md
            check_path "$override" true
            [ ! -s "$override" ] || die "Codex global override would hide the constitution: $override"
            add_target "$data/constitution.md" "$agent_root/AGENTS.md"
            add_target "$data/python-development/SKILL.md" "$home/.agents/skills/python-development/SKILL.md" ;;
        *) die "$usage" ;;
    esac
done
backups=$home/.spencrr-agents/backups
check_path "$backups"
while IFS="$tab" read -r source destination; do
    [ -n "$source" ] || continue
    [ -s "$source" ] || die "Missing or empty bundled source: $source"
    check_path "$destination" true
    if [ -f "$destination" ]; then
        if cmp -s "$source" "$destination"; then :; else
            status=$?
            [ "$status" -eq 1 ] || die "Cannot compare file: $destination"
            [ "$force" = true ] || die "Conflicting file: $destination. Review it, then use --force to back up and replace."
        fi
    fi
done <<EOF
$plan
EOF

temporary=
trap 'if [ -n "$temporary" ]; then rm -f -- "$temporary"; fi' EXIT
trap 'exit 1' HUP INT TERM
while IFS="$tab" read -r source destination; do
    [ -n "$source" ] || continue
    check_path "$destination" true
    action=CREATE
    if [ -f "$destination" ]; then
        if cmp -s "$source" "$destination"; then action=UNCHANGED; else
            status=$?
            [ "$status" -eq 1 ] || die "Cannot compare file: $destination"
            [ "$force" = true ] || die "Conflicting file: $destination"
            action=REPLACE
        fi
    fi
    printf '%s %s\n' "$action" "$destination"
    if [ "$dry_run" = true ] || [ "$action" = UNCHANGED ]; then continue; fi
    if [ "$action" = REPLACE ]; then
        check_path "$backups"
        mkdir -p -- "$backups"
        backup=$(mktemp "$backups/$(basename "$destination").XXXXXX")
        cp -p -- "$destination" "$backup"
        cmp -s "$destination" "$backup" || die "Backup verification failed: $backup"
        printf 'BACKUP %s -> %s\n' "$destination" "$backup"
    fi
    parent=$(dirname "$destination")
    mkdir -p -- "$parent"
    temporary=$(mktemp "$parent/.spencrr-agents-XXXXXX")
    if [ "$action" = REPLACE ]; then cp -p -- "$destination" "$temporary"; fi
    cat -- "$source" > "$temporary"
    mv -f -- "$temporary" "$destination"
    temporary=
    cmp -s "$source" "$destination" || die "Installed content verification failed: $destination"
done <<EOF
$plan
EOF
if [ "$dry_run" = true ]; then printf 'Dry run: no files changed.\n'
else printf 'Installed files verified. Start a new agent session to verify loading.\n'; fi
