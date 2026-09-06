. (Join-Path $PSScriptRoot 'snmp-api.ps1')
$headers=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings.GRAFANA_ADMIN_USER+':'+$settings.GRAFANA_ADMIN_PASSWORD))}
$base='http://127.0.0.1:'+$settings.GRAFANA_PORT
$dashboard=Get-Content (Join-Path $projectDir 'grafana/dashboards/impressoras-n1.json') -Raw | ConvertFrom-Json
$body=@{dashboard=$dashboard;overwrite=$true;message='Dashboard N1 de impressoras com descoberta e historico'} | ConvertTo-Json -Depth 100
Invoke-RestMethod "$base/api/dashboards/db" -Method Post -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Select-Object status,uid,url
