param(
    [ValidateRange(8, 999)]
    [int]$Total = 40
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $projectDir 'compose.yaml'
$configPath = Join-Path $projectDir 'printer-monitor/agent-collector/config.json'
$simulatorRoot = Join-Path $projectDir 'snmp-simulator'

# Docker Compose services are generated in a marked section so this command is idempotent.
$serviceBlocks = foreach ($number in 8..$Total) {
    $id = $number.ToString('D2')
    $udpPort = 11160 + $number
@"
  impressora-${id}:
    build: ./snmp-simulator
    ports:
      - "127.0.0.1:${udpPort}:1161/udp"
    restart: unless-stopped
    volumes:
      - ./snmp-simulator/printer-${id}:/data:ro
    networks: [monitoring]
"@
}
$generatedSection = "  # BEGIN generated printer simulators`n" + ($serviceBlocks -join "`n") + "`n  # END generated printer simulators`n"
$compose = Get-Content -Raw $composePath
if ($compose -match '(?s)  # BEGIN generated printer simulators.*?  # END generated printer simulators\r?\n') {
    $compose = $compose -replace '(?s)  # BEGIN generated printer simulators.*?  # END generated printer simulators\r?\n', $generatedSection
} else {
    $compose = $compose -replace '(?m)^  # printer simulator anchor$', ($generatedSection + '  # printer simulator anchor')
}
Set-Content -LiteralPath $composePath -Value $compose -Encoding utf8

$config = Get-Content -Raw $configPath | ConvertFrom-Json
if (-not $config.queue_overrides) {
    $config | Add-Member -NotePropertyName queue_overrides -NotePropertyValue ([pscustomobject]@{})
}
foreach ($number in 1..$Total) {
    $id = $number.ToString('D2')
    $name = "HML-Impressora-$id"
    $client = if ($number -le 15) { 'SESA' } elseif ($number -le 30) { 'SEJUS' } else { 'DETRAN' }
    $setor = switch ($client) {
        'SESA' { @('Administrativo', 'Hospitais', 'Vigilancia')[[math]::Floor(($number - 1) / 5) % 3] }
        'SEJUS' { @('Administrativo', 'Unidades', 'Tecnologia')[[math]::Floor(($number - 16) / 5) % 3] }
        default { @('Atendimento', 'Operacoes')[[math]::Floor(($number - 31) / 5) % 2] }
    }
    $config.queue_overrides | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
        address = '127.0.0.1'
        port = 11160 + $number
        client = $client
        setor = $setor
    }) -Force

    if ($number -le 7) { continue }
    $printerDir = Join-Path $simulatorRoot "printer-$id"
    $recordPath = Join-Path $printerDir 'public.snmprec'
    if (Test-Path $recordPath) { continue }
    New-Item -ItemType Directory -Force $printerDir | Out-Null
    $toner = 10 + (($number * 13) % 81)
    $pages = 5000 + ($number * 7500)
    $uptime = 8640000 + ($number * 360000)
@"
1.3.6.1.2.1.1.1.0|4|HP LaserJet - SIMULACAO
1.3.6.1.2.1.1.2.0|6|1.3.6.1.4.1.11.2.3.9.1
1.3.6.1.2.1.1.3.0|67|$uptime
1.3.6.1.2.1.1.5.0|4|impressora-$id
1.3.6.1.2.1.1.6.0|4|Laboratorio homologacao
1.3.6.1.2.1.25.3.5.1.1.1|2|3
1.3.6.1.2.1.43.10.2.1.4.1.1|65|$pages
1.3.6.1.2.1.43.11.1.1.6.1.1|4|Toner preto
1.3.6.1.2.1.43.11.1.1.8.1.1|2|100
1.3.6.1.2.1.43.11.1.1.9.1.1|2|$toner
"@ | Set-Content -LiteralPath $recordPath -Encoding ascii
}
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
Write-Host "Configurados $Total simuladores, filas e endpoints SNMP."
