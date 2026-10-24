#!/usr/bin/env pwsh
#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AbsolutePath([string] $Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value -match "[`r`n`t]" -or
        -not [System.IO.Path]::IsPathFullyQualified($Value)) {
        throw "Use an absolute path without tabs or newlines: $Value"
    }
    return [System.IO.Path]::GetFullPath($Value)
}

function Assert-SafePath([string] $Path, [bool] $FileAllowed = $false) {
    $current = $Path
    while ($current) {
        $attributes = $null
        try { $attributes = [System.IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] {}
        catch [System.IO.DirectoryNotFoundException] {}
        if ($null -ne $attributes) {
            if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing symlink or reparse point: $current"
            }
            $shouldBeFile = $current -eq $Path -and $FileAllowed
            $isDirectory = [bool]($attributes -band [System.IO.FileAttributes]::Directory)
            if ($shouldBeFile -eq $isDirectory) {
                throw "Unexpected file type: $current"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Test-SameBytes($Left, $Right) {
    if ($null -eq $Left) { return $null -eq $Right }
    if ($null -eq $Right) { return $false }
    return [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Read-OptionalBytes([string] $Path) {
    if ([System.IO.File]::Exists($Path)) {
        return ,([System.IO.File]::ReadAllBytes($Path))
    }
    return $null
}

try {
    $selected = ''
    $explicitHome = $null
    $dryRun = $false
    $force = $false
    $usage = 'Usage: ./install.ps1 --agents ghcp,claude,codex|all [--home ABSOLUTE_PATH] [--dry-run] [--force]'
    for ($index = 0; $index -lt $args.Count; $index++) {
        switch -CaseSensitive ($args[$index]) {
            { $_ -in '--help', '-h' } { Write-Output $usage; exit 0 }
            '--dry-run' { $dryRun = $true }
            '--force' { $force = $true }
            { $_ -in '--agents', '--home' } {
                $option = $_
                $index++
                if ($index -ge $args.Count -or $args[$index].StartsWith('--')) {
                    throw "Missing value for $option"
                }
                if ($option -ceq '--agents') { $selected = $args[$index] }
                else { $explicitHome = $args[$index] }
            }
            default { throw "Unknown argument: $($args[$index])" }
        }
    }
    $agents = @(if ($selected -ceq 'all') { 'ghcp', 'claude', 'codex' } else { $selected.Split(',') })
    if ($agents.Count -eq 0 -or @($agents | Where-Object { $_ -cnotin @('ghcp', 'claude', 'codex') }).Count) {
        throw $usage
    }
    $userHome = Get-AbsolutePath $(if ($null -ne $explicitHome) { $explicitHome } else { $HOME })
    Assert-SafePath $userHome
    function Get-AgentHome([string] $Variable, [string] $Fallback) {
        $value = [Environment]::GetEnvironmentVariable($Variable)
        if ($null -ne $explicitHome -or [string]::IsNullOrEmpty($value)) {
            return Join-Path $userHome $Fallback
        }
        return Get-AbsolutePath $value
    }
    $data = Join-Path $PSScriptRoot 'spencrr_agents/data'
    $constitution = Join-Path $data 'constitution.md'
    $skill = Join-Path $data 'python-development/SKILL.md'
    $sharedSkill = Join-Path $userHome '.agents/skills/python-development/SKILL.md'
    $targets = [ordered]@{}
    foreach ($agent in $agents) {
        switch -CaseSensitive ($agent) {
            'ghcp' {
                $root = Get-AgentHome 'COPILOT_HOME' '.copilot'
                $legacy = Join-Path $root 'instructions/python_development.instructions.md'
                Assert-SafePath $legacy $true
                if (Test-Path -LiteralPath $legacy) {
                    throw "Move the legacy Python instruction out of discovery first: $legacy"
                }
                $targets[(Join-Path $root 'copilot-instructions.md')] = $constitution
                $targets[$sharedSkill] = $skill
            }
            'claude' {
                $root = Get-AgentHome 'CLAUDE_CONFIG_DIR' '.claude'
                $targets[(Join-Path $root 'CLAUDE.md')] = $constitution
                $targets[(Join-Path $root 'skills/python-development/SKILL.md')] = $skill
            }
            'codex' {
                $root = Get-AgentHome 'CODEX_HOME' '.codex'
                $override = Join-Path $root 'AGENTS.override.md'
                Assert-SafePath $override $true
                if ([System.IO.File]::Exists($override) -and (Get-Item -LiteralPath $override).Length) {
                    throw "Codex global override would hide the constitution: $override"
                }
                $targets[(Join-Path $root 'AGENTS.md')] = $constitution
                $targets[$sharedSkill] = $skill
            }
        }
    }
    $backups = Join-Path $userHome '.spencrr-agents/backups'
    Assert-SafePath $backups
    $plan = foreach ($destination in $targets.Keys) {
        Assert-SafePath $destination $true
        $desired = [System.IO.File]::ReadAllBytes($targets[$destination])
        if (-not $desired.Length) { throw "Empty bundled source: $($targets[$destination])" }
        $previous = Read-OptionalBytes $destination
        $action = if ($null -eq $previous) { 'CREATE' }
                  elseif (Test-SameBytes $previous $desired) { 'UNCHANGED' }
                  else { 'REPLACE' }
        if ($action -eq 'REPLACE' -and -not $force) {
            throw "Conflicting file: $destination. Review it, then use --force to back up and replace."
        }
        [pscustomobject]@{ Destination = $destination; Desired = $desired; Previous = $previous; Action = $action }
    }
    foreach ($entry in $plan) {
        $destination = $entry.Destination
        Write-Output "$($entry.Action) $destination"
        if ($dryRun -or $entry.Action -eq 'UNCHANGED') { continue }
        Assert-SafePath $destination $true
        if (-not (Test-SameBytes (Read-OptionalBytes $destination) $entry.Previous)) {
            throw "File changed during installation: $destination"
        }
        if ($null -ne $entry.Previous) {
            Assert-SafePath $backups
            [System.IO.Directory]::CreateDirectory($backups) | Out-Null
            $backup = Join-Path $backups "$([System.IO.Path]::GetFileName($destination)).$([guid]::NewGuid()).bak"
            $stream = [System.IO.File]::Open($backup, [System.IO.FileMode]::CreateNew)
            try { $stream.Write($entry.Previous, 0, $entry.Previous.Length) } finally { $stream.Dispose() }
            if (-not (Test-SameBytes ([System.IO.File]::ReadAllBytes($backup)) $entry.Previous)) {
                throw "Backup verification failed: $backup"
            }
            Write-Output "BACKUP $destination -> $backup"
        }
        $parent = [System.IO.Path]::GetDirectoryName($destination)
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        $temporary = Join-Path $parent ".spencrr-agents-$([guid]::NewGuid())"
        try {
            [System.IO.File]::WriteAllBytes($temporary, $entry.Desired)
            if (-not $IsWindows -and $null -ne $entry.Previous) {
                [System.IO.File]::SetUnixFileMode($temporary, [System.IO.File]::GetUnixFileMode($destination))
            }
            [System.IO.File]::Move($temporary, $destination, $true)
        } finally {
            if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        }
        if (-not (Test-SameBytes ([System.IO.File]::ReadAllBytes($destination)) $entry.Desired)) {
            throw "Installed content verification failed: $destination"
        }
    }
    if ($dryRun) { Write-Output 'Dry run: no files changed.' }
    else { Write-Output 'Installed files verified. Start a new agent session to verify loading.' }
    exit 0
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)`nInstallation stopped; inspect any reported changes and backups.")
    exit 1
}
