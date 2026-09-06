$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $projectDir '.env'
$settings = @{}

Get-Content -LiteralPath $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $key, $value = $line.Split('=', 2)
        $settings[$key] = $value
    }
}
$apiUrl = "http://127.0.0.1:$($settings.ZABBIX_WEB_PORT)/api_jsonrpc.php"
$requestId = 0

function Invoke-ZabbixRpc {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] $Params,
        [string] $AuthToken
    )

    $script:requestId++
    $payload = [ordered]@{
        jsonrpc = '2.0'
        method = $Method
        params = $Params
        id = $script:requestId
    }
    if ($AuthToken) {
        $payload.auth = $AuthToken
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $apiUrl `
        -ContentType 'application/json-rpc' `
        -Body ($payload | ConvertTo-Json -Depth 20 -Compress)

    if ($response.error) {
        throw "$Method falhou: $($response.error.data)"
    }
    return $response.result
}

function Get-LoginToken {
    param([string] $Password)
    Invoke-ZabbixRpc -Method 'user.login' -Params @{
        username = $settings.ZABBIX_ADMIN_USER
        password = $Password
    }
}
