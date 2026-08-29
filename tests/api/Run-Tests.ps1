<#
.SYNOPSIS
    Runs the Pocket Casts API contract tests in a container.

.DESCRIPTION
    Python is not installed on the machine this repo is developed on, and the
    proxy is already tested in Docker, so this does the same. The repo
    directory is mounted, which is what lets --update-shapes write new
    baselines back into the tree.

    Credentials are passed by NAME (-e PC_EMAIL, no value), so docker inherits
    them from this shell's environment and no secret reaches a command line,
    a layer or a file.

.EXAMPLE
    $env:PC_EMAIL = 'you@example.com'
    $env:PC_PASSWORD = 'hunter2'
    .\tests\api\Run-Tests.ps1

.EXAMPLE
    .\tests\api\Run-Tests.ps1 -UpdateShapes

.EXAMPLE
    # Find an episode to point the mutating tests at, and print the two lines
    # to paste. Read-only.
    .\tests\api\Run-Tests.ps1 -ListEpisodes

.EXAMPLE
    $env:PC_TEST_EPISODE_UUID = '...'; $env:PC_TEST_PODCAST_UUID = '...'
    .\tests\api\Run-Tests.ps1 -Mutating
#>
[CmdletBinding()]
param(
    # Also run the tests that WRITE to the account.
    [switch]$Mutating,

    # Rewrite the stored response shapes instead of comparing against them.
    [switch]$UpdateShapes,

    # Print the account's episodes and pick a candidate for -Mutating,
    # instead of running any tests. Read-only.
    [switch]$ListEpisodes,

    # Extra arguments passed straight to pytest, e.g. -PytestArgs '-k','login'.
    [string[]]$PytestArgs = @()
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $env:PC_EMAIL -or -not $env:PC_PASSWORD) {
    Write-Warning "PC_EMAIL / PC_PASSWORD are not set - everything that needs an account will skip."
}
if ($Mutating -and -not $env:PC_TEST_EPISODE_UUID) {
    Write-Warning "PC_TEST_EPISODE_UUID is not set - the update_episode tests will skip. The Up Next removal test does not use it; it aims at the last entry in the real queue."
}
if ($Mutating) {
    Write-Warning "-Mutating marks a real Up Next entry played to find out whether that removes it. If it does, nothing here can put it back - see test_up_next_removal.py."
}

if ($ListEpisodes) {
    $inner = 'python list_episodes.py'
} else {
    $pytest = @('-v', '--no-header')
    if ($Mutating)     { $pytest += '--mutating' }
    if ($UpdateShapes) { $pytest += '--update-shapes' }
    $pytest += $PytestArgs
    $inner = 'python -m pytest ' + ($pytest -join ' ')
}

$command = 'pip install -q --disable-pip-version-check -r requirements.txt && ' + $inner

& docker run --rm `
    -v "${here}:/w" -w /w `
    -e PC_EMAIL -e PC_PASSWORD -e PC_TEST_EPISODE_UUID -e PC_TEST_PODCAST_UUID `
    -e PC_ROUND_TRIP_SECONDS -e PC_TEST_UPNEXT_UUID -e PC_UP_NEXT_SECONDS -e PC_UP_NEXT_NO_RESTORE `
    -e PC_TEST_UPNEXT_REMOVE_UUID -e PC_TEST_UPNEXT_SHAPE `
    python:3.12-slim sh -c $command

exit $LASTEXITCODE
