#!/usr/bin/env pwsh
#Requires -Version 7.4
using namespace System.IO

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$agentSettings = [ordered]@{
    ghcp = @{ Environment = 'COPILOT_HOME'; Directory = '.copilot'; File = 'copilot-instructions.md' }
    claude = @{ Environment = 'CLAUDE_CONFIG_DIR'; Directory = '.claude'; File = 'CLAUDE.md' }
    codex = @{ Environment = 'CODEX_HOME'; Directory = '.codex'; File = 'AGENTS.md' }
}
$usage = 'Usage: ./install.ps1 --agents ghcp,claude,codex|all [--home ABSOLUTE_PATH] [--dry-run] [--force]'

function Get-AbsolutePath([string] $Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value -match "[`r`n`t]" -or
        -not [Path]::IsPathFullyQualified($Value)) {
        throw "Use an absolute path without tabs or newlines: $Value"
    }
    return [Path]::GetFullPath($Value)
}

function Assert-SafePath([string] $Path, [switch] $FileAllowed) {
    $current = $Path
    while ($current) {
        $attributes = $null
        try { $attributes = [File]::GetAttributes($current) }
        catch [FileNotFoundException] {}
        catch [DirectoryNotFoundException] {}
        if ($null -ne $attributes) {
            if ($attributes -band [FileAttributes]::ReparsePoint) {
                throw "Refusing symlink or reparse point: $current"
            }
            $expectFile = $current -eq $Path -and $FileAllowed
            $isDirectory = [bool]($attributes -band [FileAttributes]::Directory)
            if ($expectFile -eq $isDirectory) {
                throw "Unexpected file type: $current"
            }
        }
        $parent = [Path]::GetDirectoryName($current)
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
    if ([File]::Exists($Path)) {
        return ,([File]::ReadAllBytes($Path))
    }
    return $null
}

function Get-Options([string[]] $Arguments) {
    $options = @{ Agents = ''; Home = $null; DryRun = $false; Force = $false }
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        switch -CaseSensitive ($Arguments[$index]) {
            { $_ -cin '--help', '-h' } { [Console]::WriteLine($usage); exit 0 }
            '--dry-run' { $options.DryRun = $true }
            '--force' { $options.Force = $true }
            { $_ -cin '--agents', '--home' } {
                $option = $_
                $index++
                if ($index -ge $Arguments.Count -or $Arguments[$index].StartsWith('--')) {
                    throw "Missing value for $option"
                }
                if ($option -ceq '--agents') { $options.Agents = $Arguments[$index] }
                else { $options.Home = $Arguments[$index] }
            }
            default { throw "Unknown argument: $($Arguments[$index])" }
        }
    }
    $selected = @(if ($options.Agents -ceq 'all') { $agentSettings.Keys } else { $options.Agents.Split(',') })
    foreach ($agent in $selected) {
        if ($agent -cnotin $agentSettings.Keys) { throw $usage }
    }
    $options.Agents = $selected
    return [pscustomobject]$options
}

function Get-InstallTargets([string[]] $Agents, [string] $UserHome, [bool] $Isolated) {
    $data = Join-Path $PSScriptRoot 'spencrr_agents/data'
    $sharedSkill = Join-Path $UserHome '.agents/skills/python-development/SKILL.md'
    $targets = [ordered]@{}
    foreach ($agent in $Agents) {
        $settings = $agentSettings[$agent]
        $configuredHome = [Environment]::GetEnvironmentVariable($settings.Environment)
        $root = if ($Isolated -or [string]::IsNullOrEmpty($configuredHome)) {
            Join-Path $UserHome $settings.Directory
        } else {
            Get-AbsolutePath $configuredHome
        }

        if ($agent -ceq 'ghcp') {
            $legacy = Join-Path $root 'instructions/python_development.instructions.md'
            Assert-SafePath $legacy -FileAllowed
            if (Test-Path -LiteralPath $legacy) {
                throw "Move the legacy Python instruction out of discovery first: $legacy"
            }
        } elseif ($agent -ceq 'codex') {
            $override = Join-Path $root 'AGENTS.override.md'
            Assert-SafePath $override -FileAllowed
            if ([File]::Exists($override) -and (Get-Item -LiteralPath $override).Length) {
                throw "Codex global override would hide the constitution: $override"
            }
        }
        $skill = if ($agent -ceq 'claude') {
            Join-Path $root 'skills/python-development/SKILL.md'
        } else {
            $sharedSkill
        }
        $targets[(Join-Path $root $settings.File)] = Join-Path $data 'constitution.md'
        $targets[$skill] = Join-Path $data 'python-development/SKILL.md'
    }
    return $targets
}

function Get-InstallPlan($Targets, [bool] $Force) {
    foreach ($destination in $Targets.Keys) {
        Assert-SafePath $destination -FileAllowed
        $desired = [File]::ReadAllBytes($Targets[$destination])
        if (-not $desired.Length) { throw "Empty bundled source: $($Targets[$destination])" }
        $previous = Read-OptionalBytes $destination
        $action = if ($null -eq $previous) { 'CREATE' }
                  elseif (Test-SameBytes $previous $desired) { 'UNCHANGED' }
                  else { 'REPLACE' }
        if ($action -eq 'REPLACE' -and -not $Force) {
            throw "Conflicting file: $destination. Review it, then use --force to back up and replace."
        }
        [pscustomobject]@{
            Destination = $destination
            Desired = $desired
            Previous = $previous
            Action = $action
        }
    }
}

function Write-InstallChange($Change, [string] $Backups) {
    $destination = $Change.Destination
    Assert-SafePath $destination -FileAllowed
    if (-not (Test-SameBytes (Read-OptionalBytes $destination) $Change.Previous)) {
        throw "File changed during installation: $destination"
    }

    if ($null -ne $Change.Previous) {
        Assert-SafePath $Backups
        [Directory]::CreateDirectory($Backups) | Out-Null
        $backup = Join-Path $Backups "$([Path]::GetFileName($destination)).$([guid]::NewGuid()).bak"
        $stream = [File]::Open($backup, [FileMode]::CreateNew)
        try { $stream.Write($Change.Previous, 0, $Change.Previous.Length) }
        finally { $stream.Dispose() }
        if (-not (Test-SameBytes ([File]::ReadAllBytes($backup)) $Change.Previous)) {
            throw "Backup verification failed: $backup"
        }
        Write-Output "BACKUP $destination -> $backup"
    }

    $parent = [Path]::GetDirectoryName($destination)
    [Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ".spencrr-agents-$([guid]::NewGuid())"
    try {
        [File]::WriteAllBytes($temporary, $Change.Desired)
        if (-not $IsWindows -and $null -ne $Change.Previous) {
            [File]::SetUnixFileMode($temporary, [File]::GetUnixFileMode($destination))
        }
        [File]::Move($temporary, $destination, $true)
    } finally {
        if ([File]::Exists($temporary)) { [File]::Delete($temporary) }
    }
    if (-not (Test-SameBytes ([File]::ReadAllBytes($destination)) $Change.Desired)) {
        throw "Installed content verification failed: $destination"
    }
}

try {
    $options = Get-Options $args
    $userHome = Get-AbsolutePath $(if ($null -ne $options.Home) { $options.Home } else { $HOME })
    Assert-SafePath $userHome
    $targets = Get-InstallTargets $options.Agents $userHome ($null -ne $options.Home)
    $backups = Join-Path $userHome '.spencrr-agents/backups'
    Assert-SafePath $backups
    $plan = @(Get-InstallPlan $targets $options.Force)

    foreach ($change in $plan) {
        Write-Output "$($change.Action) $($change.Destination)"
        if ($options.DryRun -or $change.Action -eq 'UNCHANGED') { continue }
        Write-InstallChange $change $backups
    }
    if ($options.DryRun) { Write-Output 'Dry run: no files changed.' }
    else { Write-Output 'Installed files verified. Start a new agent session to verify loading.' }
    exit 0
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)`nInstallation stopped; inspect any reported changes and backups.")
    exit 1
}
