[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$RemoteUrl,
    [string]$Branch='main',
    [string]$CommitMessage='Initial CISPolicyCreator framework'
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git was not found in PATH.' }
Push-Location $root
try {
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        if ($PSCmdlet.ShouldProcess($root,'git init')) { git init | Out-Host }
    }
    if ($PSCmdlet.ShouldProcess($root,"set branch $Branch")) { git branch -M $Branch | Out-Host }
    $remotes=@(git remote)
    if ($remotes -contains 'origin') {
        $current=(git remote get-url origin).Trim()
        if ($current -ne $RemoteUrl -and $PSCmdlet.ShouldProcess('origin',"change remote from $current to $RemoteUrl")) { git remote set-url origin $RemoteUrl | Out-Host }
    } elseif ($PSCmdlet.ShouldProcess('origin',"add remote $RemoteUrl")) { git remote add origin $RemoteUrl | Out-Host }
    if ($PSCmdlet.ShouldProcess($root,'stage repository files')) { git add . | Out-Host }
    $status=git status --porcelain
    if ($status) {
        if ($PSCmdlet.ShouldProcess($root,"commit: $CommitMessage")) { git commit -m $CommitMessage | Out-Host }
    } else { Write-Host 'No uncommitted changes to commit.' }
    if ($PSCmdlet.ShouldProcess("origin/$Branch",'push')) { git push -u origin $Branch | Out-Host }
} finally { Pop-Location }
