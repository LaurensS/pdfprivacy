param(
    [string]$Path = (Join-Path $PSScriptRoot "latex")
)

$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

if (-not (Test-CommandAvailable -Name "latexmk")) {
    Write-Error "latexmk was not found in PATH. Install TeX with latexmk and try again."
    exit 1
}

if (-not (Test-CommandAvailable -Name "exiftool")) {
    Write-Error "exiftool was not found in PATH. Install ExifTool and try again."
    exit 1
}

$targetPath = Resolve-Path -LiteralPath $Path
$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$repoRootPath = $repoRoot.Path
$pdfPrivacyStylePath = Join-Path $repoRootPath "pdfprivacy.sty"
$testRunId = [Guid]::NewGuid().ToString("N")
$testRunMarker = "PDFPRIVACY-TESTRUN-ID:$testRunId"

function Update-PdfPrivacyStyleRunMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StylePath,
        [Parameter(Mandatory = $true)]
        [string]$Marker
    )

    if (-not (Test-Path -LiteralPath $StylePath -PathType Leaf)) {
        throw "Style file not found: $StylePath"
    }

    $styleContent = Get-Content -LiteralPath $StylePath -Raw
    $markerBlock = @'
% PDFPRIVACY_TESTRUN_MARKER_BEGIN
\AtBeginDocument{%
\wlog{__MARKER__}%
\message{__MARKER__}%
}
% PDFPRIVACY_TESTRUN_MARKER_END
'@.Replace("__MARKER__", $Marker)

    $markerRegex = '(?ms)^% PDFPRIVACY_TESTRUN_MARKER_BEGIN\r?\n.*?^% PDFPRIVACY_TESTRUN_MARKER_END\r?\n?'
    if ($styleContent -match $markerRegex) {
        $updatedContent = [regex]::Replace(
            $styleContent,
            $markerRegex,
            { param($m) $markerBlock },
            1
        )
    }
    else {
        $endInputRegex = '(?m)^\\endinput\s*$'
        $updatedContent = [regex]::Replace(
            $styleContent,
            $endInputRegex,
            { param($m) "$markerBlock`r`n\endinput" },
            1
        )
    }

    if ($updatedContent -eq $styleContent) {
        throw "Failed to update run marker in $StylePath"
    }

    $updatedContent = $updatedContent -replace '(?m)^% PDFPRIVACY_TESTRUN_MARKER_END(?=\\endinput)', "% PDFPRIVACY_TESTRUN_MARKER_END`r`n"

    Set-Content -LiteralPath $StylePath -Value $updatedContent -NoNewline
}

Update-PdfPrivacyStyleRunMarker -StylePath $pdfPrivacyStylePath -Marker $testRunMarker
Write-Host "Using test run ID: $testRunId"

# Ensure local package files in the repo root are discoverable from subfolders.
$originalTexInputs = $env:TEXINPUTS
if ([string]::IsNullOrWhiteSpace($originalTexInputs)) {
    $env:TEXINPUTS = "$repoRootPath;"
}
else {
    $env:TEXINPUTS = "$repoRootPath;$originalTexInputs"
}

$texFiles = Get-ChildItem -LiteralPath $targetPath -Filter "*.tex" -File -Recurse | Sort-Object FullName

if ($texFiles.Count -eq 0) {
    Write-Host "No .tex files found in $targetPath"
    exit 0
}

$supportedOptions = @("nodocdata", "noproducerdata", "noeditdata", "noptexdata", "nopdftrailerid", "all")

$latexFailures = @()
$pdfMissing = @()
$metadataFailures = @()
$skippedTests = @()
$cleanFailures = @()
$styleMarkerFailures = @()

function Get-MetadataValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $prop = $Metadata.PSObject.Properties[$Key]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Test-MetadataMissingOrEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $value = Get-MetadataValue -Metadata $Metadata -Key $Key
    if ($null -eq $value) {
        return $true
    }

    if ($value -is [string] -and [string]::IsNullOrEmpty($value)) {
        return $true
    }

    return $false
}

foreach ($texFile in $texFiles) {
    $optionName = Split-Path -Leaf $texFile.DirectoryName
    if ($supportedOptions -notcontains $optionName) {
        $skippedTests += $texFile.FullName
        Write-Warning "Skipping $($texFile.FullName) because parent folder '$optionName' is not a supported option name."
        continue
    }

    Write-Host ""
    Write-Host "=== Cleaning $($texFile.FullName) [$optionName] ==="
    Push-Location -LiteralPath $texFile.DirectoryName
    try {
        & latexmk -C "$($texFile.Name)"
        if ($LASTEXITCODE -ne 0) {
            $cleanFailures += $texFile.FullName
            continue
        }
    }
    catch {
        $cleanFailures += $texFile.FullName
        continue
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "=== Building $($texFile.FullName) [$optionName] ==="

    Push-Location -LiteralPath $texFile.DirectoryName
    try {
        $buildOutput = & latexmk -pdf -interaction=nonstopmode -halt-on-error "$($texFile.Name)" 2>&1
        $buildExitCode = $LASTEXITCODE
        $buildOutputLines = @($buildOutput | ForEach-Object { $_.ToString() })
        $buildOutputLines | ForEach-Object { Write-Host $_ }

        if ($buildExitCode -ne 0) {
            $latexFailures += $texFile.FullName
            continue
        }

        $combinedBuildOutput = ($buildOutputLines -join [Environment]::NewLine)
        if ($combinedBuildOutput -notmatch [regex]::Escape($testRunMarker)) {
            $styleMarkerFailures += "[$optionName] $($texFile.FullName) -> run marker '$testRunMarker' not found in latexmk output"
            continue
        }
    }
    catch {
        $latexFailures += $texFile.FullName
        continue
    }
    finally {
        Pop-Location
    }

    $pdfPath = [System.IO.Path]::ChangeExtension($texFile.FullName, ".pdf")
    if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
        $pdfMissing += $pdfPath
        Write-Warning "Expected PDF not found: $pdfPath"
        continue
    }

    Write-Host ""
    Write-Host "=== Metadata for $(Split-Path -Leaf $pdfPath) ==="
    # -a shows duplicate tags, -G1 groups by family 1, -s prints short tag names.
    & exiftool -a -G1 -s "$pdfPath"

    $metadataJson = & exiftool -j -a -G1 -s "$pdfPath"
    if ($LASTEXITCODE -ne 0) {
        $metadataFailures += "[$optionName] Failed to read metadata JSON from $pdfPath"
        continue
    }

    $metadata = $metadataJson | ConvertFrom-Json
    if ($metadata -is [array]) {
        $metadata = $metadata[0]
    }

    $failedChecks = @()

    switch ($optionName) {
        "nodocdata" {
            $docTags = @("PDF:Author", "PDF:Title", "PDF:Subject", "PDF:Keywords")
            foreach ($tag in $docTags) {
                if (-not (Test-MetadataMissingOrEmpty -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "$tag has value '$value'"
                }
            }
        }
        "noproducerdata" {
            $producerTags = @("PDF:Creator", "PDF:Producer")
            foreach ($tag in $producerTags) {
                if (-not (Test-MetadataMissingOrEmpty -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "$tag has value '$value'"
                }
            }
        }
        "noeditdata" {
            $dateTags = @("PDF:CreateDate", "PDF:ModifyDate")
            foreach ($tag in $dateTags) {
                if ($null -ne (Get-MetadataValue -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "$tag is still present with value '$value'"
                }
            }
        }
        "noptexdata" {
            $ptexKeys = @($metadata.PSObject.Properties.Name | Where-Object { $_ -like "PDF:PTEX_*" })
            if ($ptexKeys.Count -gt 0) {
                $failedChecks += "PTEX tags still present: $($ptexKeys -join ", ")"
            }
        }
        "nopdftrailerid" {
            $verboseMetadata = & exiftool -v3 "$pdfPath"
            if ($LASTEXITCODE -ne 0) {
                $failedChecks += "Unable to inspect trailer ID with exiftool -v3"
            }
            elseif ($verboseMetadata -match "(?m)^\s*\d+\)\s+ID\s*=\s*\[") {
                $failedChecks += "PDF trailer ID is still present"
            }
        }
        "all" {
            # "all" option should remove everything, so combine all checks from individual options
            $docTags = @("PDF:Author", "PDF:Title", "PDF:Subject", "PDF:Keywords")
            foreach ($tag in $docTags) {
                if (-not (Test-MetadataMissingOrEmpty -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "[$tag] has value '$value' (nodocdata failed)"
                }
            }

            $producerTags = @("PDF:Creator", "PDF:Producer")
            foreach ($tag in $producerTags) {
                if (-not (Test-MetadataMissingOrEmpty -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "[$tag] has value '$value' (noproducerdata failed)"
                }
            }

            $dateTags = @("PDF:CreateDate", "PDF:ModifyDate")
            foreach ($tag in $dateTags) {
                if ($null -ne (Get-MetadataValue -Metadata $metadata -Key $tag)) {
                    $value = Get-MetadataValue -Metadata $metadata -Key $tag
                    $failedChecks += "[$tag] is still present with value '$value' (noeditdata failed)"
                }
            }

            $ptexKeys = @($metadata.PSObject.Properties.Name | Where-Object { $_ -like "PDF:PTEX_*" })
            if ($ptexKeys.Count -gt 0) {
                $failedChecks += "PTEX tags still present: $($ptexKeys -join ", ") (noptexdata failed)"
            }

            $verboseMetadata = & exiftool -v3 "$pdfPath"
            if ($LASTEXITCODE -ne 0) {
                $failedChecks += "Unable to inspect trailer ID with exiftool -v3"
            }
            elseif ($verboseMetadata -match "(?m)^\s*\d+\)\s+ID\s*=\s*\[") {
                $failedChecks += "PDF trailer ID is still present (nopdftrailerid failed)"
            }
        }
    }

    if ($failedChecks.Count -gt 0) {
        $metadataFailures += "[$optionName] $pdfPath -> $($failedChecks -join "; ")"
    }
}

Write-Host ""
Write-Host "=== Summary ==="
Write-Host "Processed TeX files: $($texFiles.Count)"
Write-Host "Clean failures: $($cleanFailures.Count)"
Write-Host "LaTeX build failures: $($latexFailures.Count)"
Write-Host "Style marker failures: $($styleMarkerFailures.Count)"
Write-Host "Missing PDFs: $($pdfMissing.Count)"
Write-Host "Metadata assertion failures: $($metadataFailures.Count)"
Write-Host "Skipped tests: $($skippedTests.Count)"

if ($cleanFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Clean failures:"
    $cleanFailures | ForEach-Object { Write-Host "- $_" }
}

if ($latexFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Build failures:"
    $latexFailures | ForEach-Object { Write-Host "- $_" }
}

if ($styleMarkerFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Style marker failures:"
    $styleMarkerFailures | ForEach-Object { Write-Host "- $_" }
}

if ($pdfMissing.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing PDFs:"
    $pdfMissing | ForEach-Object { Write-Host "- $_" }
}

if ($metadataFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Metadata assertion failures:"
    $metadataFailures | ForEach-Object { Write-Host "- $_" }
}

if ($skippedTests.Count -gt 0) {
    Write-Host ""
    Write-Host "Skipped tests:"
    $skippedTests | ForEach-Object { Write-Host "- $_" }
}

if (($cleanFailures.Count + $latexFailures.Count + $styleMarkerFailures.Count + $pdfMissing.Count + $metadataFailures.Count) -gt 0) {
    $env:TEXINPUTS = $originalTexInputs
    exit 1
}

$env:TEXINPUTS = $originalTexInputs
exit 0
