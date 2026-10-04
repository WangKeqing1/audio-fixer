$ErrorActionPreference = 'Stop'
$folder = (Resolve-Path 'build/windows/x64/runner/Release').Path
$exe = Join-Path $folder 'audio_fixer.exe'
if (-not (Test-Path $exe)) { throw 'Release executable missing' }
$process = Start-Process -FilePath $exe -WorkingDirectory $folder -PassThru
try {
  $deadline = (Get-Date).AddSeconds(45)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    if ($process.HasExited) { throw "Release app exited early: $($process.ExitCode)" }
    if ($process.MainWindowHandle -ne 0) { $ready = $true; break }
  }
  if (-not $ready) { throw 'Release app did not produce a Windows window' }
  Start-Sleep -Seconds 3
  $process.Refresh()
  if ($process.HasExited) { throw 'Release app crashed after its first window' }
  @{
    started = $true
    windowTitle = $process.MainWindowTitle
    architecture = 'x64'
    verification = 'Real release executable stayed alive and created a native window; separate integration tests exercise services and UI.'
    signed = $false
  } | ConvertTo-Json | Set-Content 'build/ci/windows/release-smoke.json'
} finally {
  $process.Refresh()
  if (-not $process.HasExited) {
    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) { $process.Kill() }
  }
}
