# Test for the disk-space check of issue #1 (branch agent/1-disk-space-check), run by hand on
# a Windows PC in a child PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows-disktest.ps1
# Downloads that branch from GitHub into %TEMP%\takwerx-disktest and loads its Windows
# libraries without installing anything. Runs the checks against a fresh takwerx folder in
# %TEMP%, and read-only against the installed takwerx. Prints PASS/FAIL lines and uploads them
# to the Mac on the switch (-Mac host:port, tools/measure-server.py there).
# The red "Error:" lines it prints are expected: some checks are made to stop on purpose.
param([string]$Mac = '192.168.123.99:8000')
$ErrorActionPreference = 'Stop'
$branchZip = 'https://github.com/takwerx-agent/atak-terminal/archive/refs/heads/agent/1-disk-space-check.zip'
$work = Join-Path $env:TEMP 'takwerx-disktest'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script:out = New-Object System.Collections.Generic.List[string]
function Note([string]$m) { Write-Host $m -ForegroundColor Cyan; $script:out.Add($m) }

try {
    Note ("PowerShell " + $PSVersionTable.PSVersion + ", Windows " + [Environment]::OSVersion.Version)
    $zip = Join-Path $work 'branch.zip'
    & curl.exe -fsSL -o $zip $branchZip
    if ($LASTEXITCODE -ne 0) { throw 'could not download the branch from GitHub' }
    $src = Join-Path $work 'src'
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    & tar.exe -xf $zip -C $src --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw 'could not unpack the branch zip' }
    $script:App = $src

    # 1. Every Windows script in the branch parses under this PowerShell.
    $files = @('takwerx.ps1', 'install.ps1')
    foreach ($f in @(Get-ChildItem (Join-Path $src 'lib\windows') -Filter '*.ps1')) { $files += ('lib\windows\' + $f.Name) }
    foreach ($f in $files) {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src $f), [ref]$tokens, [ref]$errs)
        if ($errs.Count -eq 0) { Note "PASS parses: $f" }
        else { Note ("FAIL parse errors in {0}: {1}" -f $f, (($errs | ForEach-Object { $_.Message }) -join '; ')) }
    }

    # 2. A fresh takwerx folder in TEMP: no Android device yet, so the new check applies.
    $env:TAKWERX_ROOT = Join-Path $work 'fresh-root'
    . (Join-Path $src 'lib\windows\common.ps1')
    . (Join-Path $src 'lib\windows\host.ps1')
    . (Join-Path $src 'lib\windows\android.ps1')
    . (Join-Path $src 'lib\windows\emulator.ps1')
    $drive = Get-PSDrive -Name ((Split-Path $AvdHome -Qualifier).TrimEnd(':'))
    $free = $drive.Free / 1GB
    Note ("Free on {0}: {1:N1} GB" -f $drive.Root, $free)
    if (Test-AvdHasData) { Note 'FAIL the fresh folder reports device data' }
    else { Note 'PASS the fresh folder has no device data, so the check applies' }

    $script:AvdDataGB = 10
    $stopped = $null
    try { Test-AvdDiskSpace } catch { $stopped = $_.Exception.Message }
    if ($free -ge 12) {
        if ($stopped) { Note ("FAIL 12 GB needed, {0:N1} GB free, but it stopped: {1}" -f $free, $stopped) }
        else { Note 'PASS enough space for the 10 GB data partition: no stop' }
    } else {
        if ($stopped) { Note ("PASS under 12 GB free, it stops: " + $stopped) }
        else { Note 'FAIL under 12 GB free, but no stop' }
    }

    $script:AvdDataGB = 100000
    $stopped = $null
    try { Test-AvdDiskSpace } catch { $stopped = $_.Exception.Message }
    if (-not $stopped) { Note 'FAIL short of space (100000 GB asked): it did not stop' }
    elseif ($stopped -match "Not enough free disk space for Android's data") { Note ("PASS short of space, it stops with: " + $stopped) }
    else { Note ("FAIL short of space, unexpected error: " + $stopped) }

    # 3. The pre-download check counts the 12 GB for a device without data.
    $need = 1.6 + 5.5 + 12 + 2
    $script:AvdDataGB = 10
    $stopped = $null; $said = ''
    try { $said = (@(Test-EmuHost 6>&1) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -ne 'ok' }) -join ' | ' }
    catch { $stopped = $_.Exception.Message }
    if ($free -ge $need) {
        if ($stopped) { Note ("FAIL pre-download check stopped with {0:N1} GB free: {1}" -f $free, $stopped) }
        else { Note ("PASS pre-download check passes: " + $said) }
    } else {
        if ($stopped) { Note ("PASS pre-download check, under {0} GB free, stops: {1}" -f $need, $stopped) }
        else { Note ("FAIL pre-download check did not stop with {0:N1} GB free" -f $free) }
    }

    $script:AvdDataGB = 100000
    $stopped = $null
    try { Test-EmuHost 6>&1 | Out-Null } catch { $stopped = $_.Exception.Message }
    if (-not $stopped) { Note 'FAIL pre-download check, short of space: it did not stop' }
    elseif ($stopped -match 'Not enough free disk space on') { Note ("PASS pre-download check, short of space, stops with: " + $stopped) }
    else { Note ("FAIL pre-download check, short of space, unexpected error: " + $stopped) }

    # 4. The installed takwerx, read only: a device that has run keeps its data, so it is never stopped.
    Remove-Item Env:TAKWERX_ROOT
    . (Join-Path $src 'lib\windows\common.ps1')
    . (Join-Path $src 'lib\windows\emulator.ps1')
    if (Test-AvdHasData) {
        $script:AvdDataGB = 100000
        $stopped = $null
        try { Test-AvdDiskSpace } catch { $stopped = $_.Exception.Message }
        if ($stopped) { Note ("FAIL your existing device was stopped: " + $stopped) }
        else { Note 'PASS your existing device has data and is never stopped, even when 100000 GB is asked' }
    } else {
        Note 'INFO the installed device has no userdata-qemu.img; its folder holds:'
        foreach ($f in @(Get-ChildItem (Join-Path $AvdHome "$Avd.avd") -ErrorAction SilentlyContinue)) { Note ("  {0}  {1:N0} bytes" -f $f.Name, $f.Length) }
    }
} catch {
    Note ("FAIL the test script itself: " + $_.Exception.Message)
}

$pass = @($script:out | Where-Object { $_ -like 'PASS*' }).Count
$fail = @($script:out | Where-Object { $_ -like 'FAIL*' }).Count
Note ("{0} passed, {1} failed" -f $pass, $fail)
$log = Join-Path $work 'disktest-result.txt'
Set-Content -Path $log -Encoding ASCII -Value $script:out
& curl.exe -fsS -T $log ("http://{0}/upload/disktest-result.txt" -f $Mac)
Write-Host ("upload exit code: {0}" -f $LASTEXITCODE)
