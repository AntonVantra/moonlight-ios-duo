[CmdletBinding()]
param(
    [string]$StagingDirectory = (Join-Path $env:LOCALAPPDATA 'MoonlightDuo'),
    [ValidateRange(0, 30)]
    [int]$WaitForSignInMinutes = 10
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from administrator PowerShell. Tailscale installs a Windows network adapter.'
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This setup uses the verified Windows AMD64 releases.'
}

$install = Join-Path $env:ProgramFiles 'SunshineDuo'
$sunshine = Join-Path $install 'Sunshine'
$config = Join-Path $sunshine 'config\sunshine.conf'
$serviceExecutable = Join-Path $sunshine 'tools\sunshinesvc.exe'
$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$serviceName = 'SunshineService'
$existing = Get-CimInstance Win32_Service -Filter "Name = '$serviceName' OR Name = 'SunshineSvc'"
if ($existing -and ($existing.Name -ne $serviceName -or $existing.PathName.Trim('"') -ne $serviceExecutable)) {
    throw 'This PC has another Sunshine service. Its installation and settings were preserved.'
}

New-Item -ItemType Directory -Path $install -Force | Out-Null
Start-Transcript -Path (Join-Path $install 'setup.log') -Append | Out-Null
try {
    if (!(Test-Path -LiteralPath $tailscale)) {
        $msiName = 'tailscale-setup-1.104.7-amd64.msi'
        $msi = Join-Path $install $msiName
        Copy-Item -LiteralPath (Join-Path $StagingDirectory "downloads\$msiName") -Destination $msi
        $signature = Get-AuthenticodeSignature -FilePath $msi
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Tailscale Inc\.' -or
            (Get-FileHash -LiteralPath $msi).Hash -ne '676B5B32FDD1AEAEE90D8E8F38E222635B216FBDFBF877BF01CB1D7CDA330EC5') {
            throw 'Tailscale installer verification failed.'
        }
        $msiArgs = '/i "{0}" /qn /norestart TS_NOLAUNCH=1 TS_UNATTENDEDMODE=always' -f $msi
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $msiArgs -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) { throw "Tailscale installer exited with code $($process.ExitCode)." }
        if ($process.ExitCode -eq 3010) { Write-Output 'Tailscale requested a reboot. Finish sign-in after rebooting at a convenient time.' }
    }

    if (!$existing) {
        $zipName = 'Sunshine-Windows-AMD64-lite.zip'
        $zip = Join-Path $install $zipName
        Copy-Item -LiteralPath (Join-Path $StagingDirectory "downloads\$zipName") -Destination $zip
        if ((Get-FileHash -LiteralPath $zip).Hash -ne '233008E46F4C0E501A586CBFD6C4FD4A4C0D414A0B5FC7F13C070EB92EC3824B') {
            throw 'Sunshine release verification failed.'
        }
        if (!(Test-Path -LiteralPath $serviceExecutable)) { Expand-Archive -LiteralPath $zip -DestinationPath $install -Force }
        $portable = Join-Path $StagingDirectory 'Sunshine\Sunshine\sunshine.exe'
        $runningSunshine = Get-CimInstance Win32_Process -Filter "Name = 'sunshine.exe'"
        if ($runningSunshine | Where-Object ExecutablePath -ne $portable) {
            throw 'An unrelated Sunshine process is using the host ports.'
        }
        $runningSunshine | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction Stop }

        if (!(Test-Path -LiteralPath $config)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force | Out-Null
            @'
bind_address = 127.0.0.1
address_family = ipv4
origin_web_ui_allowed = pc
upnp = off
lan_encryption_mode = 2
wan_encryption_mode = 2
encoder = nvenc
capture = ddx
nvenc_preset = 1
dd_configuration_option = disabled
'@ | Set-Content -LiteralPath $config -Encoding ASCII
        }
        # The upstream Windows service works without the installer's unrestricted firewall rules.
        New-Service -Name $serviceName -BinaryPathName ('"{0}"' -f $serviceExecutable) -DisplayName 'Sunshine Service' -StartupType Automatic | Out-Null
    }
    Start-Service -Name $serviceName
    Write-Output 'Sunshine is configured to start with Windows.'
    Write-Output 'Create your Sunshine login at https://127.0.0.1:47990 if prompted.'
    Write-Output 'Sign in to Tailscale on this PC. Setup will wait for both sign-ins before switching to the tailnet.'

    $deadline = (Get-Date).AddMinutes($WaitForSignInMinutes)
    do {
        $currentConfig = Get-Content -LiteralPath $config -Raw
        if ($currentConfig -match '(?m)^bind_address[ \t]*=[ \t]*100\.') {
            Write-Output 'Sunshine already has a tailnet binding.'
            return
        }
        $tailStatus = & $tailscale status --json --peers=false | ConvertFrom-Json
        $tailIp = $tailStatus.TailscaleIPs | Where-Object { $_ -match '^100\.' } | Select-Object -First 1
        $localHttp = & "$env:SystemRoot\System32\curl.exe" --silent --insecure --max-time 2 -o NUL -w '%{http_code}' 'https://127.0.0.1:47990/'
        if ($tailStatus.BackendState -eq 'Running' -and
            $tailIp -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$' -and $localHttp -eq '401') { break }
        if ((Get-Date) -ge $deadline) {
            Write-Output 'Sunshine remains on localhost. After both sign-ins, rerun this setup to enable the tailnet binding.'
            return
        }
        Start-Sleep -Seconds 3
    } while ($true)

    $tailInterface = Get-NetIPAddress -IPAddress $tailIp -AddressFamily IPv4
    if ($tailInterface.InterfaceAlias -notlike 'Tailscale*') { throw 'The address does not belong to the Tailscale adapter.' }
    if (Get-NetIPInterface -AddressFamily IPv4 | Where-Object {
        $_.ConnectionState -eq 'Connected' -and $_.InterfaceIndex -ne $tailInterface.InterfaceIndex -and $_.WeakHostReceive -eq 'Enabled'
    }) {
        throw 'A connected interface accepts packets for addresses on other interfaces. Sunshine remains on localhost.'
    }
    & $tailscale set --unattended=true
    if ($LASTEXITCODE -ne 0) { throw 'Tailscale could not enable unattended mode.' }

    $tailConfig = $currentConfig -replace '(?m)^bind_address[ \t]*=.*$', "bind_address = $tailIp"
    $tailConfig = $tailConfig -replace '(?m)^origin_web_ui_allowed[ \t]*=.*$', 'origin_web_ui_allowed = wan'
    $uiUrl = 'https://{0}:47990' -f $tailIp
    $tailConfig += [Environment]::NewLine + "csrf_allowed_origins = $uiUrl" + [Environment]::NewLine

    # The Web UI uses the same Tailscale-only listener and requires the local
    # Sunshine credentials before pairing can be approved.
    try {
        Set-Content -LiteralPath $config -Value $tailConfig -Encoding ASCII
        Restart-Service -Name $serviceName
        $listen = $null
        for ($attempt = 0; $attempt -lt 55 -and !$listen; $attempt++) {
            Start-Sleep -Seconds 1
            $listen = Get-NetTCPConnection -LocalAddress $tailIp -LocalPort 47989 -State Listen -ErrorAction SilentlyContinue
        }
        if (!$listen) { throw 'Sunshine did not start on the Tailscale address.' }
        $listenerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($listen.OwningProcess)"
        if ($listenerProcess.ExecutablePath -ne (Join-Path $sunshine 'sunshine.exe')) {
            throw 'The listener on the Tailscale address is not the expected Sunshine process.'
        }
    } catch {
        Write-Output "Restoring localhost after private-listener check failed. $($_.Exception.Message)"
        Set-Content -LiteralPath $config -Value $currentConfig -Encoding ASCII
        Restart-Service -Name $serviceName
        throw
    }
    Write-Output "Add $tailIp in Moonlight. Open $uiUrl on this PC to enter the Moonlight PIN."
} finally {
    Stop-Transcript | Out-Null
}
