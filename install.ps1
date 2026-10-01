# cfucli installer for Windows. Install and update are the same command:
#
#     irm https://cfucli.github.io/install.ps1 | iex
#
# From a cmd.exe window rather than PowerShell:
#
#     powershell -c "irm https://cfucli.github.io/install.ps1 | iex"
#
# No administrator rights, and nothing needs to be installed first. Since 0.4 cfucli.exe is ONE
# single file (jr, github.com/jarrunner/jr, built with its config baked in) that is both the
# command line and, run with no arguments, the window: on first run it fetches its jar from the
# GitHub release it was built for, checked against the sha256 it carries, and a Java runtime if
# none is found. So this script only puts that exe in %USERPROFILE%\cfucli\bin, puts that folder on
# your user PATH, adds shortcuts, and warms it up. A launcher that is running while it is replaced
# (cfucli update runs FROM cfucli.exe) is renamed aside instead, which Windows allows, and swept on
# a later run. The cfucliapp.exe of 0.3 is removed the same way. Your settings.toml (the relay
# credentials) is never touched.
#
# Updating later: run this line again, `cfucli update`, or `cfucli -Xjr:update` (replaces just
# that exe from https://cfucli.github.io/update/cfucli.json).
#
# This is ONE script on purpose: it runs through Invoke-Expression, which execution policy does not
# apply to, and launching any other .ps1 from here would be subject to that policy again.
#
# CFUCLI_HOME overrides the folder, which is how this script is tested without touching a real
# install. CFUCLI_NO_PATH=1 leaves the user PATH alone. CFUCLI_RELEASE points at a different
# release folder (a local test server) instead of the latest GitHub release. CFUCLI_EXE installs that
# local cfucli.exe instead of downloading one - "cfucli install" sets it, which is how an exe that
# was downloaded and double-clicked installs itself (the window offers it on F6).

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $release = if ($env:CFUCLI_RELEASE) { $env:CFUCLI_RELEASE } else { 'https://github.com/cfucli/cfucli/releases/latest/download' }
    # From the profile API, not $env:USERPROFILE: that variable is set at logon and can be missing
    # from an environment rebuilt from the registry, and a null there fails the whole install.
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if (-not $userHome) { $userHome = $env:USERPROFILE }
    $home_   = if ($env:CFUCLI_HOME) { $env:CFUCLI_HOME } else { Join-Path $userHome 'cfucli' }
    $bin     = Join-Path $home_ 'bin'

    function Say($m) { Write-Host "cfucli: $m" }

    # Runs a program with all its output discarded by cmd.exe rather than by PowerShell: under
    # ErrorActionPreference=Stop, Windows PowerShell turns any stderr line from a native program
    # into a terminating error, and redirecting it in PowerShell does not stop that.
    # Start-Process hands the command line over verbatim, where the call operator would re-quote it.
    function Quiet([string]$exe, [string]$arguments) {
        Start-Process -FilePath cmd.exe -ArgumentList "/d /c `"`"$exe`" $arguments <nul >nul 2>&1`"" -Wait -NoNewWindow
    }

    # A flaky connection should cost a retry, not a half-installed tool.
    function Fetch($url, $out) {
        for ($i = 1; $i -le 4; $i++) {
            try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return }
            catch { if ($i -eq 4) { throw "download failed after 4 tries: $url - $($_.Exception.Message)" }; Start-Sleep -Seconds (2 * $i) }
        }
    }

    # A folder is only deleted when nothing in it is in use: renaming fails if any file inside is
    # open, so a rename that succeeds means the delete cannot leave a running program half removed.
    function RemoveIfUnused($dir) {
        if (-not (Test-Path $dir)) { return }
        $aside = "$dir.removing-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        try { Rename-Item $dir $aside -ErrorAction Stop } catch { return }
        Remove-Item -Recurse -Force $aside -ErrorAction SilentlyContinue
    }

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'cfucli needs 64-bit Windows.' }
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    # Launchers renamed aside by an earlier run, because they were running then. Still in use now
    # means they stay for the next run; that is fine, they are not on anyone's PATH under that name.
    Get-ChildItem $bin -Filter '*.old' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $exes = @('cfucli.exe')

    $tmp = Join-Path $home_ ('.download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        if ($env:CFUCLI_EXE) {
            # "cfucli install": the exe someone downloaded and double-clicked installs itself, so
            # there is nothing to download. Its jar is checked by the exe itself, against the
            # sha256 it carries, the first time it runs.
            if (-not (Test-Path $env:CFUCLI_EXE)) { throw "CFUCLI_EXE names $env:CFUCLI_EXE, which does not exist" }
            $version = 'this exe'
            Say "installing $env:CFUCLI_EXE"
            Copy-Item $env:CFUCLI_EXE (Join-Path $tmp 'cfucli.exe')
        } else {
        Fetch "$release/version.txt" (Join-Path $tmp 'version.txt')
        $version = (Get-Content (Join-Path $tmp 'version.txt') -Raw).Trim()
        if ($version -notmatch '^[0-9A-Za-z._-]+$') { throw "unexpected version string '$version'" }
        Say "downloading version $version"
        Fetch "$release/SHA256SUMS" (Join-Path $tmp 'SHA256SUMS')
        foreach ($f in $exes) { Fetch "$release/$f" (Join-Path $tmp $f) }
        $sums = @{}
        foreach ($line in Get-Content (Join-Path $tmp 'SHA256SUMS')) {
            $p = $line -split '\s+', 2
            if ($p.Count -eq 2) { $sums[$p[1].Trim().TrimStart('*')] = $p[0].ToLower() }
        }
        foreach ($f in $exes) {
            $want = $sums[$f]
            $got = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $f)).Hash.ToLower()
            if (-not $want) { throw "SHA256SUMS has no entry for $f" }
            if ($want -ne $got) { throw "$f failed its checksum - nothing was installed" }
        }
        }

        # A running exe cannot be overwritten or deleted, but it can be renamed - and `cfucli update`
        # is itself running from bin\cfucli.exe - so a busy one is moved aside to <name>.<ticks>.old,
        # off everyone's PATH, and swept by the next run.
        foreach ($exe in $exes) {
            $dst = Join-Path $bin $exe
            if (Test-Path $dst) {
                try { Remove-Item -Force $dst -ErrorAction Stop }
                catch { Rename-Item $dst "$exe.$([DateTime]::UtcNow.Ticks).old" }
            }
            Move-Item (Join-Path $tmp $exe) $dst
        }
        # The window's own exe until 0.3; cfucli.exe with no arguments is the window now. Removed,
        # or moved aside the same way if it is running (a window or the tray from the old install).
        $oldApp = Join-Path $bin 'cfucliapp.exe'
        if (Test-Path $oldApp) {
            try { Remove-Item -Force $oldApp -ErrorAction Stop }
            catch { Rename-Item $oldApp "cfucliapp.exe.$([DateTime]::UtcNow.Ticks).old" }
            Say 'removed cfucliapp.exe - cfucli.exe opens the window now'
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    $cli = Join-Path $bin 'cfucli.exe'
    Say "verified and installed into $bin"

    # Warm up now rather than on the first real command: the exe fetches its jar (about 87 MB) and
    # a Java runtime if there is none (once, about 50 MB). -Xjr:yes so jr does not stop to ask
    # about the runtime; stdin from nul so nothing can wait on a prompt. -Xjr:aot=false so this
    # trivial run does not become the AOT training run: the one jar serves the cli and the window,
    # and a cache trained by printing a version carries neither, so the first real use trains it.
    # Through cmd, deliberately: in Windows PowerShell with ErrorActionPreference=Stop ANY stderr
    # from a native program is a terminating error, even redirected.
    Say 'fetching the cfucli jar (and a Java runtime if needed) - a minute on first install'
    Quiet $cli '-Xjr:yes -Xjr:aot=false -V'

    # Nodes still running the previous version would keep answering with the old code - measured:
    # a jar replaced under a running node fails later with NoSuchMethodError, not at once.
    # Nodes keep their state under the user's own cfucli folder whatever folder the exes were
    # installed into - that is where cfucli itself looks (user.home), not CFUCLI_HOME.
    $state = if ($env:CFUCLI_STATE) { $env:CFUCLI_STATE } else { Join-Path $userHome 'cfucli' }
    $runDir = Join-Path $state 'run'
    if (Test-Path $runDir) {
        foreach ($f in Get-ChildItem $runDir -Filter 'node-*.json') {
            $node = $f.BaseName.Substring(5)
            $nodePid = try { (Get-Content $f.FullName -Raw | ConvertFrom-Json).pid } catch { $null }
            # A port file outlives a node that was killed outright; only a live process is stopped.
            if (-not $nodePid -or -not (Get-Process -Id $nodePid -ErrorAction SilentlyContinue)) { continue }
            Quiet $cli "node stop --node $node"
            Say "stopped node '$node' so it restarts on the new version"
        }
    }

    # What installs before 0.4 left here: .jrc files (the exes now ignore any config beside them),
    # per-version jar folders and a private runtime (the exes keep their own jar and Java now).
    # Removed only where nothing is still using them; a later run finishes the job.
    Get-ChildItem $bin -Filter '*.jrc' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    RemoveIfUnused (Join-Path $home_ 'versions')
    RemoveIfUnused (Join-Path $home_ 'runtime')
    # The .cmd launchers of 0.2.x, superseded - .exe wins on the PATH anyway, but a stale launcher
    # is a trap for whoever calls it by name. (If this run came from one, cmd.exe may say "The batch
    # file cannot be found" once, as it exits; that is cosmetic.)
    foreach ($old in 'cfucli.cmd', 'cfucliapp.cmd') { Remove-Item -Force (Join-Path $bin $old) -ErrorAction SilentlyContinue }
    Remove-Item -Force (Join-Path $home_ 'cfucli.ico') -ErrorAction SilentlyContinue   # 0.2.x shortcut icon; the exe carries it now

    # Desktop and Start Menu shortcuts to the window: cfucli.exe with no arguments, its own embedded
    # icon, its own process name. Rewritten on every run, which is also what repoints the shortcuts
    # an older install aimed at cfucliapp.exe.
    $app = $cli
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'cfucli'))
    if ($env:CFUCLI_NO_PATH -eq '1') { $places = @((Join-Path $home_ 'shortcuts')) }   # tests leave the real desktop alone
    foreach ($dir in $places) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lnk = $shell.CreateShortcut((Join-Path $dir 'cfucli.lnk'))
        $lnk.TargetPath = $app
        $lnk.Arguments = ''
        $lnk.WorkingDirectory = $home_
        $lnk.Description = 'cfucli - share a shell, or join one'
        $lnk.IconLocation = "$app,0"
        $lnk.Save()
    }
    Say "shortcut on the desktop and in the Start Menu"

    if ($env:CFUCLI_NO_PATH -ne '1') {
        # FIRST in the user PATH, so this install wins over an older copy - a v0.1 zip folder, say -
        # without deleting anything. Nothing this script did not create is ever removed or edited:
        # an old install is indistinguishable by its files from a folder of other tools that also
        # happens to hold a cfucli.exe, and deleting that would break every tool in it.
        # Raw, and written back with its own registry type. [Environment]::GetEnvironmentVariable
        # returns the user PATH with %VARIABLES% already expanded, and SetEnvironmentVariable writes
        # it back as a plain string - so every %USERPROFILE%-style entry would be flattened, or,
        # where the variable is not set, turned into a literal that never resolves again.
        $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        $userPath = [string]$envKey.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $kind = if ($envKey.GetValueNames() -contains 'Path') { $envKey.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $rest = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin })
        $envKey.SetValue('Path', ((@($bin) + $rest) -join ';'), $kind)
        $envKey.Close()
        # A registry write alone is not announced, and Explorer would hand new terminals the old
        # PATH until the next sign-in. Setting (then removing) a user variable through .NET sends
        # the WM_SETTINGCHANGE broadcast that makes it re-read the environment.
        [Environment]::SetEnvironmentVariable('CFUCLI_PATH_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('CFUCLI_PATH_REFRESH', $null, 'User')
        # This script runs inside the caller's own session, so it can fix that session too.
        $env:Path = (@($bin) + @($env:Path -split ';' | Where-Object { $_ -and $_ -ne $bin })) -join ';'
        Say "$bin is first on your PATH"

        # Then ask which cfucli a new window will actually run, and say so if it is not this one.
        $found = @(Get-Command cfucli -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
        $others = @($found | Where-Object { -not $_.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) })
        if ($found.Count -gt 0 -and -not $found[0].StartsWith($bin, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host ''
            Write-Host "  NOTE: 'cfucli' still runs $($found[0]) - it is on the system PATH, ahead of every user entry."
            Write-Host '  Remove that folder from the system PATH (or delete it if it is an old cfucli) to use this install.'
        } elseif ($others.Count -gt 0) {
            Write-Host ''
            Write-Host '  Other copies of cfucli on your PATH, now shadowed by this one (safe to delete if they are old installs):'
            $others | ForEach-Object { Write-Host "    $_" }
        }
    }

    Say "installed $version"
    Write-Host ''
    Write-Host '  First time on this machine? Two things, once:'
    Write-Host '    cfucli relay set --from <the relay file you were sent>'
    Write-Host '    cfucli available on --as <your name>'
    Write-Host ''
    Write-Host '  To update later, run the same install line again, or:  cfucli update'
}
