[CmdletBinding(DefaultParameterSetName = 'Sync')]
param(
  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [string]$ContentRoot = 'content/publication',

  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [string]$AuthorRoot = 'content/authors',

  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [Parameter(ParameterSetName = 'Import')]
  [string]$AliasFile = 'data/author_aliases.yaml',

  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [Parameter(ParameterSetName = 'Import')]
  [string]$PublicationDir,

  [Parameter(ParameterSetName = 'Import', Mandatory = $true)]
  [string]$TargetDir,

  [Parameter(ParameterSetName = 'Import')]
  [string]$BibFile,

  [Parameter(ParameterSetName = 'Import')]
  [string]$Doi,

  [Parameter(ParameterSetName = 'Sync')]
  [switch]$WriteChanges,

  [Parameter(ParameterSetName = 'Validate')]
  [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Utf8File {
  param([Parameter(Mandatory = $true)][string]$Path)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $encoding)
}

function Write-Utf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Fix-Mojibake {
  param([AllowNull()][string]$Text)
  return $Text
}

function Normalize-Whitespace {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) {
    return $null
  }

  $value = Fix-Mojibake $Text
  $value = $value.Replace([char]0x2019, "'")
  $value = $value.Replace([char]0x2018, "'")
  $value = $value.Replace([char]0x2010, '-')
  $value = $value.Replace([char]0x2011, '-')
  $value = $value.Replace([char]0x2012, '-')
  $value = $value.Replace([char]0x2013, '-')
  $value = $value.Replace([char]0x2014, '-')
  $value = $value.Replace([char]0x2015, '-')
  $value = $value.Replace([char]0x2032, "'")
  $value = $value.Replace([char]0x00A0, ' ')
  $value = $value -replace '\s+', ' '
  return $value.Trim()
}

function Remove-Diacritics {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ''
  }

  $normalized = (Normalize-Whitespace $Text).Normalize([Text.NormalizationForm]::FormD)
  $builder = New-Object System.Text.StringBuilder
  foreach ($char in $normalized.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$builder.Append($char)
    }
  }
  return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-ComparableName {
  param([AllowNull()][string]$Text)
  $value = Remove-Diacritics $Text
  $value = $value.ToLowerInvariant()
  $value = $value -replace "[^a-z0-9' -]", ' '
  $value = $value -replace '\s+', ' '
  return $value.Trim()
}

function Get-InitialsToken {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ''
  }
  return ((Remove-Diacritics $Text).ToLowerInvariant() -replace '[^a-z]', '')
}

function Parse-AuthorName {
  param([AllowNull()][string]$Name)

  $value = Normalize-Whitespace $Name
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }

  $family = ''
  $given = ''
  if ($value.Contains(',')) {
    $parts = $value.Split(',', 2)
    $family = Normalize-Whitespace $parts[0]
    $given = Normalize-Whitespace $parts[1]
  } else {
    $tokens = $value.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($tokens.Count -eq 1) {
      $family = $tokens[0]
      $given = ''
    } else {
      $family = $tokens[-1]
      $given = (($tokens | Select-Object -SkipLast 1) -join ' ')
    }
  }

  $display = if ($given) { "$given $family" } else { $family }
  return [PSCustomObject]@{
    Original = $value
    Display  = Normalize-Whitespace $display
    Family   = Normalize-Whitespace $family
    Given    = Normalize-Whitespace $given
  }
}

function Get-NameSignatures {
  param([AllowNull()][string]$Name)

  $parsed = Parse-AuthorName $Name
  if ($null -eq $parsed) {
    return @()
  }

  $signatures = New-Object 'System.Collections.Generic.HashSet[string]'
  $displayComparable = Get-ComparableName $parsed.Display
  if ($displayComparable) {
    [void]$signatures.Add(('display::{0}' -f $displayComparable))
  }

  $familyComparable = Get-ComparableName $parsed.Family
  $givenComparable = Get-ComparableName $parsed.Given
  if ($familyComparable) {
    [void]$signatures.Add(('family::{0}' -f $familyComparable))
  }
  if ($familyComparable -and $givenComparable) {
    [void]$signatures.Add(('full::{0}|{1}' -f $familyComparable, $givenComparable))
  }

  $initials = Get-InitialsToken $parsed.Given
  if ($familyComparable -and $initials) {
    [void]$signatures.Add(('initials::{0}|{1}' -f $familyComparable, $initials))
  }

  return @($signatures | Sort-Object)
}

function Get-AuthorSlugFromProfile {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)
  $content = Read-Utf8File $ProfilePath
  if ($content -match '(?ms)^---\s*(.*?)\s*---') {
    foreach ($line in ($Matches[1] -split "`r?`n")) {
      if ($line -match '^\s*-\s*([A-Za-z0-9_-]+)\s*$') {
        return $Matches[1]
      }
      if ($line -match '^authors:\s*\[\s*"?([A-Za-z0-9_-]+)"?\s*\]\s*$') {
        return $Matches[1]
      }
    }
  }
  return [System.IO.Path]::GetFileName((Split-Path -Parent $ProfilePath))
}

function Get-AuthorTitleFromProfile {
  param([Parameter(Mandatory = $true)][string]$ProfilePath)
  $content = Read-Utf8File $ProfilePath
  if ($content -match '(?ms)^---\s*(.*?)\s*---') {
    foreach ($line in ($Matches[1] -split "`r?`n")) {
      if ($line -match '^title:\s*(.+)$') {
        return Normalize-Whitespace $Matches[1]
      }
    }
  }
  return $null
}

function Parse-AliasFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $entries = @()
  $current = $null
  $inAliases = $false

  foreach ($line in (Read-Utf8File $Path) -split "`r?`n") {
    if ($line -match '^\s*-\s+slug:\s*(.+?)\s*$') {
      if ($current) {
        $entries += [PSCustomObject]$current
      }
      $current = @{
        slug = $Matches[1].Trim()
        display_name = ''
        aliases = New-Object System.Collections.Generic.List[string]
      }
      $inAliases = $false
      continue
    }

    if (-not $current) {
      continue
    }

    if ($line -match '^\s*display_name:\s*(.+?)\s*$') {
      $current.display_name = Normalize-Whitespace $Matches[1]
      continue
    }

    if ($line -match '^\s*aliases:\s*$') {
      $inAliases = $true
      continue
    }

    if ($inAliases -and $line -match '^\s*-\s+(.+?)\s*$') {
      $current.aliases.Add((Normalize-Whitespace $Matches[1]))
      continue
    }
  }

  if ($current) {
    $entries += [PSCustomObject]$current
  }

  return $entries
}

function Get-AuthorRegistry {
  param(
    [Parameter(Mandatory = $true)][string]$AliasPath,
    [Parameter(Mandatory = $true)][string]$AuthorRootPath
  )

  $profileMap = @{}
  Get-ChildItem -Path $AuthorRootPath -Directory | ForEach-Object {
    $profilePath = Join-Path $_.FullName '_index.md'
    if (Test-Path $profilePath) {
      $slug = Get-AuthorSlugFromProfile $profilePath
      $title = Get-AuthorTitleFromProfile $profilePath
      $profileMap[$slug] = [PSCustomObject]@{
        slug = $slug
        title = $title
        path = $profilePath
      }
    }
  }

  $aliasEntries = Parse-AliasFile $AliasPath
  $signatures = @{}
  $missingSlugs = New-Object System.Collections.Generic.List[string]

  foreach ($entry in $aliasEntries) {
    if (-not $profileMap.ContainsKey($entry.slug)) {
      $missingSlugs.Add($entry.slug)
      continue
    }

    $allNames = New-Object System.Collections.Generic.List[string]
    if ($profileMap[$entry.slug].title) {
      $allNames.Add($profileMap[$entry.slug].title)
    }
    if ($entry.display_name) {
      $allNames.Add($entry.display_name)
    }
    foreach ($alias in $entry.aliases) {
      $allNames.Add($alias)
    }

    foreach ($name in $allNames) {
      foreach ($signature in Get-NameSignatures $name) {
        $signatures[$signature] = $entry.slug
      }
    }
  }

  return [PSCustomObject]@{
    Profiles = $profileMap
    Signatures = $signatures
    MissingSlugs = @($missingSlugs)
    AliasEntries = $aliasEntries
  }
}

function Split-BibAuthors {
  param([AllowNull()][string]$AuthorsValue)

  $value = Normalize-Whitespace $AuthorsValue
  if ([string]::IsNullOrWhiteSpace($value)) {
    return @()
  }

  $parts = @()
  $builder = New-Object System.Text.StringBuilder
  $depth = 0
  for ($i = 0; $i -lt $value.Length; $i++) {
    $char = $value[$i]
    if ($char -eq '{') { $depth++ }
    if ($char -eq '}') { $depth-- }

    if ($depth -eq 0 -and $i -le ($value.Length - 5) -and $value.Substring($i, 5) -eq ' and ') {
      $parts += $builder.ToString()
      $builder.Clear() | Out-Null
      $i += 4
      continue
    }

    [void]$builder.Append($char)
  }

  $parts += $builder.ToString()
  return @($parts | ForEach-Object { Normalize-Whitespace ($_ -replace '[{}]', '') } | Where-Object { $_ })
}

function Parse-BibTexRecord {
  param([Parameter(Mandatory = $true)][string]$Text)

  $lines = $Text -split "`r?`n"
  $fields = @{}
  $currentField = $null
  $valueBuilder = New-Object System.Text.StringBuilder
  $braceDepth = 0
  $quoteCount = 0

  function Commit-Field {
    param([string]$FieldName, [System.Text.StringBuilder]$Builder, [hashtable]$Target)
    if (-not $FieldName) {
      return
    }
    $rawValue = $Builder.ToString().Trim().TrimEnd(',')
    if ($rawValue.StartsWith('{') -and $rawValue.EndsWith('}')) {
      $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
    } elseif ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"')) {
      $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
    }
    $Target[$FieldName.ToLowerInvariant()] = Normalize-Whitespace ($rawValue -replace '\s+', ' ')
  }

  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('@') -or $trimmed -eq '}') {
      continue
    }

    if (-not $currentField) {
      if ($trimmed -match '^([A-Za-z_]+)\s*=\s*(.+)$') {
        $currentField = $Matches[1]
        [void]$valueBuilder.Append($Matches[2])
      }
    } else {
      [void]$valueBuilder.Append(' ')
      [void]$valueBuilder.Append($trimmed)
    }

    $textValue = $valueBuilder.ToString()
    $braceDepth = ([regex]::Matches($textValue, '\{')).Count - ([regex]::Matches($textValue, '\}')).Count
    $quoteCount = ([regex]::Matches($textValue, '"')).Count
    $quoteClosed = ($quoteCount % 2 -eq 0)
    $ready = ($braceDepth -le 0 -and $quoteClosed -and $textValue.TrimEnd().EndsWith(','))

    if ($ready) {
      Commit-Field -FieldName $currentField -Builder $valueBuilder -Target $fields
      $currentField = $null
      $valueBuilder.Clear() | Out-Null
      $braceDepth = 0
      $quoteCount = 0
    }
  }

  if ($currentField) {
    Commit-Field -FieldName $currentField -Builder $valueBuilder -Target $fields
  }

  return $fields
}

function Get-BibMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)
  $record = Parse-BibTexRecord (Read-Utf8File $Path)
  $authors = @()
  foreach ($author in Split-BibAuthors $record['author']) {
    $parsed = Parse-AuthorName $author
    if ($parsed) {
      $authors += $parsed.Display
    }
  }

  return [PSCustomObject]@{
    Title = Normalize-Whitespace $record['title']
    Abstract = Normalize-Whitespace $record['abstract']
    Publication = Normalize-Whitespace $record['journal']
    Year = Normalize-Whitespace $record['year']
    Doi = Normalize-Whitespace $record['doi']
    Url = Normalize-Whitespace $record['url']
    Authors = $authors
    Source = 'bibtex'
  }
}

function Get-DoiMetadata {
  param([Parameter(Mandatory = $true)][string]$DoiValue)
  $encodedDoi = [System.Uri]::EscapeDataString($DoiValue)
  $response = Invoke-RestMethod -Uri "https://api.crossref.org/works/$encodedDoi"
  $message = $response.message

  $authors = @()
  foreach ($author in @($message.author)) {
    $family = Normalize-Whitespace $author.family
    $given = Normalize-Whitespace $author.given
    if ($family -and $given) {
      $authors += (Normalize-Whitespace "$given $family")
    } elseif ($family) {
      $authors += $family
    } elseif ($given) {
      $authors += $given
    }
  }

  $title = ''
  if ($message.title.Count -gt 0) {
    $title = Normalize-Whitespace $message.title[0]
  }

  $container = ''
  if ($message.'container-title'.Count -gt 0) {
    $container = Normalize-Whitespace $message.'container-title'[0]
  }

  $abstract = ''
  if ($message.abstract) {
    $abstract = Normalize-Whitespace ($message.abstract -replace '<[^>]+>', ' ')
  }

  $year = ''
  if ($message.issued.'date-parts'.Count -gt 0) {
    $year = [string]$message.issued.'date-parts'[0][0]
  }

  return [PSCustomObject]@{
    Title = $title
    Abstract = $abstract
    Publication = $container
    Year = $year
    Doi = Normalize-Whitespace $message.DOI
    Url = Normalize-Whitespace $message.URL
    Authors = $authors
    Source = 'doi'
  }
}

function Get-FrontMatterAuthors {
  param([Parameter(Mandatory = $true)][string]$FilePath)
  $content = Read-Utf8File $FilePath
  if (-not ($content -match '(?ms)^---\s*(.*?)\s*---')) {
    return @()
  }

  $frontMatter = $Matches[1]
  $authors = New-Object System.Collections.Generic.List[string]
  $inAuthors = $false
  foreach ($line in $frontMatter -split "`r?`n") {
    if ($line -match '^authors:\s*$') {
      $inAuthors = $true
      continue
    }
    if ($inAuthors) {
      if ($line -match '^\s*-\s+(.+?)\s*$') {
        $authors.Add((Normalize-Whitespace $Matches[1]))
      } elseif ($line -match '^\S') {
        break
      }
    }
  }
  return @($authors)
}

function Resolve-Authors {
  param(
    [Parameter(Mandatory = $true)][string[]]$SourceAuthors,
    [Parameter(Mandatory = $true)][hashtable]$SignatureMap
  )

  $resolved = New-Object System.Collections.Generic.List[string]
  $unresolved = New-Object System.Collections.Generic.List[string]

  foreach ($author in $SourceAuthors) {
    $normalizedAuthor = Normalize-Whitespace $author
    $matchedSlug = $null
    foreach ($signature in Get-NameSignatures $normalizedAuthor) {
      if ($SignatureMap.ContainsKey($signature)) {
        $matchedSlug = $SignatureMap[$signature]
        break
      }
    }

    if ($matchedSlug) {
      $resolved.Add($matchedSlug)
    } else {
      $resolved.Add($normalizedAuthor)
      $unresolved.Add($normalizedAuthor)
    }
  }

  return [PSCustomObject]@{
    Authors = @($resolved)
    Unresolved = @($unresolved | Sort-Object -Unique)
  }
}

function Set-FrontMatterAuthors {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Authors
  )

  $content = Read-Utf8File $FilePath
  if (-not ($content -match '(?ms)^---\s*(.*?)\s*---(.*)$')) {
    throw "No YAML front matter found in $FilePath"
  }

  $frontMatter = $Matches[1]
  $body = $Matches[2]
  $lines = New-Object System.Collections.Generic.List[string]
  $frontLines = $frontMatter -split "`r?`n"
  $i = 0
  $inserted = $false

  while ($i -lt $frontLines.Count) {
    $line = $frontLines[$i]
    if ($line -match '^authors:\s*$') {
      $lines.Add('authors:')
      foreach ($author in $Authors) {
        $lines.Add("- $author")
      }
      $inserted = $true
      $i++
      while ($i -lt $frontLines.Count) {
        if ($frontLines[$i] -match '^\s*-\s+') {
          $i++
          continue
        }
        break
      }
      continue
    }

    $lines.Add($line)
    $i++
  }

  if (-not $inserted) {
    $newLines = New-Object System.Collections.Generic.List[string]
    $authorsBlockAdded = $false
    foreach ($line in $lines) {
      $newLines.Add($line)
      if (-not $authorsBlockAdded -and $line -match '^date:') {
        $newLines.Add('')
        $newLines.Add('authors:')
        foreach ($author in $Authors) {
          $newLines.Add("- $author")
        }
        $authorsBlockAdded = $true
      }
    }
    $lines = $newLines
  }

  $newFrontMatter = ($lines -join "`n").Trim("`r", "`n")
  $rebuilt = "---`n$newFrontMatter`n---$body"
  return $rebuilt
}

function Get-PublicationMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$DirectoryPath,
    [string]$BibPathOverride,
    [string]$DoiOverride
  )

  $bibPath = if ($BibPathOverride) { $BibPathOverride } else { Join-Path $DirectoryPath 'cite.bib' }
  $indexPath = Join-Path $DirectoryPath 'index.md'

  if ($BibPathOverride -or (Test-Path $bibPath)) {
    return Get-BibMetadata $bibPath
  }

  if ($DoiOverride) {
    return Get-DoiMetadata $DoiOverride
  }

  if (Test-Path $indexPath) {
    $fallbackAuthors = Get-FrontMatterAuthors $indexPath
    return [PSCustomObject]@{
      Title = ''
      Abstract = ''
      Publication = ''
      Year = ''
      Doi = ''
      Url = ''
      Authors = $fallbackAuthors
      Source = 'frontmatter'
    }
  }

  throw "No metadata found for $DirectoryPath"
}

function Build-PublicationFrontMatter {
  param(
    [Parameter(Mandatory = $true)]$Metadata,
    [Parameter(Mandatory = $true)][string[]]$Authors
  )

  $dateValue = if ($Metadata.Year) { "{0}-01-01" -f $Metadata.Year } else { (Get-Date).ToString('yyyy-01-01') }
  $lines = @(
    '---'
    "title: $($Metadata.Title)"
    "date: '$dateValue'"
    ''
    'authors:'
  )
  foreach ($author in $Authors) {
    $lines += "- $author"
  }
  $lines += ''
  $lines += "abstract: $($Metadata.Abstract)"
  $lines += 'featured: false'
  $lines += "publication: '*$($Metadata.Publication)*'"
  if ($Metadata.Url) {
    $lines += "url_source: $($Metadata.Url)"
  }
  if ($Metadata.Doi) {
    $lines += "doi: $($Metadata.Doi)"
  }
  $lines += "publication_types: ['2']"
  $lines += '---'
  $lines += ''
  return ($lines -join "`n")
}

function Invoke-PublicationSync {
  param(
    [Parameter(Mandatory = $true)][string]$PublicationPath,
    [Parameter(Mandatory = $true)]$Registry,
    [switch]$Persist,
    [string]$BibPath,
    [string]$DoiValue
  )

  $indexPath = Join-Path $PublicationPath 'index.md'
  if (-not (Test-Path $indexPath) -and -not $Persist) {
    throw "index.md not found in $PublicationPath"
  }

  $metadata = Get-PublicationMetadata -DirectoryPath $PublicationPath -BibPathOverride $BibPath -DoiOverride $DoiValue
  $resolved = Resolve-Authors -SourceAuthors $metadata.Authors -SignatureMap $Registry.Signatures

  $changed = $false
  if (Test-Path $indexPath) {
    $currentContent = Read-Utf8File $indexPath
    $newContent = Set-FrontMatterAuthors -FilePath $indexPath -Authors $resolved.Authors
    if ($newContent -ne $currentContent) {
      $changed = $true
      if ($Persist) {
        Write-Utf8File -Path $indexPath -Content $newContent
      }
    }
  } elseif ($Persist) {
    New-Item -ItemType Directory -Path $PublicationPath -Force | Out-Null
    $newContent = Build-PublicationFrontMatter -Metadata $metadata -Authors $resolved.Authors
    Write-Utf8File -Path $indexPath -Content $newContent
    $changed = $true
  }

  return [PSCustomObject]@{
    Path = $PublicationPath
    Title = $metadata.Title
    Authors = $resolved.Authors
    Unresolved = $resolved.Unresolved
    Changed = $changed
    Source = $metadata.Source
  }
}

function Get-PublicationDirectories {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$SpecificPath
  )

  if ($SpecificPath) {
    return @((Resolve-Path -LiteralPath $SpecificPath).Path)
  }

  return @(Get-ChildItem -Path $Root -Directory | ForEach-Object { $_.FullName } | Sort-Object)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir '..')
Push-Location $repoRoot

try {
  $mode = switch ($PSCmdlet.ParameterSetName) {
    'Validate' { 'validate' }
    'Import' { 'import' }
    default { 'sync' }
  }

  $registry = Get-AuthorRegistry -AliasPath $AliasFile -AuthorRootPath $AuthorRoot

  if ($registry.MissingSlugs.Count -gt 0) {
    foreach ($slug in $registry.MissingSlugs) {
      Write-Error "Alias file references missing slug '$slug'."
    }
    exit 1
  }

  if ($mode -eq 'import') {
    $result = Invoke-PublicationSync -PublicationPath $TargetDir -Registry $registry -Persist -BibPath $BibFile -DoiValue $Doi
    Write-Host ("IMPORT {0} [{1}]" -f $result.Path, $result.Source)
    foreach ($author in $result.Authors) {
      Write-Host ("  - {0}" -f $author)
    }
    if ($result.Unresolved.Count -gt 0) {
      Write-Warning ("Unresolved authors: {0}" -f ($result.Unresolved -join '; '))
    }
    exit 0
  }

  $persistChanges = ($mode -eq 'sync' -and $WriteChanges)
  $results = New-Object System.Collections.Generic.List[object]
  foreach ($dir in Get-PublicationDirectories -Root $ContentRoot -SpecificPath $PublicationDir) {
    $results.Add((Invoke-PublicationSync -PublicationPath $dir -Registry $registry -Persist:$persistChanges))
  }

  $changedCount = @($results | Where-Object { $_.Changed }).Count
  $unresolvedByPublication = $results | Where-Object { $_.Unresolved.Count -gt 0 }
  $newAliasCandidates = $unresolvedByPublication | ForEach-Object { $_.Unresolved } | Sort-Object -Unique

  Write-Host ("Mode: {0}" -f $mode)
  Write-Host ("Publications scanned: {0}" -f $results.Count)
  Write-Host ("Publications changed: {0}" -f $changedCount)
  Write-Host ("Publications with unresolved authors: {0}" -f @($unresolvedByPublication).Count)

  foreach ($item in $unresolvedByPublication) {
    $relativePath = Resolve-Path -LiteralPath $item.Path -Relative
    Write-Host ("- {0}" -f $relativePath)
    foreach ($name in $item.Unresolved) {
      Write-Host ("    * {0}" -f $name)
    }
  }

  if ($newAliasCandidates.Count -gt 0) {
    Write-Host 'New alias candidates:'
    foreach ($candidate in $newAliasCandidates) {
      Write-Host ("  - {0}" -f $candidate)
    }
  }

  if ($mode -eq 'validate' -and @($unresolvedByPublication).Count -gt 0) {
    exit 1
  }
} finally {
  Pop-Location
}
