#!/bin/sh
set -eu
umask 077

usage='Usage: sh install.sh --agents ghcp,claude,codex|all [--home ABSOLUTE_PATH] [--dry-run] [--force]'
tab=$(printf '\t')
cr=$(printf '\r')
newline='
'

die() {
    printf 'ERROR: %s\nInstallation stopped; inspect any reported changes and backups.\n' "$*" >&2
    exit 1
}

check_absolute() {
    case "$1" in
        ''|*"$tab"*|*"$cr"*|*"$newline"*)
            die "Paths must be nonempty and cannot contain tabs or newlines." ;;
    esac
    case "$1" in
        /*|[A-Za-z]:/*) ;;
        *) die "Use an absolute path: $1" ;;
    esac
    case "/$1/" in
        */../*|*/./*) die "Use a normalized absolute path: $1" ;;
    esac
}

# Subshells keep helper variables out of the caller's scope.
check_path() (
    current=$1
    expected_type=${2:-directory}
    while :; do
        [ ! -L "$current" ] || die "Refusing symlink: $current"
        if [ -e "$current" ]; then
            if [ "$expected_type" = file ]; then
                [ -f "$current" ] || die "Unexpected file type: $current"
            else
                [ -d "$current" ] || die "Unexpected file type: $current"
            fi
        fi
        parent=$(dirname "$current")
        [ "$parent" != "$current" ] || break
        current=$parent
        expected_type=directory
    done
)

agent_home() (
    set -e
    if [ "$explicit_home" = true ] || [ -z "$1" ]; then
        directory=$home/$2
    else
        directory=$1
    fi
    check_absolute "$directory"
    printf '%s\n' "$directory"
)

add_target() {
    record=$1$tab$2
    case "$newline$targets" in
        *"$newline$record$newline"*) return ;;
    esac
    targets=$targets$record$newline
}

build_targets() (
    set -e
    targets=
    remaining=$selected
    while [ -n "$remaining" ]; do
        agent=${remaining%%,*}
        case "$remaining" in
            *,*) remaining=${remaining#*,} ;;
            *) remaining= ;;
        esac
        skill=$home/.agents/skills/python-development/SKILL.md
        case "$agent" in
            ghcp)
                agent_root=$(agent_home "${COPILOT_HOME:-}" .copilot)
                legacy=$agent_root/instructions/python_development.instructions.md
                check_path "$legacy" file
                [ ! -e "$legacy" ] || die "Move the legacy Python instruction out of discovery first: $legacy"
                instructions=$agent_root/copilot-instructions.md ;;
            claude)
                agent_root=$(agent_home "${CLAUDE_CONFIG_DIR:-}" .claude)
                instructions=$agent_root/CLAUDE.md
                skill=$agent_root/skills/python-development/SKILL.md ;;
            codex)
                agent_root=$(agent_home "${CODEX_HOME:-}" .codex)
                override=$agent_root/AGENTS.override.md
                check_path "$override" file
                [ ! -s "$override" ] || die "Codex global override would hide the constitution: $override"
                instructions=$agent_root/AGENTS.md ;;
            *) die "$usage" ;;
        esac
        add_target "$data/constitution.md" "$instructions"
        add_target "$data/python-development/SKILL.md" "$skill"
    done
    printf '%s' "$targets"
)

file_action() (
    set -e
    source=$1
    destination=$2
    [ -s "$source" ] || die "Missing or empty bundled source: $source"
    check_path "$destination" file

    if [ ! -e "$destination" ]; then
        printf 'CREATE\n'
    elif cmp -s "$source" "$destination"; then
        printf 'UNCHANGED\n'
    else
        status=$?
        [ "$status" -eq 1 ] || die "Cannot compare file: $destination"
        [ "$force" = true ] || die "Conflicting file: $destination. Review it, then use --force to back up and replace."
        printf 'REPLACE\n'
    fi
)

install_file() (
    source=$1
    destination=$2
    action=$(file_action "$source" "$destination")
    printf '%s %s\n' "$action" "$destination"
    if [ "$dry_run" = true ] || [ "$action" = UNCHANGED ]; then return; fi

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
    trap 'rm -f -- "$temporary"' 0
    trap 'exit 1' HUP INT TERM
    if [ "$action" = REPLACE ]; then cp -p -- "$destination" "$temporary"; fi
    cat -- "$source" > "$temporary"
    mv -f -- "$temporary" "$destination"
    cmp -s "$source" "$destination" || die "Installed content verification failed: $destination"
)

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
            if [ "$option" = --agents ]; then
                selected=$2
            else
                home=$2
                explicit_home=true
            fi
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
targets=$(build_targets)
backups=$home/.spencrr-agents/backups
check_path "$backups"

while IFS="$tab" read -r source destination; do
    file_action "$source" "$destination" > /dev/null
done <<EOF
$targets
EOF

while IFS="$tab" read -r source destination; do
    install_file "$source" "$destination"
done <<EOF
$targets
EOF

if [ "$dry_run" = true ]; then
    printf 'Dry run: no files changed.\n'
else
    printf 'Installed files verified. Start a new agent session to verify loading.\n'
fi
