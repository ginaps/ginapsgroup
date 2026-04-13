[CmdletBinding()]
param(
    [string]$ContentRoot = 'content/publication',
    [switch]$RemoveDuplicates,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $encoding)
}

function Get-PublicationMetadata {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $indexPath = Join-Path $Directory 'index.md'
    if (-not (Test-Path $indexPath)) {
        return $null
    }

    $title = ''
    $doi = ''
    foreach ($line in (Read-Utf8File $indexPath) -split "`r?`n") {
        if ($line -match '^title:\s*(.+)$') {
            $title = $Matches[1].Trim("'")
        } elseif ($line -match '^doi:\s*(.+)$') {
            $doi = $Matches[1].Trim("'")
        }
    }

    return [PSCustomObject]@{
        Directory = $Directory
        Title = $title
        Doi = $doi
    }
}

if (-not (Test-Path $ContentRoot)) {
    throw "Content root '$ContentRoot' does not exist."
}

$records = Get-ChildItem -Path $ContentRoot -Directory | ForEach-Object {
    Get-PublicationMetadata -Directory $_.FullName
} | Where-Object { $_ -ne $null }

$doiGroups = $records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Doi) } | Group-Object Doi | Where-Object Count -gt 1
$titleGroups = $records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Title) } | Group-Object Title | Where-Object Count -gt 1

if ($doiGroups.Count -eq 0 -and $titleGroups.Count -eq 0) {
    Write-Host 'No duplicate publications found.'
    exit 0
}

if ($doiGroups.Count -gt 0) {
    Write-Host 'Duplicate publications by DOI:'
    foreach ($group in $doiGroups) {
        Write-Host "- $($group.Name) ($($group.Count) entries)"
        foreach ($item in $group.Group) {
            Write-Host "    $($item.Directory)"
        }
    }
}

if ($titleGroups.Count -gt 0) {
    Write-Host 'Duplicate publications by title:'
    foreach ($group in $titleGroups) {
        Write-Host "- $($group.Name) ($($group.Count) entries)"
        foreach ($item in $group.Group) {
            Write-Host "    $($item.Directory)"
        }
    }
}

$duplicatesFound = ($doiGroups.Count -gt 0 -or $titleGroups.Count -gt 0)

if ($RemoveDuplicates) {
    Write-Host ''
    Write-Host 'Removing duplicate publication directories by DOI...'
    foreach ($group in $doiGroups) {
        $ordered = $group.Group | Sort-Object Directory
        $keep = $ordered[0].Directory
        $remove = $ordered | Select-Object -Skip 1
        Write-Host "Keeping: $keep"
        foreach ($item in $remove) {
            Write-Host "Removing: $($item.Directory)"
            $removeParams = @{ LiteralPath = $item.Directory; Recurse = $true; Force = $true }
            if ($WhatIf) { $removeParams.WhatIf = $true }
            Remove-Item @removeParams
        }
    }
    if (-not $WhatIf) {
        $duplicatesFound = $false
    }
}

if ($duplicatesFound) {
    Write-Error 'Duplicate publications were found.'
    exit 1
}
