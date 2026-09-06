. (Join-Path $PSScriptRoot 'snmp-api.ps1')
$token=Get-LoginToken -Password $settings.ZABBIX_ADMIN_PASSWORD
try {
    $hostEntry=@(Invoke-ZabbixRpc 'host.get' @{filter=@{host=@('print-server-windows')}} $token)[0]
    if (-not $hostEntry) {throw 'Host nao encontrado.'}
    $items=@(Invoke-ZabbixRpc 'item.get' @{hostids=@($hostEntry.hostid);output=@('name','key_','lastvalue','lastclock','state','error')} $token)
    $items | Where-Object key_ -NotLike 'vfs.file.contents*' | Select-Object name,lastvalue,state,error | Format-Table -AutoSize
    $master=@($items | Where-Object key_ -Like 'vfs.file.contents*')[0]
    if (-not $master.lastclock -or $master.lastclock -eq '0') {throw 'Agent ainda nao enviou o JSON.'}
    $data=$master.lastvalue | ConvertFrom-Json
    if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$data.timestamp -gt 120) {throw 'Coleta desatualizada.'}
    $expectedConfig=Get-Content (Join-Path $projectDir 'printer-monitor/agent-collector/config.json') -Raw | ConvertFrom-Json
    $expected=@($expectedConfig.queue_overrides.psobject.Properties.Name | Where-Object {$_ -match '^HML-Impressora-(\d+)$'}).Count
    if (@($data.printers).Count -lt $expected) {throw "Ainda nao foram descobertas todas as $expected filas de teste."}
    if (@($data.printers | Where-Object available -ne 1).Count) {throw 'Uma impressora ainda esta indisponivel.'}
    if (@($items | Where-Object {$_.state -ne '0' -or $_.lastclock -eq '0'}).Count -or $items.Count -lt 52) {throw 'Itens da descoberta ainda nao estao coletando.'}
    Write-Host 'OK: Windows -> SNMP -> JSON -> Agent 2 ativo -> Zabbix, com descoberta das filas.'
} finally {$null=Invoke-ZabbixRpc 'user.logout' @{} $token}
