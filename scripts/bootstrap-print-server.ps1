. (Join-Path $PSScriptRoot 'snmp-api.ps1')
$token=Get-LoginToken -Password $settings.ZABBIX_ADMIN_PASSWORD
try {
    $group=@(Invoke-ZabbixRpc 'hostgroup.get' @{filter=@{name=@('Homologacao/Print Server')}} $token)
    if ($group.Count) {$gid=$group[0].groupid} else {$gid=(Invoke-ZabbixRpc 'hostgroup.create' @{name='Homologacao/Print Server'} $token).groupids[0]}
    $tg=@(Invoke-ZabbixRpc 'templategroup.get' @{filter=@{name=@('Templates/Printers')}} $token)
    if ($tg.Count) {$tgid=$tg[0].groupid} else {$tgid=(Invoke-ZabbixRpc 'templategroup.create' @{name='Templates/Printers'} $token).groupids[0]}
    $templateName='Windows Print Server by active agent - Lab'
    $templates=@(Invoke-ZabbixRpc 'template.get' @{filter=@{host=@($templateName)}} $token)
    if ($templates.Count) {$tid=$templates[0].templateid} else {$tid=(Invoke-ZabbixRpc 'template.create' @{host=$templateName;groups=@(@{groupid=$tgid})} $token).templateids[0]}
    function Ensure-Item($item) {
        $found=@(Invoke-ZabbixRpc 'item.get' @{hostids=@($tid);filter=@{key_=@($item.key_)}} $token)
        if ($found.Count) { $item.itemid=$found[0].itemid; $null=Invoke-ZabbixRpc 'item.update' $item $token; return $found[0].itemid }
        $item.hostid=$tid; return (Invoke-ZabbixRpc 'item.create' $item $token).itemids[0]
    }
    $master=Ensure-Item @{name='Print server: JSON do coletor';key_='vfs.file.contents[C:\ProgramData\ZabbixPrintLab\cache.json]';type=7;value_type=4;delay='30s';history='1d'}
    $null=Ensure-Item @{name='Print server: ultima coleta';key_='print.collector.timestamp';type=18;value_type=3;master_itemid=$master;delay='0';units='unixtime';preprocessing=@(@{type=12;params='$.timestamp';error_handler=0})}
    $null=Ensure-Item @{name='Print server: Spooler (0=executando)';key_='service.info[Spooler,state]';type=7;value_type=3;delay='30s'}
    $rule=@(Invoke-ZabbixRpc 'discoveryrule.get' @{hostids=@($tid);filter=@{key_=@('print.printers.discovery')}} $token)
    $ruleParams=@{name='Descoberta de filas de impressoras SNMP';key_='print.printers.discovery';type=18;master_itemid=$master;delay='0';lifetime='7d';preprocessing=@(@{type=12;params='$.printers';error_handler=0});lld_macro_paths=@(@{lld_macro='{#ID}';path='$.id'},@{lld_macro='{#NAME}';path='$.name'})}
    if ($rule.Count) {$rid=$rule[0].itemid; $ruleParams.itemid=$rid; $null=Invoke-ZabbixRpc 'discoveryrule.update' $ruleParams $token}
    else {$ruleParams.hostid=$tid; $rid=(Invoke-ZabbixRpc 'discoveryrule.create' $ruleParams $token).itemids[0]}
    foreach ($metric in @(@('available','Disponibilidade SNMP',3,''),@('toner','Toner preto',0,'%'),@('pages','Paginas impressas',3,''),@('jobs','Trabalhos na fila',3,''),@('queue_status','Estado da fila Windows',4,''),@('device_status','Estado SNMP (3=ociosa)',3,''),@('error','Erro SNMP',4,''))) {
        $key='print.printer.'+$metric[0]+'[{#ID}]'
        $found=@(Invoke-ZabbixRpc 'itemprototype.get' @{discoveryids=@($rid);filter=@{key_=@($key)}} $token)
        $item=@{name='{#NAME}: '+$metric[1];key_=$key;type=18;value_type=$metric[2];master_itemid=$master;delay='0';units=$metric[3];history='7d';preprocessing=@(@{type=12;params=('$.printers[?(@.id == "{#ID}")].'+$metric[0]+'.first()');error_handler=1})}
        if ($found.Count) {$item.itemid=$found[0].itemid; $null=Invoke-ZabbixRpc 'itemprototype.update' $item $token}
        else {$item.hostid=$tid; $item.ruleid=$rid; $null=Invoke-ZabbixRpc 'itemprototype.create' $item $token}
    }
    $hostname='print-server-windows'
    $found=@(Invoke-ZabbixRpc 'host.get' @{filter=@{host=@($hostname)};selectTags='extend'} $token)
    if (-not $found.Count) {
        $null=Invoke-ZabbixRpc 'host.create' @{host=$hostname;name='Print Server Windows - '+$env:COMPUTERNAME;groups=@(@{groupid=$gid});templates=@(@{templateid=$tid});tags=@(@{tag='origem';value='print-server-lab'})} $token
    } elseif (-not @($found[0].tags | Where-Object {$_.tag -eq 'origem' -and $_.value -eq 'print-server-lab'}).Count) {throw 'Host existente nao pertence ao laboratorio.'}
    $export=Invoke-ZabbixRpc 'configuration.export' @{format='yaml';options=@{templates=@($tid)}} $token
    $export | Set-Content (Join-Path $projectDir 'printer-monitor/agent-collector/template.yaml') -Encoding utf8
    Write-Host 'Template, descoberta automatica e host print-server-windows configurados.'
} finally { $null=Invoke-ZabbixRpc 'user.logout' @{} $token }
