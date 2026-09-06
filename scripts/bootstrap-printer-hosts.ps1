. (Join-Path $PSScriptRoot 'snmp-api.ps1')
$token=Get-LoginToken -Password $settings.ZABBIX_ADMIN_PASSWORD
try {
    $groupName='Homologacao/Impressoras'
    $groups=@(Invoke-ZabbixRpc 'hostgroup.get' @{filter=@{name=@($groupName)}} $token)
    if ($groups.Count) {$groupId=$groups[0].groupid} else {$groupId=(Invoke-ZabbixRpc 'hostgroup.create' @{name=$groupName} $token).groupids[0]}
    $templateGroup='Templates/Printers'
    $groups=@(Invoke-ZabbixRpc 'templategroup.get' @{filter=@{name=@($templateGroup)}} $token)
    if ($groups.Count) {$templateGroupId=$groups[0].groupid} else {$templateGroupId=(Invoke-ZabbixRpc 'templategroup.create' @{name=$templateGroup} $token).groupids[0]}
    $templateName='Printer by Windows Collector - Lab'
    $templates=@(Invoke-ZabbixRpc 'template.get' @{filter=@{host=@($templateName)}} $token)
    if ($templates.Count) {$templateId=$templates[0].templateid} else {$templateId=(Invoke-ZabbixRpc 'template.create' @{host=$templateName;name=$templateName;groups=@(@{groupid=$templateGroupId})} $token).templateids[0]}
    function Ensure-TrapperItem($key,$name,$valueType,$units='') {
        $found=@(Invoke-ZabbixRpc 'item.get' @{hostids=@($templateId);filter=@{key_=@($key)}} $token)
        $trends=if ($valueType -in @(1,2,4)) {'0'} else {'365d'}
        $item=@{name=$name;key_=$key;type=2;value_type=$valueType;delay='0';history='30d';trends=$trends;units=$units}
        if ($found.Count) {$item.itemid=$found[0].itemid; $null=Invoke-ZabbixRpc 'item.update' $item $token}
        else {$item.hostid=$templateId; $null=Invoke-ZabbixRpc 'item.create' $item $token}
    }
    Ensure-TrapperItem 'printer.available' 'Disponibilidade SNMP' 3
    Ensure-TrapperItem 'printer.toner' 'Toner preto' 0 '%'
    Ensure-TrapperItem 'printer.pages' 'Paginas impressas' 3
    Ensure-TrapperItem 'printer.jobs' 'Trabalhos na fila' 3
    Ensure-TrapperItem 'printer.queue_status' 'Estado da fila Windows' 1
    Ensure-TrapperItem 'printer.device_status' 'Estado SNMP (3=ociosa)' 3
    Ensure-TrapperItem 'printer.error' 'Erro SNMP' 1
    Ensure-TrapperItem 'printer.collector.timestamp' 'Ultima coleta' 3 'unixtime'
    $existingToken=@(Invoke-ZabbixRpc 'token.get' @{output=@('tokenid','name');filter=@{name=@('Windows Print Collector Lab')}} $token)
    if ($existingToken.Count) {$tokenId=[int]$existingToken[0].tokenid}
    else {$tokenId=[int](Invoke-ZabbixRpc 'token.create' @{name='Windows Print Collector Lab';description='Sincroniza hosts de impressoras descobertas neste Windows';userid=1;status=0;expires_at=0} $token).tokenids[0]}
    $apiToken=(Invoke-ZabbixRpc 'token.generate' @{tokenid=$tokenId} $token).token
    $installedConfig='C:\ProgramData\ZabbixPrintLab\config.json'
    if (-not (Test-Path $installedConfig)) {throw 'Instale ou atualize o coletor Windows antes de habilitar hosts individuais.'}
    $config=Get-Content $installedConfig -Raw | ConvertFrom-Json
    $config.zabbix.enabled=$true
    $config.zabbix.api_token=$apiToken
    $config | ConvertTo-Json -Depth 8 | Set-Content "$installedConfig.new" -Encoding utf8
    Move-Item "$installedConfig.new" $installedConfig -Force
    Write-Host 'Template e grupo de hosts individuais prontos. O coletor criara hosts a cada ciclo.'
} finally {$null=Invoke-ZabbixRpc 'user.logout' @{} $token}
