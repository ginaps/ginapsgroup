[CmdletBinding()]
param(
  [string]$SourceSlug,
  [switch]$SkipImport,
  [switch]$SkipSync,
  [switch]$FailOnUnresolvedAuthors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$syncScript = Join-Path $scriptDir 'sync-publications.ps1'

if (-not (Test-Path $syncScript)) {
  throw "sync-publications.ps1 not found in $scriptDir"
}

if (-not $SkipImport) {
  $importArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-ImportOrcidSources', '-WriteChanges')
  if ($SourceSlug) {
    $importArgs += @('-SourceSlug', $SourceSlug)
  }

  Write-Host 'Step 1/3: importing new publications from ORCID sources'
  & powershell @importArgs
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

if (-not $SkipSync) {
  Write-Host 'Step 2/3: syncing authors across all publications'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $syncScript -WriteChanges
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

$validateArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syncScript, '-ValidateOnly')
if (-not $FailOnUnresolvedAuthors) {
  $validateArgs += '-IgnoreUnresolvedAuthors'
}

Write-Host 'Step 3/3: validating duplicates and publication consistency'
& powershell @validateArgs
exit $LASTEXITCODE
