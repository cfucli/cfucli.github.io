# cfucli installer for Windows. Install and update are the same command:
#
#     irm https://cfucli.github.io/install.ps1 | iex
#
# From a cmd.exe window rather than PowerShell:
#
#     powershell -c "irm https://cfucli.github.io/install.ps1 | iex"
#
# No administrator rights, and nothing needs to be installed first - a private Java runtime is
# fetched into the cfucli folder if one is not already there. Everything lives under
# %USERPROFILE%\cfucli:
#     versions\<version>\   cfucli.jar and cfucli-app.jar for that release
#     runtime\              the Java runtime cfucli runs on
#     bin\                  cfucli.cmd and cfucliapp.cmd, added to your user PATH
# Each release goes into its own versions folder and the launchers are repointed, so a jar that is
# in use is never overwritten - Windows cannot overwrite an open file, and a running cfucli holds
# its jar open. Your settings.toml (the relay credentials) is never touched.
#
# This is ONE script on purpose: it runs through Invoke-Expression, which execution policy does not
# apply to, and launching any other .ps1 from here would be subject to that policy again.
#
# CFUCLI_HOME overrides the folder, which is how this script is tested without touching a real
# install. CFUCLI_NO_PATH=1 leaves the user PATH alone. CFUCLI_RELEASE points at a different
# release folder (a local test server) instead of the latest GitHub release.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest many times slower
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $release = if ($env:CFUCLI_RELEASE) { $env:CFUCLI_RELEASE } else { 'https://github.com/cfucli/cfucli/releases/latest/download' }
    $jre     = 'https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jre/hotspot/normal/eclipse'
    $home_   = if ($env:CFUCLI_HOME) { $env:CFUCLI_HOME } else { Join-Path $env:USERPROFILE 'cfucli' }
    $bin     = Join-Path $home_ 'bin'
    $runtime = Join-Path $home_ 'runtime'
    $versions = Join-Path $home_ 'versions'

    function Say($m) { Write-Host "cfucli: $m" }

    # A flaky connection should cost a retry, not a half-installed tool.
    function Fetch($url, $out) {
        for ($i = 1; $i -le 4; $i++) {
            try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return }
            catch { if ($i -eq 4) { throw "download failed after 4 tries: $url - $($_.Exception.Message)" }; Start-Sleep -Seconds (2 * $i) }
        }
    }

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'cfucli needs 64-bit Windows.' }
    New-Item -ItemType Directory -Force -Path $bin, $versions | Out-Null

    $tmp = Join-Path $home_ ('.download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        Fetch "$release/version.txt" (Join-Path $tmp 'version.txt')
        $version = (Get-Content (Join-Path $tmp 'version.txt') -Raw).Trim()
        if ($version -notmatch '^[0-9A-Za-z._-]+$') { throw "unexpected version string '$version'" }
        $target = Join-Path $versions $version

        if (Test-Path (Join-Path $target 'cfucli.jar')) {
            Say "version $version is already installed - repointing the launchers only"
        } else {
            Say "downloading version $version"
            Fetch "$release/SHA256SUMS" (Join-Path $tmp 'SHA256SUMS')
            Fetch "$release/cfucli.jar" (Join-Path $tmp 'cfucli.jar')
            Fetch "$release/cfucli-app-win.jar" (Join-Path $tmp 'cfucli-app.jar')
            $sums = @{}
            foreach ($line in Get-Content (Join-Path $tmp 'SHA256SUMS')) {
                $p = $line -split '\s+', 2
                if ($p.Count -eq 2) { $sums[$p[1].Trim().TrimStart('*')] = $p[0].ToLower() }
            }
            foreach ($pair in @(@('cfucli.jar', 'cfucli.jar'), @('cfucli-app-win.jar', 'cfucli-app.jar'))) {
                $want = $sums[$pair[0]]
                $got = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $pair[1])).Hash.ToLower()
                if (-not $want) { throw "SHA256SUMS has no entry for $($pair[0])" }
                if ($want -ne $got) { throw "$($pair[0]) failed its checksum - nothing was installed" }
            }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Move-Item (Join-Path $tmp 'cfucli.jar'), (Join-Path $tmp 'cfucli-app.jar') $target
            Copy-Item (Join-Path $tmp 'version.txt') $target
            Say "verified and unpacked into $target"
        }

        $java = Join-Path $runtime 'bin\java.exe'
        if (-not (Test-Path $java)) {
            Say 'downloading a Java 25 runtime (once; about 50 MB)'
            $zip = Join-Path $tmp 'jre.zip'
            Fetch $jre $zip
            $unz = Join-Path $tmp 'jre'
            Expand-Archive -Path $zip -DestinationPath $unz -Force
            $root = Get-ChildItem $unz -Directory | Select-Object -First 1
            if (-not $root -or -not (Test-Path (Join-Path $root.FullName 'bin\java.exe'))) { throw 'the Java runtime archive did not contain bin\java.exe' }
            if (Test-Path $runtime) { Remove-Item -Recurse -Force $runtime }
            Move-Item $root.FullName $runtime
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    # Nodes still running the previous version would keep answering with the old code - measured:
    # a jar replaced under a running node fails later with NoSuchMethodError, not at once.
    $cli = Join-Path $target 'cfucli.jar'
    # Nodes keep their state under the user's own cfucli folder whatever folder the jars were
    # installed into - that is where cfucli itself looks (user.home), not CFUCLI_HOME.
    $state = if ($env:CFUCLI_STATE) { $env:CFUCLI_STATE } else { Join-Path $env:USERPROFILE 'cfucli' }
    $runDir = Join-Path $state 'run'
    if (Test-Path $runDir) {
        foreach ($f in Get-ChildItem $runDir -Filter 'node-*.json') {
            $node = $f.BaseName.Substring(5)
            $nodePid = try { (Get-Content $f.FullName -Raw | ConvertFrom-Json).pid } catch { $null }
            # A port file outlives a node that was killed outright; only a live process is stopped.
            if (-not $nodePid -or -not (Get-Process -Id $nodePid -ErrorAction SilentlyContinue)) { continue }
            & $java -jar $cli node stop --node $node 2>$null | Out-Null
            Say "stopped node '$node' so it restarts on the new version"
        }
    }

    $vm = '--enable-native-access=ALL-UNNAMED -Xlog:aot*=off -XX:+DisplayVMOutputToStderr'
    $javaw = Join-Path $runtime 'bin\javaw.exe'
    Set-Content -Encoding ASCII (Join-Path $bin 'cfucli.cmd') "@`"$java`" $vm -jar `"$cli`" %*"
    # javaw and start: the window must not drag a console window along behind it.
    Set-Content -Encoding ASCII (Join-Path $bin 'cfucliapp.cmd') "@start `"`" `"$javaw`" --enable-native-access=ALL-UNNAMED -jar `"$(Join-Path $target 'cfucli-app.jar')`" %*"

    # Desktop and Start Menu shortcuts to the window. Rewritten on every run, so they always open
    # the version just installed. The icon is fetched from the site; without it the shortcut still
    # works, with Java's icon, so a failed fetch is not a failed install.
    $appJar = Join-Path $target 'cfucli-app.jar'
    $ico = Join-Path $home_ 'cfucli.ico'
    if (-not (Test-Path $ico)) { try { Fetch 'https://cfucli.github.io/assets/cfucli-favicon.ico' $ico } catch { } }
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'cfucli'))
    if ($env:CFUCLI_NO_PATH -eq '1') { $places = @((Join-Path $home_ 'shortcuts')) }   # tests leave the real desktop alone
    foreach ($dir in $places) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lnk = $shell.CreateShortcut((Join-Path $dir 'cfucli.lnk'))
        $lnk.TargetPath = $javaw
        $lnk.Arguments = "--enable-native-access=ALL-UNNAMED -jar `"$appJar`""
        $lnk.WorkingDirectory = $home_
        $lnk.Description = 'cfucli - share a shell, or join one'
        if (Test-Path $ico) { $lnk.IconLocation = $ico }
        $lnk.Save()
    }
    Say "shortcut on the desktop and in the Start Menu"

    if ($env:CFUCLI_NO_PATH -ne '1') {
        # FIRST in the user PATH, so this install wins over an older copy - a v0.1 zip folder, say -
        # without deleting anything. Nothing this script did not create is ever removed or edited:
        # an old install is indistinguishable by its files from a folder of other tools that also
        # happens to hold a cfucli.exe, and deleting that would break every tool in it.
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $rest = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin })
        [Environment]::SetEnvironmentVariable('Path', ((@($bin) + $rest) -join ';'), 'User')
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

    # Keep the current version and the one before it; anything older goes, unless it is in use.
    Get-ChildItem $versions -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

    Say "installed $version"
    Write-Host ''
    Write-Host '  First time on this machine? Two things, once:'
    Write-Host '    cfucli relay set --from <the relay file you were sent>'
    Write-Host '    cfucli available on --as <your name>'
    Write-Host ''
    Write-Host '  To update later, run the same install line again, or:  cfucli update'
}
