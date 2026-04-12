[CmdletBinding(DefaultParameterSetName = 'Sync')]
param(
  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [Parameter(ParameterSetName = 'Orcid')]
  [string]$ContentRoot = 'content/publication',

  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [Parameter(ParameterSetName = 'Orcid')]
  [string]$AuthorRoot = 'content/authors',

  [Parameter(ParameterSetName = 'Sync')]
  [Parameter(ParameterSetName = 'Validate')]
  [Parameter(ParameterSetName = 'Import')]
  [Parameter(ParameterSetName = 'Orcid')]
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
  [Parameter(ParameterSetName = 'Orcid')]
  [switch]$WriteChanges,

  [Parameter(ParameterSetName = 'Validate')]
  [switch]$ValidateOnly,

  [Parameter(ParameterSetName = 'Validate')]
  [switch]$IgnoreUnresolvedAuthors,

  [Parameter(ParameterSetName = 'Orcid', Mandatory = $true)]
  [switch]$ImportOrcidSources,

  [Parameter(ParameterSetName = 'Orcid')]
  [string]$PublicationSourceFile = 'data/publication_sources.yaml',

  [Parameter(ParameterSetName = 'Orcid')]
  [string]$SourceSlug
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
  $sanitized = if ($null -ne $Text) { $Text -replace '<[^>]+>', '' } else { $Text }
  $value = Remove-Diacritics $sanitized
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

function Parse-PublicationSourceFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $entries = @()
  $current = $null

  foreach ($line in (Read-Utf8File $Path) -split "`r?`n") {
    if ($line -match '^\s*-\s+slug:\s*(.+?)\s*$') {
      if ($current) {
        $entries += [PSCustomObject]$current
      }
      $current = @{
        slug = $Matches[1].Trim()
        orcid = ''
        primary = 'false'
      }
      continue
    }

    if (-not $current) {
      continue
    }

    if ($line -match '^\s*orcid:\s*(.+?)\s*$') {
      $current.orcid = $Matches[1].Trim()
      continue
    }

    if ($line -match '^\s*primary:\s*(.+?)\s*$') {
      $current.primary = $Matches[1].Trim().ToLowerInvariant()
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

function Get-PublicationIdentityIndex {
  param([Parameter(Mandatory = $true)][string]$Root)

  $doiIndex = @{}
  $titleIndex = @{}

  foreach ($dir in Get-ChildItem -Path $Root -Directory) {
    $indexPath = Join-Path $dir.FullName 'index.md'
    if (-not (Test-Path $indexPath)) {
      continue
    }

    $title = ''
    $doi = ''
    foreach ($line in Get-Content $indexPath) {
      if ($line -match '^title:\s*(.+)$') {
        $title = Normalize-Whitespace ($Matches[1].Trim("'"))
      } elseif ($line -match '^doi:\s*(.+)$') {
        $doi = Normalize-Whitespace $Matches[1]
      }
    }

    if ($doi) {
      $doiIndex[$doi.ToLowerInvariant()] = $dir.FullName
    }
    if ($title) {
      $titleIndex[(Get-ComparableName $title)] = $dir.FullName
    }
  }

  return [PSCustomObject]@{
    Doi = $doiIndex
    Title = $titleIndex
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

function Get-OrcidWorkSummaries {
  param([Parameter(Mandatory = $true)][string]$Orcid)

  $cleanOrcid = ($Orcid -replace '^https?://orcid.org/', '').Trim()
  $response = Invoke-RestMethod -Headers @{ Accept = 'application/json' } -Uri ("https://pub.orcid.org/v3.0/{0}/works" -f $cleanOrcid)

  $items = @()
  foreach ($group in @($response.group)) {
    $summary = $group.'work-summary'[0]
    if (-not $summary) {
      continue
    }

    $doi = ''
    foreach ($externalId in @($group.'external-ids'.'external-id')) {
      if ($externalId.'external-id-type' -eq 'doi') {
        $doi = Normalize-Whitespace $externalId.'external-id-value'
        break
      }
    }

    $title = ''
    if ($summary.title.title.value) {
      $title = Normalize-Whitespace $summary.title.title.value
    }

    $journal = ''
    if ($summary.'journal-title'.value) {
      $journal = Normalize-Whitespace $summary.'journal-title'.value
    }

    $year = ''
    if ($summary.'publication-date'.year.value) {
      $year = Normalize-Whitespace $summary.'publication-date'.year.value
    }

    $url = ''
    if ($summary.url.value) {
      $url = Normalize-Whitespace $summary.url.value
    } elseif ($doi) {
      $url = 'https://doi.org/{0}' -f $doi
    }

    $items += [PSCustomObject]@{
      Orcid = $cleanOrcid
      PutCode = $summary.'put-code'
      Title = $title
      Doi = $doi
      Year = $year
      Journal = $journal
      Url = $url
    }
  }

  return @($items)
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

function Get-DoiBibTex {
  param([Parameter(Mandatory = $true)][string]$DoiValue)

  $doiUrl = 'https://doi.org/{0}' -f $DoiValue
  $response = Invoke-WebRequest -Headers @{ Accept = 'application/x-bibtex; charset=utf-8' } -Uri $doiUrl
  return ($response.Content.Trim() + "`n")
}

function Get-PublicationTypesForWorkType {
  param([AllowNull()][string]$WorkType)

  switch ($WorkType) {
    'book-chapter' { return @('5') }
    default { return @('2') }
  }
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
    PublicationTypes = @('2')
    Source = 'bibtex'
  }
}

function Get-SlugPart {
  param([AllowNull()][string]$Text)

  $value = Get-ComparableName $Text
  $value = $value -replace '''', ''
  $value = $value -replace '[^a-z0-9]+', '-'
  $value = $value.Trim('-')
  if (-not $value) {
    return 'publication'
  }
  return $value
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
  if ($null -ne $message.PSObject.Properties['abstract'] -and $message.abstract) {
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
    PublicationTypes = @('2')
    Source = 'doi'
  }
}

function Get-OrcidWorkMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Orcid,
    [Parameter(Mandatory = $true)][string]$PutCode
  )

  $cleanOrcid = ($Orcid -replace '^https?://orcid.org/', '').Trim()
  $response = Invoke-RestMethod -Headers @{ Accept = 'application/json' } -Uri ("https://pub.orcid.org/v3.0/{0}/work/{1}" -f $cleanOrcid, $PutCode)

  $record = @{}
  $citationValue = ''
  if ($response.citation.'citation-value') {
    $citationValue = Normalize-Whitespace $response.citation.'citation-value'
    if ($response.citation.'citation-type' -eq 'bibtex') {
      $record = Parse-BibTexRecord $response.citation.'citation-value'
    }
  }

  $authors = @()
  foreach ($contributor in @($response.contributors.contributor)) {
    if ($contributor.'credit-name'.value) {
      $parsed = Parse-AuthorName $contributor.'credit-name'.value
      if ($parsed) {
        $authors += $parsed.Display
      }
    }
  }
  if ($authors.Count -eq 0 -and $record.ContainsKey('author')) {
    foreach ($author in Split-BibAuthors $record['author']) {
      $parsed = Parse-AuthorName $author
      if ($parsed) {
        $authors += $parsed.Display
      }
    }
  }

  $title = if ($record.ContainsKey('title')) { Normalize-Whitespace $record['title'] } else { Normalize-Whitespace $response.title.title.value }
  $publication = if ($record.ContainsKey('journal')) { Normalize-Whitespace $record['journal'] } else { Normalize-Whitespace $response.'journal-title'.value }
  $year = if ($record.ContainsKey('year')) { Normalize-Whitespace $record['year'] } else { Normalize-Whitespace $response.'publication-date'.year.value }
  $url = Normalize-Whitespace $response.url.value
  $doi = ''
  foreach ($externalId in @($response.'external-ids'.'external-id')) {
    if ($externalId.'external-id-type' -eq 'doi' -and $externalId.'external-id-relationship' -eq 'self') {
      $doi = Normalize-Whitespace $externalId.'external-id-value'
      break
    }
  }

  return [PSCustomObject]@{
    Title = $title
    Abstract = ''
    Publication = $publication
    Year = $year
    Doi = $doi
    Url = $url
    Authors = $authors
    PublicationTypes = (Get-PublicationTypesForWorkType $response.type)
    CitationValue = $citationValue
    Source = 'orcid'
  }
}

function Get-PublicationDirectoryName {
  param(
    [Parameter(Mandatory = $true)]$Metadata,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $firstAuthor = 'publication'
  if ($Metadata.Authors.Count -gt 0) {
    $parsed = Parse-AuthorName $Metadata.Authors[0]
    if ($parsed -and $parsed.Family) {
      $firstAuthor = Get-SlugPart $parsed.Family
    }
  }

  $yearPart = if ($Metadata.Year) { $Metadata.Year } else { (Get-Date).ToString('yyyy') }
  $suffixSource = if ($Metadata.Doi) { $Metadata.Doi } else { $Metadata.Title }
  $suffixPart = Get-SlugPart $suffixSource
  if ($suffixPart.Length -gt 24) {
    $suffixPart = $suffixPart.Substring($suffixPart.Length - 24)
  }

  $candidate = '{0}-{1}-{2}' -f $firstAuthor, $yearPart, $suffixPart
  $candidate = $candidate.Trim('-')
  if (-not (Test-Path (Join-Path $Root $candidate))) {
    return $candidate
  }

  $counter = 2
  do {
    $next = '{0}-{1}' -f $candidate, $counter
    $counter++
  } while (Test-Path (Join-Path $Root $next))

  return $next
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
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SourceAuthors,
    [Parameter(Mandatory = $true)][hashtable]$SignatureMap
  )

  $resolved = New-Object System.Collections.Generic.List[string]
  $seenAuthors = New-Object 'System.Collections.Generic.HashSet[string]'
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
      if ($seenAuthors.Add($matchedSlug)) {
        $resolved.Add($matchedSlug)
      }
    } else {
      if ($seenAuthors.Add($normalizedAuthor)) {
        $resolved.Add($normalizedAuthor)
      }
      $unresolved.Add($normalizedAuthor)
    }
  }

  return [PSCustomObject]@{
    Authors = @($resolved)
    Unresolved = @($unresolved | Sort-Object -Unique)
  }
}

function Find-DuplicatePublications {
  param([Parameter(Mandatory = $true)][object[]]$Results)

  $records = foreach ($item in $Results) {
    $indexPath = Join-Path $item.Path 'index.md'
    if (-not (Test-Path $indexPath)) {
      continue
    }

    $title = ''
    $doi = ''
    foreach ($line in Get-Content $indexPath) {
      if ($line -match '^title:\s*(.+)$') {
        $title = Normalize-Whitespace ($Matches[1].Trim("'"))
      } elseif ($line -match '^doi:\s*(.+)$') {
        $doi = Normalize-Whitespace $Matches[1]
      }
    }

    [PSCustomObject]@{
      Path = $item.Path
      Title = $title
      Doi = $doi
    }
  }

  $titleDuplicates = @(
    $records |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_.Title) } |
      Group-Object Title |
      Where-Object Count -gt 1
  )

  $doiDuplicates = @(
    $records |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_.Doi) } |
      Group-Object Doi |
      Where-Object Count -gt 1
  )

  return [PSCustomObject]@{
    ByTitle = $titleDuplicates
    ByDoi = $doiDuplicates
  }
}

function Set-FrontMatterAuthors {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Authors
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

function ConvertTo-YamlSingleQuoted {
  param([AllowNull()][string]$Value)

  $normalized = Normalize-Whitespace $Value
  if ($null -eq $normalized) {
    $normalized = ''
  }

  return "'" + ($normalized -replace "'", "''") + "'"
}

function Build-PublicationFrontMatter {
  param(
    [Parameter(Mandatory = $true)]$Metadata,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Authors
  )

  $dateValue = if ($Metadata.Year) { "{0}-01-01" -f $Metadata.Year } else { (Get-Date).ToString('yyyy-01-01') }
  $lines = @(
    '---'
    ("title: {0}" -f (ConvertTo-YamlSingleQuoted $Metadata.Title))
    ("date: {0}" -f (ConvertTo-YamlSingleQuoted $dateValue))
    ''
    'authors:'
  )
  foreach ($author in $Authors) {
    $lines += "- $author"
  }
  $lines += ''
  $lines += ("abstract: {0}" -f (ConvertTo-YamlSingleQuoted $Metadata.Abstract))
  $lines += 'featured: false'
  $lines += ("publication: {0}" -f (ConvertTo-YamlSingleQuoted ("*{0}*" -f $Metadata.Publication)))
  if ($Metadata.Url) {
    $lines += ("url_source: {0}" -f (ConvertTo-YamlSingleQuoted $Metadata.Url))
  }
  if ($Metadata.Doi) {
    $lines += ("doi: {0}" -f (ConvertTo-YamlSingleQuoted $Metadata.Doi))
  }
  $publicationTypes = if ($Metadata.PSObject.Properties['PublicationTypes'] -and @($Metadata.PublicationTypes).Count -gt 0) { @($Metadata.PublicationTypes) } else { @('2') }
  $typeValues = ($publicationTypes | ForEach-Object { "'$_'" }) -join ', '
  $lines += ("publication_types: [{0}]" -f $typeValues)
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
    [string]$DoiValue,
    $MetadataOverride
  )

  $indexPath = Join-Path $PublicationPath 'index.md'
  if (-not (Test-Path $indexPath) -and -not $Persist) {
    throw "index.md not found in $PublicationPath"
  }

  $metadata = if ($null -ne $MetadataOverride) { $MetadataOverride } else { Get-PublicationMetadata -DirectoryPath $PublicationPath -BibPathOverride $BibPath -DoiOverride $DoiValue }
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

function Get-OrcidImportCandidates {
  param(
    [Parameter(Mandatory = $true)][object[]]$Sources,
    [Parameter(Mandatory = $true)]$ExistingIndex,
    [string]$FilterSlug
  )

  $allCandidates = @()
  $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach ($source in $Sources) {
    if ($FilterSlug -and $source.slug -ne $FilterSlug) {
      continue
    }

    foreach ($work in (Get-OrcidWorkSummaries $source.orcid)) {
      $comparisonTitle = Get-ComparableName $work.Title
      $doiKey = if ($work.Doi) { $work.Doi.ToLowerInvariant() } else { '' }
      $exists = $false

      if ($doiKey -and $ExistingIndex.Doi.ContainsKey($doiKey)) {
        $exists = $true
      } elseif ($comparisonTitle -and $ExistingIndex.Title.ContainsKey($comparisonTitle)) {
        $exists = $true
      }

      $identityKeys = @()
      if ($doiKey) {
        $identityKeys += ('doi::{0}' -f $doiKey)
      }
      if ($comparisonTitle) {
        $identityKeys += ('title::{0}' -f $comparisonTitle)
      }

      $seenAlready = $false
      foreach ($identityKey in $identityKeys) {
        if ($seenKeys.Contains($identityKey)) {
          $seenAlready = $true
          break
        }
      }

      if ($exists -or $seenAlready) {
        continue
      }

      foreach ($identityKey in $identityKeys) {
        [void]$seenKeys.Add($identityKey)
      }

      $allCandidates += [PSCustomObject]@{
        SourceSlug = $source.slug
        Orcid = $source.orcid
        PutCode = $work.PutCode
        Title = $work.Title
        Doi = $work.Doi
        Year = $work.Year
        Journal = $work.Journal
        Url = $work.Url
      }
    }
  }

  return @($allCandidates | Sort-Object Year, Title)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir '..')
Push-Location $repoRoot

try {
  $mode = switch ($PSCmdlet.ParameterSetName) {
    'Validate' { 'validate' }
    'Import' { 'import' }
    'Orcid' { 'orcid' }
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

  if ($mode -eq 'orcid') {
    $sources = Parse-PublicationSourceFile $PublicationSourceFile
    $existingIndex = Get-PublicationIdentityIndex -Root $ContentRoot
    $candidates = Get-OrcidImportCandidates -Sources $sources -ExistingIndex $existingIndex -FilterSlug $SourceSlug

    Write-Host ("Mode: orcid")
    Write-Host ("Configured sources: {0}" -f @($sources).Count)
    Write-Host ("Missing ORCID works: {0}" -f @($candidates).Count)

    if (-not $WriteChanges) {
      foreach ($candidate in $candidates) {
        Write-Host ("- [{0}] {1} ({2})" -f $candidate.SourceSlug, $candidate.Title, $candidate.Year)
        if ($candidate.Doi) {
          Write-Host ("    DOI: {0}" -f $candidate.Doi)
        }
      }
      exit 0
    }

    $imported = @()
    foreach ($candidate in $candidates) {
      $metadata = if ($candidate.Doi) { Get-DoiMetadata $candidate.Doi } else { Get-OrcidWorkMetadata -Orcid $candidate.Orcid -PutCode $candidate.PutCode }
      $dirName = Get-PublicationDirectoryName -Metadata $metadata -Root $ContentRoot
      $targetPath = Join-Path $ContentRoot $dirName
      $result = Invoke-PublicationSync -PublicationPath $targetPath -Registry $registry -Persist -DoiValue $candidate.Doi -MetadataOverride $metadata

      if ($candidate.Doi) {
        try {
          $bibContent = Get-DoiBibTex $candidate.Doi
          Write-Utf8File -Path (Join-Path $targetPath 'cite.bib') -Content $bibContent
        } catch {
          Write-Warning ("Could not fetch BibTeX for DOI {0}" -f $candidate.Doi)
        }
      } elseif ($metadata.PSObject.Properties['CitationValue'] -and $metadata.CitationValue) {
        Write-Utf8File -Path (Join-Path $targetPath 'cite.bib') -Content ($metadata.CitationValue + "`n")
      }

      $existingIndex = Get-PublicationIdentityIndex -Root $ContentRoot
      $imported += [PSCustomObject]@{
        Path = $targetPath
        Title = $metadata.Title
        Doi = $candidate.Doi
        SourceSlug = $candidate.SourceSlug
        Unresolved = $result.Unresolved
      }
    }

    Write-Host ("Imported ORCID works: {0}" -f @($imported).Count)
    foreach ($item in $imported) {
      $relativePath = Resolve-Path -LiteralPath $item.Path -Relative
      Write-Host ("- [{0}] {1}" -f $item.SourceSlug, $relativePath)
      if ($item.Unresolved.Count -gt 0) {
        Write-Warning ("Unresolved authors: {0}" -f ($item.Unresolved -join '; '))
      }
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
  $duplicatePublications = Find-DuplicatePublications -Results $results

  Write-Host ("Mode: {0}" -f $mode)
  Write-Host ("Publications scanned: {0}" -f $results.Count)
  Write-Host ("Publications changed: {0}" -f $changedCount)
  Write-Host ("Publications with unresolved authors: {0}" -f @($unresolvedByPublication).Count)
  Write-Host ("Duplicate titles: {0}" -f @($duplicatePublications.ByTitle).Count)
  Write-Host ("Duplicate DOIs: {0}" -f @($duplicatePublications.ByDoi).Count)

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

  if (@($duplicatePublications.ByTitle).Count -gt 0) {
    Write-Host 'Duplicate publications by title:'
    foreach ($group in $duplicatePublications.ByTitle) {
      Write-Host ("- {0}" -f $group.Name)
      foreach ($entry in $group.Group) {
        $relativePath = Resolve-Path -LiteralPath $entry.Path -Relative
        Write-Host ("    * {0}" -f $relativePath)
      }
    }
  }

  if (@($duplicatePublications.ByDoi).Count -gt 0) {
    Write-Host 'Duplicate publications by DOI:'
    foreach ($group in $duplicatePublications.ByDoi) {
      Write-Host ("- {0}" -f $group.Name)
      foreach ($entry in $group.Group) {
        $relativePath = Resolve-Path -LiteralPath $entry.Path -Relative
        Write-Host ("    * {0}" -f $relativePath)
      }
    }
  }

  $hasBlockingUnresolvedAuthors = (-not $IgnoreUnresolvedAuthors) -and (@($unresolvedByPublication).Count -gt 0)
  if ($mode -eq 'validate' -and ($hasBlockingUnresolvedAuthors -or @($duplicatePublications.ByTitle).Count -gt 0 -or @($duplicatePublications.ByDoi).Count -gt 0)) {
    exit 1
  }
} finally {
  Pop-Location
}
