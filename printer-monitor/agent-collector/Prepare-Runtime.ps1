param(
    [Parameter(Mandatory)]
    [string]$ZabbixBinDirectory,
    [Parameter(Mandatory)]
    [string]$PythonHome
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$runtime = Join-Path $root 'runtime'
$agent = Join-Path $ZabbixBinDirectory 'zabbix_agent2.exe'
$sender = Join-Path $ZabbixBinDirectory 'zabbix_sender.exe'
$python = Join-Path $PythonHome 'python.exe'

foreach ($path in @($agent, $sender, $python)) {
    if (-not (Test-Path $path)) { throw "Arquivo nao encontrado: $path" }
}

$bin = Join-Path $runtime 'agent/bin'
New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item $agent, $sender -Destination $bin -Force
(Resolve-Path $PythonHome).Path | Set-Content (Join-Path $runtime 'python-source.txt') -Encoding ascii

& $python -m venv (Join-Path $runtime 'venv')
if ($LASTEXITCODE) { throw 'Falha ao criar o ambiente Python do coletor.' }
$venvPython = Join-Path $runtime 'venv/Scripts/python.exe'
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r (Join-Path $root 'requirements.txt')
if ($LASTEXITCODE) { throw 'Falha ao instalar as dependencias SNMP.' }

Write-Host 'Runtime preparado. O diretorio runtime permanece local e nao deve ser versionado.'
