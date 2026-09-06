#Requires -RunAsAdministrator
$ErrorActionPreference='Stop'
$dest='C:\ProgramData\ZabbixPrintLab'
$serviceName='Zabbix Agent 2 [print-server-windows]'
New-Item -ItemType Directory -Force $dest | Out-Null
Start-Transcript -Path "$dest\install.log" -Append
try {
    $service=Get-Service | Where-Object Name -eq $serviceName
    if ($service) { $service | Stop-Service }
    if (Get-ScheduledTask -TaskName ZabbixPrintLabCollector -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName ZabbixPrintLabCollector }
    Copy-Item "$PSScriptRoot\collect.py","$PSScriptRoot\config.json" $dest -Force
    Copy-Item "$PSScriptRoot\runtime\agent\bin\zabbix_agent2.exe" $dest -Force
    Copy-Item "$PSScriptRoot\runtime\agent\bin\zabbix_sender.exe" $dest -Force
    $pythonSource=Get-Content "$PSScriptRoot\runtime\python-source.txt" -Raw
    $pythonSource=$pythonSource.Trim()
    if (-not (Test-Path "$dest\python\python.exe")) {
        New-Item -ItemType Directory -Force "$dest\python" | Out-Null
        Copy-Item "$pythonSource\*" "$dest\python" -Recurse -Force
    }
    Copy-Item "$PSScriptRoot\runtime\venv\Lib\site-packages\pysnmp","$PSScriptRoot\runtime\venv\Lib\site-packages\pyasn1" "$dest\python\Lib\site-packages" -Recurse -Force
    @'
Hostname=print-server-windows
ServerActive=127.0.0.1:11051
LogFile=C:\ProgramData\ZabbixPrintLab\agent.log
LogFileSize=5
Timeout=10
RefreshActiveChecks=30
ForceActiveChecksOnStart=1
ControlSocket=\\.\pipe\ZabbixPrintLabControl
'@ | Set-Content "$dest\agent.conf" -Encoding ascii
    # Protect all code executed by the service and task from standard-user modification.
    & icacls.exe $dest /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q
    if ($LASTEXITCODE) { throw 'Falha ao proteger a pasta do coletor.' }
    & icacls.exe "$dest\*" /reset /T /Q
    if ($LASTEXITCODE) { throw 'Falha ao configurar heranca de permissoes.' }
    $labConfig=Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
    $labQueues=@($labConfig.queue_overrides.psobject.Properties.Name | Where-Object {$_ -match '^HML-Impressora-(\d+)$'} | Sort-Object)
    foreach ($name in $labQueues) {
        $suffix=([regex]::Match($name,'(\d+)$')).Groups[1].Value
        $number=[int]$suffix
        $port='HML-SNMP-'+$suffix
        if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
            Add-PrinterPort -Name $port -PrinterHostAddress '127.0.0.1' -PortNumber (19100+$number)
        }
        if (-not (Get-Printer -Name $name -ErrorAction SilentlyContinue)) {
            Add-Printer -Name $name -DriverName 'Microsoft Print To PDF' -PortName $port
        }
    }
    if (-not (Get-Service | Where-Object Name -eq $serviceName)) {
        & "$dest\zabbix_agent2.exe" -c "$dest\agent.conf" -i -m
        if ($LASTEXITCODE) { throw 'Falha ao instalar Agent 2.' }
    }
    $action=New-ScheduledTaskAction -Execute "$dest\python\python.exe" -Argument ('"'+$dest+'\collect.py"') -WorkingDirectory $dest
    $trigger=New-ScheduledTaskTrigger -AtStartup
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount
    $taskSettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName ZabbixPrintLabCollector -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force | Out-Null
    Start-ScheduledTask -TaskName ZabbixPrintLabCollector
    Get-Service | Where-Object Name -eq $serviceName | Start-Service
    'OK' | Set-Content "$dest\install-result.txt"
} catch {
    $_ | Out-String | Set-Content "$dest\install-result.txt"
    throw
} finally { Stop-Transcript }
