<#
.SYNOPSIS
  End-to-end acceptance test of LeakWatch against a running RabbitMQ.

.DESCRIPTION
  Starts three instances on this machine: WS-01 (Mode A), WS-02 (Mode B) and
  WS-03 (Mode A), each with -autostart -runfor=<Minutes>, and checks their
  detector event logs afterwards:
    - every observer has SEEN all three AppIds (the fanout works),
    - WS-02 reached Likely (FINAL maximum level),
    - WS-01 and WS-03 never went above None,
    - every process exited with code 0.
  Prints a pass/fail table and exits non-zero on any failure.
  Windows PowerShell 5.1 compatible.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File test\acceptance.ps1
  powershell -ExecutionPolicy Bypass -File test\acceptance.ps1 -NoBuild -Minutes 25
#>
param(
  [string]$BrokerHost = 'localhost',
  [int]$Port = 15672,
  [string]$User = 'guest',
  [string]$Password = 'guest',
  [string]$VHost = '/',
  [double]$Minutes = 20,
  [int]$Seed = 4711,
  [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'build\LeakWatch.exe'
$instances = @(
  @{ Id = 'WS-01'; Mode = 'A'; Expected = 'None' },
  @{ Id = 'WS-02'; Mode = 'B'; Expected = 'Likely' },
  @{ Id = 'WS-03'; Mode = 'A'; Expected = 'None' }
)

# 1. broker
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Password}"))
try {
  $overview = Invoke-RestMethod -Uri "http://${BrokerHost}:${Port}/api/overview" -Headers @{ Authorization = $auth } -TimeoutSec 5
} catch {
  Write-Host "RabbitMQ management API not reachable at http://${BrokerHost}:${Port}/api/overview ($($_.Exception.Message))."
  Write-Host 'Start the broker (with the management plugin) and run the test again.'
  exit 2
}
Write-Host "RabbitMQ $($overview.rabbitmq_version) at ${BrokerHost}:${Port}"

# 2. build
if (-not $NoBuild) {
  & cmd /c "`"$root\build.cmd`""
  if ($LASTEXITCODE -ne 0) { Write-Host 'build failed'; exit 3 }
}
if (-not (Test-Path $exe)) { Write-Host "$exe not found"; exit 3 }

# 3. run
$out = Join-Path $root ('build\acceptance\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $out | Out-Null
$ini = Join-Path $out 'acceptance.ini'
@"
[Broker]
Host=$BrokerHost
Port=$Port
User=$User
Password=$Password
VHost=$VHost
"@ | Set-Content -Path $ini -Encoding UTF8

$processes = @{}
$i = 0
foreach ($inst in $instances) {
  $log = Join-Path $out "$($inst.Id)-events.log"
  $arguments = @("-id=$($inst.Id)", "-mode=$($inst.Mode)", '-autostart',
    "-runfor=$($Minutes.ToString([Globalization.CultureInfo]::InvariantCulture))",
    "-seed=$($Seed + $i)", "`"-eventlog=$log`"", "`"-ini=$ini`"")
  $processes[$inst.Id] = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
  $i++
}
Write-Host "started WS-01 (A), WS-02 (B), WS-03 (A) for $Minutes min; logs in $out"

$deadline = (Get-Date).AddMinutes($Minutes + 3)
foreach ($id in $processes.Keys) {
  $p = $processes[$id]
  $left = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds)
  if (-not $p.WaitForExit($left * 1000)) {
    Write-Host "$id did not exit in time, killing it"
    $p.Kill()
    $p.WaitForExit()
  }
}

# 4. check
$results = @()
$failed = $false
foreach ($observer in $instances) {
  $log = Join-Path $out "$($observer.Id)-events.log"
  $exitCode = $processes[$observer.Id].ExitCode
  if ($exitCode -ne 0) { $failed = $true }
  $lines = @()
  if (Test-Path $log) { $lines = Get-Content -Path $log -Encoding UTF8 | ForEach-Object { , ($_ -split "`t") } }
  foreach ($subject in $instances) {
    $seen = @($lines | Where-Object { $_[0] -eq 'SEEN' -and $_[4] -eq $subject.Id }).Count -gt 0
    $final = @($lines | Where-Object { $_[0] -eq 'FINAL' -and $_[4] -eq $subject.Id })
    $maxLevel = 'missing'
    $samples = 0
    if ($final.Count -gt 0) {
      $maxLevel = $final[-1][8]
      $samples = [int]$final[-1][6]
    }
    $ok = $seen -and ($maxLevel -eq $subject.Expected) -and ($exitCode -eq 0)
    if (-not $ok) { $failed = $true }
    $results += [pscustomobject]@{
      Observer = $observer.Id
      Subject  = $subject.Id
      Seen     = $seen
      Samples  = $samples
      MaxLevel = $maxLevel
      Expected = $subject.Expected
      ExitCode = $exitCode
      Result   = $(if ($ok) { 'PASS' } else { 'FAIL' })
    }
  }
}
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Host 'Level changes:'
foreach ($observer in $instances) {
  $log = Join-Path $out "$($observer.Id)-events.log"
  if (Test-Path $log) {
    Get-Content -Path $log -Encoding UTF8 | Where-Object { $_ -like 'LEVEL*' } | ForEach-Object { Write-Host "  $_" }
  }
}

if ($failed) {
  Write-Host 'ACCEPTANCE TEST FAILED'
  exit 1
}
Write-Host 'ACCEPTANCE TEST PASSED'
exit 0
