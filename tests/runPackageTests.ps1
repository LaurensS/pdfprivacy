param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

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

function Get-TestCaseExpectation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TexFilePath
    )

    $headerLines = Get-Content -LiteralPath $TexFilePath -TotalCount 12
    $expectation = [ordered]@{
        Build = $null
        Package = $null
        Absent = @()
    }

    foreach ($line in $headerLines) {
        if ($line -match '^\s*$') {
            continue
        }

        if ($line -notmatch '^\s*%\s*pdfprivacy-test:\s*') {
            break
        }

        if ($line -match '^\s*%\s*pdfprivacy-test:\s*build=(?<build>success|fail)\s+package=(?<package>none|warning|error)\s*$') {
            $expectation.Build = $Matches.build.ToLowerInvariant()
            $expectation.Package = $Matches.package.ToLowerInvariant()
            continue
        }

        if ($line -match '^\s*%\s*pdfprivacy-test:\s*absent=(?<absent>.+?)\s*$') {
            $absentValues = $Matches.absent.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }
            $expectation.Absent += $absentValues
            continue
        }

        throw "Invalid pdfprivacy-test header in $TexFilePath. Expected directives like `% pdfprivacy-test: build=success package=none` or `% pdfprivacy-test: absent=PDF:Author,PDF:Title`."
    }

    if ($null -eq $expectation.Build -or $null -eq $expectation.Package) {
        throw "Missing pdfprivacy-test build/package directive in $TexFilePath. Expected `% pdfprivacy-test: build=(success|fail) package=(none|warning|error)` before the document content."
    }

    if ($expectation.Build -eq 'success' -and $expectation.Absent.Count -eq 0) {
        throw "Missing pdfprivacy-test absent directive in $TexFilePath. Successful tests must declare which metadata entries must be absent."
    }

    return [PSCustomObject]$expectation
}

function Test-ExpectedPackageDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CombinedBuildOutput,
        [Parameter(Mandatory = $true)]
        [string]$PackageExpectation
    )

    switch ($PackageExpectation) {
        'none' {
            return -not ($CombinedBuildOutput -match '(?s)Package\s+pdfprivacy\s+(Warning|Error):')
        }
        'warning' {
            return $CombinedBuildOutput -match '(?s)Package\s+pdfprivacy\s+Warning:'
        }
        'error' {
            return $CombinedBuildOutput -match '(?s)Package\s+pdfprivacy\s+Error:'
        }
        default {
            throw "Unknown package expectation '$PackageExpectation'"
        }
    }
}

function Test-ExpectedMetadataAbsence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Metadata,
        [Parameter(Mandatory = $true)]
        [string[]]$AbsentTags,
        [Parameter(Mandatory = $true)]
        [string]$PdfPath
    )

    $failedChecks = @()
    foreach ($tag in $AbsentTags) {
        if ($tag -match '^(?i:PDF:TrailerID|TrailerID|pdftrailerid)$') {
            $verboseMetadata = & exiftool -v3 "$PdfPath"
            if ($LASTEXITCODE -ne 0) {
                $failedChecks += "Unable to inspect trailer ID with exiftool -v3"
            }
            elseif ($verboseMetadata -match '(?m)^\s*\d+\)\s+ID\s*=\s*\[') {
                $failedChecks += "PDF trailer ID is still present"
            }
            continue
        }

        if ($tag -match '[\*\?]') {
            $matchingKeys = @($Metadata.PSObject.Properties.Name | Where-Object { $_ -like $tag })
            if ($matchingKeys.Count -gt 0) {
                $failedChecks += "Metadata keys still present: $($matchingKeys -join ', ')"
            }
            continue
        }

        if (-not (Test-MetadataMissingOrEmpty -Metadata $Metadata -Key $tag)) {
            $value = Get-MetadataValue -Metadata $Metadata -Key $tag
            $failedChecks += "$tag has value '$value'"
        }
    }

    return $failedChecks
}

function Add-Failure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [ref]$Failures
    )

    $Failures.Value += $Message
}

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
    $markerBlock = @"
% PDFPRIVACY_TESTRUN_MARKER_BEGIN
\AtBeginDocument{%
\wlog{__MARKER__}%
\message{__MARKER__}%
}
% PDFPRIVACY_TESTRUN_MARKER_END
"@.Replace("__MARKER__", $Marker)

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

if (-not (Test-CommandAvailable -Name "latexmk")) {
    Write-Error "latexmk was not found in PATH. Install TeX with latexmk and try again."
    exit 1
}

if (-not (Test-CommandAvailable -Name "exiftool")) {
    Write-Error "exiftool was not found in PATH. Install ExifTool and try again."
    exit 1
}

$targetPath = Resolve-Path -LiteralPath $Path
$targetPathString = $targetPath.Path
$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
$repoRootPath = $repoRoot.Path
$pdfPrivacyStylePath = Join-Path $repoRootPath "pdfprivacy.sty"
$testRunId = [Guid]::NewGuid().ToString("N")
$testRunMarker = "PDFPRIVACY-TESTRUN-ID:$testRunId"

$engineConfigs = @(
    @{ Name = "latex"; BuildFlag = "-pdf" },
    @{ Name = "xelatex"; BuildFlag = "-xelatex" },
    @{ Name = "lualatex"; BuildFlag = "-lualatex" }
)

$selectedEngines = @()
$targetLeaf = Split-Path -Leaf $targetPathString
$directEngine = $engineConfigs | Where-Object { $_.Name -ieq $targetLeaf } | Select-Object -First 1
if ($null -ne $directEngine) {
    $selectedEngines += @{ Name = $directEngine.Name; BuildFlag = $directEngine.BuildFlag; Root = $targetPathString }
}
else {
    foreach ($engine in $engineConfigs) {
        $engineRoot = Join-Path $targetPathString $engine.Name
        if (Test-Path -LiteralPath $engineRoot -PathType Container) {
            $selectedEngines += @{ Name = $engine.Name; BuildFlag = $engine.BuildFlag; Root = $engineRoot }
        }
    }
}

if ($selectedEngines.Count -eq 0) {
    Write-Error "No engine testcase folders found under $targetPathString. Expected one or more of: latex, xelatex, lualatex"
    exit 1
}

$originalTexInputs = $env:TEXINPUTS
try {
    Update-PdfPrivacyStyleRunMarker -StylePath $pdfPrivacyStylePath -Marker $testRunMarker
    Write-Host "Using test run ID: $testRunId"

    if ([string]::IsNullOrWhiteSpace($originalTexInputs)) {
        $env:TEXINPUTS = "$repoRootPath;"
    }
    else {
        $env:TEXINPUTS = "$repoRootPath;$originalTexInputs"
    }

    $testCases = @()
    foreach ($engine in $selectedEngines) {
        $engineTexFiles = Get-ChildItem -LiteralPath $engine.Root -Filter "*.tex" -File | Sort-Object FullName
        foreach ($texFile in $engineTexFiles) {
            $testCases += [PSCustomObject]@{
                EngineName = $engine.Name
                BuildFlag = $engine.BuildFlag
                TexFile = $texFile
            }
        }
    }

    if ($testCases.Count -eq 0) {
        Write-Host "No .tex files found under selected engine folders."
        exit 0
    }

    $cleanFailures = @()
    $latexFailures = @()
    $styleMarkerFailures = @()
    $packageExpectationFailures = @()
    $pdfMissing = @()
    $metadataFailures = @()
    $skippedTests = @()

    foreach ($case in $testCases) {
        $texFile = $case.TexFile
        $engineName = $case.EngineName
        $buildFlag = $case.BuildFlag
        $caseLabel = "[$engineName] $($texFile.FullName)"
        $testExpectation = Get-TestCaseExpectation -TexFilePath $texFile.FullName

        Write-Host ""
        Write-Host "=== Cleaning $caseLabel ==="
        Push-Location -LiteralPath $texFile.DirectoryName
        try {
            & latexmk $buildFlag -C "$($texFile.Name)"
            if ($LASTEXITCODE -ne 0) {
                Add-Failure -Message $caseLabel -Failures ([ref]$cleanFailures)
                continue
            }
        }
        catch {
            Add-Failure -Message "$caseLabel -> $($_.Exception.Message)" -Failures ([ref]$cleanFailures)
            continue
        }
        finally {
            Pop-Location
        }

        Write-Host ""
        Write-Host "=== Building $caseLabel ==="
        Push-Location -LiteralPath $texFile.DirectoryName
        try {
            $buildOutput = & latexmk $buildFlag -interaction=nonstopmode -halt-on-error "$($texFile.Name)" 2>&1
            $buildExitCode = $LASTEXITCODE
            $buildOutputLines = @($buildOutput | ForEach-Object { $_.ToString() })
            $buildOutputLines | ForEach-Object { Write-Host $_ }
            $combinedBuildOutput = ($buildOutputLines -join [Environment]::NewLine)
            $packageMatchesExpectation = Test-ExpectedPackageDiagnostics -CombinedBuildOutput $combinedBuildOutput -PackageExpectation $testExpectation.Package

            if ($buildExitCode -ne 0) {
                if ($testExpectation.Build -eq 'fail' -and $packageMatchesExpectation) {
                    continue
                }
                Add-Failure -Message "$caseLabel -> build failed but directive expected '$($testExpectation.Build)' and package severity '$($testExpectation.Package)' was not satisfied" -Failures ([ref]$packageExpectationFailures)
                continue
            }

            if ($testExpectation.Build -eq 'fail') {
                Add-Failure -Message "$caseLabel -> build succeeded but directive expected failure" -Failures ([ref]$packageExpectationFailures)
                continue
            }

            if (-not $packageMatchesExpectation) {
                Add-Failure -Message "$caseLabel -> package diagnostic did not match expected '$($testExpectation.Package)' severity" -Failures ([ref]$packageExpectationFailures)
                continue
            }

            if ($combinedBuildOutput -notmatch [regex]::Escape($testRunMarker)) {
                Add-Failure -Message "$caseLabel -> run marker '$testRunMarker' not found in latexmk output" -Failures ([ref]$styleMarkerFailures)
                continue
            }
        }
        catch {
            Add-Failure -Message "$caseLabel -> $($_.Exception.Message)" -Failures ([ref]$latexFailures)
            continue
        }
        finally {
            Pop-Location
        }

        $pdfPath = [System.IO.Path]::ChangeExtension($texFile.FullName, ".pdf")
        if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
            Add-Failure -Message "$caseLabel -> Expected PDF not found: $pdfPath" -Failures ([ref]$pdfMissing)
            continue
        }

        Write-Host ""
        Write-Host "=== Metadata for $(Split-Path -Leaf $pdfPath) [$engineName] ==="
        & exiftool -a -G1 -s "$pdfPath"

        $metadataJson = & exiftool -j -a -G1 -s "$pdfPath"
        if ($LASTEXITCODE -ne 0) {
            Add-Failure -Message "$caseLabel -> Failed to read metadata JSON from $pdfPath" -Failures ([ref]$metadataFailures)
            continue
        }

        $metadata = $metadataJson | ConvertFrom-Json
        if ($metadata -is [array]) {
            $metadata = $metadata[0]
        }

        $failedChecks = Test-ExpectedMetadataAbsence -Metadata $metadata -AbsentTags $testExpectation.Absent -PdfPath $pdfPath

        if ($failedChecks.Count -gt 0) {
            Add-Failure -Message "$caseLabel -> $($failedChecks -join '; ')" -Failures ([ref]$metadataFailures)
        }
    }

    Write-Host ""
    Write-Host "=== Summary ==="
    Write-Host "Processed TeX files: $($testCases.Count)"
    Write-Host "Clean failures: $($cleanFailures.Count)"
    Write-Host "LaTeX build failures: $($latexFailures.Count)"
    Write-Host "Style marker failures: $($styleMarkerFailures.Count)"
    Write-Host "Package expectation failures: $($packageExpectationFailures.Count)"
    Write-Host "Missing PDFs: $($pdfMissing.Count)"
    Write-Host "Metadata assertion failures: $($metadataFailures.Count)"
    Write-Host "Skipped tests: $($skippedTests.Count)"

    if ($packageExpectationFailures.Count -gt 0) {
        Write-Host ""
        Write-Host "Package expectation failures:"
        $packageExpectationFailures | ForEach-Object { Write-Host "- $_" }
    }

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

    if (($cleanFailures.Count + $latexFailures.Count + $styleMarkerFailures.Count + $packageExpectationFailures.Count + $pdfMissing.Count + $metadataFailures.Count) -gt 0) {
        exit 1
    }

    exit 0
}
finally {
    $env:TEXINPUTS = $originalTexInputs
}