$ErrorActionPreference = "Stop"

$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
	throw "Could not find the repository root."
}

git -C $repoRoot config core.hooksPath .githooks
Write-Host "Git hooks enabled for $repoRoot"
