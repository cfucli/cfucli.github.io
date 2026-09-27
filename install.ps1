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
#     versions\<version>\   cfucli.jar, cfucli-app.jar and that release's two launchers
#     runtime\              the Java runtime cfucli runs on
#     bin\                  cfucli.exe and cfucliapp.exe with their .jrc files, on your user PATH
# The launchers are jr (github.com/littlejlib/jr) branded with the cfucli icon: the JVM runs inside
# the named process, and an AOT cache beside the jar makes every start faster. Each release goes
# into its own versions folder and the launchers are repointed, so a jar that is in use is never
# overwritten - Windows cannot overwrite an open file, and a running cfucli holds its jar open. A
# launcher that is running while it is replaced (cfucli update runs FROM cfucli.exe) is renamed
# aside instead, which Windows allows, and swept on a later run. Your settings.toml (the relay
# credentials) is never touched.
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
    # From the profile API, not $env:USERPROFILE: that variable is set at logon and can be missing
    # from an environment rebuilt from the registry, and a null there fails the whole install.
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if (-not $userHome) { $userHome = $env:USERPROFILE }
    $home_   = if ($env:CFUCLI_HOME) { $env:CFUCLI_HOME } else { Join-Path $userHome 'cfucli' }
    $bin     = Join-Path $home_ 'bin'
    $runtime = Join-Path $home_ 'runtime'
    $versions = Join-Path $home_ 'versions'

    function Say($m) { Write-Host "cfucli: $m" }

    # Runs a program with all its output discarded by cmd.exe rather than by PowerShell: under
    # ErrorActionPreference=Stop, Windows PowerShell turns any stderr line from a native program
    # into a terminating error, and redirecting it in PowerShell does not stop that.
    # Start-Process hands the command line over verbatim, where the call operator would re-quote it.
    function Quiet([string]$exe, [string]$arguments) {
        Start-Process -FilePath cmd.exe -ArgumentList "/d /c `"`"$exe`" $arguments >nul 2>&1`"" -Wait -NoNewWindow
    }

    # A flaky connection should cost a retry, not a half-installed tool.
    function Fetch($url, $out) {
        for ($i = 1; $i -le 4; $i++) {
            try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return }
            catch { if ($i -eq 4) { throw "download failed after 4 tries: $url - $($_.Exception.Message)" }; Start-Sleep -Seconds (2 * $i) }
        }
    }

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'cfucli needs 64-bit Windows.' }
    New-Item -ItemType Directory -Force -Path $bin, $versions | Out-Null
    # Launchers renamed aside by an earlier run, because they were running then. Still in use now
    # means they stay for the next run; that is fine, they are not on anyone's PATH under that name.
    Get-ChildItem $bin -Filter '*.old' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $files = @(@('cfucli.jar', 'cfucli.jar'), @('cfucli-app-win.jar', 'cfucli-app.jar'), @('cfucli.exe', 'cfucli.exe'), @('cfucliapp.exe', 'cfucliapp.exe'))
    $newRuntime = $false

    $tmp = Join-Path $home_ ('.download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        Fetch "$release/version.txt" (Join-Path $tmp 'version.txt')
        $version = (Get-Content (Join-Path $tmp 'version.txt') -Raw).Trim()
        if ($version -notmatch '^[0-9A-Za-z._-]+$') { throw "unexpected version string '$version'" }
        $target = Join-Path $versions $version

        if (@($files | Where-Object { -not (Test-Path (Join-Path $target $_[1])) }).Count -eq 0) {
            Say "version $version is already installed - repointing the launchers only"
        } else {
            Say "downloading version $version"
            Fetch "$release/SHA256SUMS" (Join-Path $tmp 'SHA256SUMS')
            foreach ($f in $files) { Fetch "$release/$($f[0])" (Join-Path $tmp $f[1]) }
            $sums = @{}
            foreach ($line in Get-Content (Join-Path $tmp 'SHA256SUMS')) {
                $p = $line -split '\s+', 2
                if ($p.Count -eq 2) { $sums[$p[1].Trim().TrimStart('*')] = $p[0].ToLower() }
            }
            foreach ($f in $files) {
                $want = $sums[$f[0]]
                $got = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $f[1])).Hash.ToLower()
                if (-not $want) { throw "SHA256SUMS has no entry for $($f[0])" }
                if ($want -ne $got) { throw "$($f[0]) failed its checksum - nothing was installed" }
            }
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            foreach ($f in $files) { Move-Item -Force (Join-Path $tmp $f[1]) $target }
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
            $newRuntime = $true
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    # Nodes still running the previous version would keep answering with the old code - measured:
    # a jar replaced under a running node fails later with NoSuchMethodError, not at once.
    $cli = Join-Path $target 'cfucli.jar'
    # Nodes keep their state under the user's own cfucli folder whatever folder the jars were
    # installed into - that is where cfucli itself looks (user.home), not CFUCLI_HOME.
    $state = if ($env:CFUCLI_STATE) { $env:CFUCLI_STATE } else { Join-Path $userHome 'cfucli' }
    $runDir = Join-Path $state 'run'
    if (Test-Path $runDir) {
        foreach ($f in Get-ChildItem $runDir -Filter 'node-*.json') {
            $node = $f.BaseName.Substring(5)
            $nodePid = try { (Get-Content $f.FullName -Raw | ConvertFrom-Json).pid } catch { $null }
            # A port file outlives a node that was killed outright; only a live process is stopped.
            if (-not $nodePid -or -not (Get-Process -Id $nodePid -ErrorAction SilentlyContinue)) { continue }
            Quiet $java "-jar `"$cli`" node stop --node $node"
            Say "stopped node '$node' so it restarts on the new version"
        }
    }

    # An AOT cache is only valid for the JVM that wrote it; a new runtime means every cache is stale.
    if ($newRuntime) { Get-ChildItem $versions -Recurse -Filter '*.aot' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }

    # The launchers. A running exe cannot be overwritten or deleted, but it can be renamed - and
    # `cfucli update` is itself running from bin\cfucli.exe - so a busy one is moved aside to
    # <name>.<ticks>.old, off everyone's PATH, and swept by the next run.
    foreach ($exe in 'cfucli.exe', 'cfucliapp.exe') {
        $dst = Join-Path $bin $exe
        if (Test-Path $dst) {
            try { Remove-Item -Force $dst -ErrorAction Stop }
            catch { Rename-Item $dst "$exe.$([DateTime]::UtcNow.Ticks).old" }
        }
        Copy-Item (Join-Path $target $exe) $dst
    }
    # java.home pins the bundled runtime, so whatever Java is (or is not) on the PATH never matters,
    # and java.autoinstall=false means jr never stops to ask about downloading one. Quoted jar
    # paths, because a user folder can have a space in it. Rewritten on every run; jr reads its
    # .jrc once at start, so a launcher that is running is not disturbed by this.
    $common = @("java.home=$runtime", 'aot=true', 'jvm=dll', 'java.autoinstall=false')
    Set-Content -Encoding ASCII (Join-Path $bin 'cfucli.jrc') (@('# Written by the cfucli installer; rewritten on every install and update.',
        'vm.args=--enable-native-access=ALL-UNNAMED -Xlog:aot*=off -XX:+DisplayVMOutputToStderr',
        "java.args=-jar `"$cli`"") + $common)
    Set-Content -Encoding ASCII (Join-Path $bin 'cfucliapp.jrc') (@('# Written by the cfucli installer; rewritten on every install and update.',
        'vm.args=--enable-native-access=ALL-UNNAMED -Xlog:aot*=off',
        "java.args=-jar `"$(Join-Path $target 'cfucli-app.jar')`"") + $common)
    # The .cmd launchers of 0.2.x, superseded - .exe wins on the PATH anyway, but a stale launcher
    # is a trap for whoever calls it by name. (If this run came from one, cmd.exe may say "The batch
    # file cannot be found" once, as it exits; that is cosmetic.)
    foreach ($old in 'cfucli.cmd', 'cfucliapp.cmd') { Remove-Item -Force (Join-Path $bin $old) -ErrorAction SilentlyContinue }
    Remove-Item -Force (Join-Path $home_ 'cfucli.ico') -ErrorAction SilentlyContinue   # 0.2.x shortcut icon; the exe carries it now

    # Desktop and Start Menu shortcuts to the window, pointing at cfucliapp.exe itself - its own
    # embedded icon, its own process name. Rewritten on every run.
    $app = Join-Path $bin 'cfucliapp.exe'
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

    # Build the AOT cache now rather than on the first real command - it costs a few seconds once.
    # Through cmd, deliberately: the JVM reports its AOT recording on stderr, and in Windows
    # PowerShell with ErrorActionPreference=Stop ANY stderr from a native program is a terminating
    # error, even redirected - measured, it aborted this installer here with the cache half written.
    Quiet (Join-Path $bin 'cfucli.exe') '-V'

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
