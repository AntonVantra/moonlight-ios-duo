[CmdletBinding()]
param(
    [switch]$Disable,
    [ValidatePattern('^\{[0-9a-fA-F-]{36}\}$')]
    [string]$DisplayId
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from administrator PowerShell to update Sunshine.'
}

$install = Join-Path $env:ProgramFiles 'SunshineDuo\Sunshine'
$service = Get-CimInstance Win32_Service -Filter "Name = 'SunshineService'"
if (!$service -or $service.PathName.Trim('"') -ne (Join-Path $install 'tools\sunshinesvc.exe')) {
    throw 'The running service is not the Sunshine Duo installation.'
}

$config = Join-Path $install 'config\sunshine.conf'
$log = Join-Path $install 'config\sunshine.log'
$lastSessionEvent = Get-Content -LiteralPath $log -Tail 400 |
    Select-String 'CLIENT (CONNECTED|DISCONNECTED)' | Select-Object -Last 1
if ($lastSessionEvent -and $lastSessionEvent.Line -match 'CLIENT CONNECTED') {
    throw 'Disconnect the active desktop stream before restarting Sunshine.'
}

$original = Get-Content -LiteralPath $config -Raw
$options = @{
    dd_configuration_option = if ($Disable) { 'disabled' } else { 'verify_only' }
    dd_resolution_option = 'auto'
    dd_refresh_rate_option = 'disabled'
    dd_hdr_option = 'disabled'
    dd_config_revert_on_disconnect = 'enabled'
}
if ($DisplayId) { $options.output_name = $DisplayId }
$updated = $original
foreach ($key in $options.Keys) {
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=.*$'
    $line = "$key = $($options[$key])"
    if ($updated -match $pattern) {
        $updated = $updated -replace $pattern, $line
    } else {
        $updated = $updated.TrimEnd() + [Environment]::NewLine + $line + [Environment]::NewLine
    }
}
if ($updated -eq $original) { return }

$backup = "$config.before-display-match"
if (!(Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $config -Destination $backup }
try {
    Set-Content -LiteralPath $config -Value $updated -Encoding ASCII
    Restart-Service -Name SunshineService
} catch {
    Set-Content -LiteralPath $config -Value $original -Encoding ASCII
    Start-Service -Name SunshineService
    throw
}
