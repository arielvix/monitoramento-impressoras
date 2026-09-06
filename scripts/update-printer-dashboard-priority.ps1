. (Join-Path $PSScriptRoot 'snmp-api.ps1')
$dashboardPath=Join-Path $projectDir 'grafana/dashboards/impressoras-n1.json'
$dashboard=Get-Content $dashboardPath -Raw | ConvertFrom-Json

$availabilityPeriodVariable=[pscustomobject]@{
    name='availability_period'; label='Disponibilidade — período próprio'; type='custom'
    query='24 horas : 86400,7 dias : 604800,15 dias : 1296000,30 dias : 2592000'
    hide=0; multi=$false; includeAll=$false; options=@()
    current=[pscustomobject]@{text='24 horas';value='86400'}
}
$printerPageQuery=@'
WITH printer_count AS (
  SELECT COUNT(*) AS total
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
  JOIN host_tag client_tag ON client_tag.hostid = h.hostid AND client_tag.tag = 'client'
  JOIN host_tag sector_tag ON sector_tag.hostid = h.hostid AND sector_tag.tag = 'setor'
  WHERE h.status = 0
    AND h.name ~ '${hostname:regex}'
    AND client_tag.value ~ '${printer_client:regex}'
    AND sector_tag.value ~ '${printer_setor:regex}'
)
SELECT page::text AS __text, page::text AS __value
FROM printer_count,
     generate_series(1, GREATEST(1, CEIL(printer_count.total / 10.0)::integer)) AS page
'@
$printerPageVariable=[pscustomobject]@{
    name='printer_page'; label='Página — 10 impressoras'; type='query'
    datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    definition=$printerPageQuery; query=$printerPageQuery
    refresh=1; sort=0; hide=0; multi=$false; includeAll=$false; options=@()
    current=[pscustomobject]@{text='1';value='1'}
}
$clientQuery=@'
SELECT DISTINCT tag.value AS __text, tag.value AS __value
FROM host_tag tag
JOIN hosts h ON h.hostid = tag.hostid AND h.status = 0
JOIN hosts_groups hg ON hg.hostid = h.hostid
JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
WHERE tag.tag = 'client'
ORDER BY tag.value
'@
$clientVariable=[pscustomobject]@{
    name='printer_client'; label='Cliente'; type='query'
    datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    definition=$clientQuery; query=$clientQuery
    refresh=1; sort=0; hide=0; multi=$true; includeAll=$true; allValue='.*'; options=@()
    current=[pscustomobject]@{text='All';value='$__all'}
}
$sectorQuery=@'
SELECT DISTINCT sector.value AS __text, sector.value AS __value
FROM host_tag sector
JOIN host_tag client ON client.hostid = sector.hostid AND client.tag = 'client'
JOIN hosts h ON h.hostid = sector.hostid AND h.status = 0
JOIN hosts_groups hg ON hg.hostid = h.hostid
JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
WHERE sector.tag = 'setor'
  AND client.value ~ '${printer_client:regex}'
ORDER BY sector.value
'@
$sectorVariable=[pscustomobject]@{
    name='printer_setor'; label='Setor'; type='query'
    datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    definition=$sectorQuery; query=$sectorQuery
    refresh=1; sort=0; hide=0; multi=$true; includeAll=$true; allValue='.*'; options=@()
    current=[pscustomobject]@{text='All';value='$__all'}
}
$dashboard.templating.list=@($dashboard.templating.list | Where-Object { $_.name -notin @('availability_period','printer_page','printer_client','printer_setor') })+@($clientVariable,$sectorVariable,$availabilityPeriodVariable,$printerPageVariable)

$availabilityHistorySql=@'
WITH paged_hosts AS (
  SELECT h.hostid, h.name
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
  JOIN host_tag client_tag ON client_tag.hostid = h.hostid AND client_tag.tag = 'client'
  JOIN host_tag sector_tag ON sector_tag.hostid = h.hostid AND sector_tag.tag = 'setor'
  WHERE h.status = 0
    AND h.name ~ '${hostname:regex}'
    AND client_tag.value ~ '${printer_client:regex}'
    AND sector_tag.value ~ '${printer_setor:regex}'
  ORDER BY h.name
  LIMIT 10 OFFSET ((CAST('${printer_page}' AS integer) - 1) * 10)
)
SELECT to_timestamp(history.clock) AS "time",
       h.name AS metric,
       history.value AS value
FROM history_uint history
JOIN items item ON item.itemid = history.itemid AND item.key_ = 'printer.available'
JOIN paged_hosts h ON h.hostid = item.hostid
WHERE history.clock >= EXTRACT(EPOCH FROM NOW() - (CAST('${availability_period}' AS integer) * INTERVAL '1 second'))
ORDER BY "time"
'@

$queueHistorySql=@'
WITH paged_hosts AS (
  SELECT h.hostid, h.name
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
  JOIN host_tag client_tag ON client_tag.hostid = h.hostid AND client_tag.tag = 'client'
  JOIN host_tag sector_tag ON sector_tag.hostid = h.hostid AND sector_tag.tag = 'setor'
  WHERE h.status = 0
    AND h.name ~ '${hostname:regex}'
    AND client_tag.value ~ '${printer_client:regex}'
    AND sector_tag.value ~ '${printer_setor:regex}'
  ORDER BY h.name
  LIMIT 10 OFFSET ((CAST('${printer_page}' AS integer) - 1) * 10)
)
SELECT to_timestamp(history.clock) AS "time",
       h.name AS metric,
       history.value AS value
FROM history_uint history
JOIN items item ON item.itemid = history.itemid AND item.key_ = 'printer.jobs'
JOIN paged_hosts h ON h.hostid = item.hostid
WHERE history.clock >= (CAST(${__from} AS bigint) / 1000)
  AND history.clock <= (CAST(${__to} AS bigint) / 1000)
ORDER BY "time"
'@

# A tabela de prioridade já mostra o estado atual e o toner. Remova os
# barômetros que repetiam esses dados; a disponibilidade do período fica em
# um único painel de síntese que acompanha o intervalo escolhido.
$dashboard.panels=@($dashboard.panels | Where-Object { $_.id -notin @(4,5,7,9,10,11,12,13,14) })
$dashboard.timepicker.time_options=@('24h','7d','15d','30d')
$dashboard.time.from='now-24h'
$dashboard.time.to='now'
foreach($panel in $dashboard.panels) {
    if ($panel.id -eq 1) {
        $panel.options.content="**Verde: online · Vermelho: offline · Sem dados: verificar coletor**`n`nFiltre por cliente e setor. Escolha a página para ver 10 impressoras por vez. Fila e demais gráficos usam o período geral; disponibilidade tem seletor próprio. Atualização: **30 s**."
    }
    elseif ($panel.id -eq 6) {
        $panel.gridPos.y=15
        $panel.title='Histórico de disponibilidade · período próprio'
        $panel.description='Usa o seletor de disponibilidade e mostra somente as 10 impressoras da página atual.'
        $panel.datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
        $panel.targets=@([pscustomobject]@{
            refId='A';format='time_series';rawQuery=$true;rawSql=$availabilityHistorySql
            datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
        })
        $panel.transformations=@()
    }
    elseif ($panel.id -eq 8) {
        $panel.gridPos.x=0
        $panel.gridPos.y=32
        $panel.gridPos.w=24
        $panel.title='Trabalhos na fila · período geral'
        $panel | Add-Member -NotePropertyName description -NotePropertyValue 'Usa o período geral e a página selecionada.' -Force
        $panel.datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
        $panel.targets=@([pscustomobject]@{
            refId='A';format='time_series';rawQuery=$true;rawSql=$queueHistorySql
            datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
        })
        $panel.transformations=@()
    }
}

$sql=@'
WITH paged_hosts AS (
  SELECT h.hostid, h.name
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
  JOIN host_tag client_tag ON client_tag.hostid = h.hostid AND client_tag.tag = 'client'
  JOIN host_tag sector_tag ON sector_tag.hostid = h.hostid AND sector_tag.tag = 'setor'
  WHERE h.status = 0
    AND h.name ~ '${hostname:regex}'
    AND client_tag.value ~ '${printer_client:regex}'
    AND sector_tag.value ~ '${printer_setor:regex}'
  ORDER BY h.name
  LIMIT 10 OFFSET ((CAST('${printer_page}' AS integer) - 1) * 10)
)
SELECT h.name AS "Impressora",
       CASE WHEN latest_available.value = 1 THEN 'ONLINE' ELSE 'OFFLINE' END AS "Status",
       latest_available.value AS "Disponibilidade",
       COALESCE(latest_toner.value, -1) AS "Toner (%)",
       COALESCE(latest_pages.value, 0) AS "Paginas"
FROM paged_hosts h
JOIN items availability ON availability.hostid = h.hostid AND availability.key_ = 'printer.available'
JOIN LATERAL (
  SELECT value FROM history_uint
  WHERE itemid = availability.itemid
  ORDER BY clock DESC, ns DESC LIMIT 1
) latest_available ON true
LEFT JOIN items toner ON toner.hostid = h.hostid AND toner.key_ = 'printer.toner'
LEFT JOIN LATERAL (
  SELECT value FROM history
  WHERE itemid = toner.itemid
  ORDER BY clock DESC, ns DESC LIMIT 1
) latest_toner ON true
LEFT JOIN items pages ON pages.hostid = h.hostid AND pages.key_ = 'printer.pages'
LEFT JOIN LATERAL (
  SELECT value FROM history_uint
  WHERE itemid = pages.itemid
  ORDER BY clock DESC, ns DESC LIMIT 1
) latest_pages ON true
ORDER BY latest_available.value ASC, COALESCE(latest_toner.value, 999) ASC, h.name ASC
'@

$priorityPanel=[pscustomobject]@{
    id=9; type='table'; title='PRIORIDADE N1 — incidentes e toner baixo primeiro'
    description='Mostra as 10 impressoras da página atual, ordenadas por disponibilidade e depois pelo menor toner.'
    gridPos=[pscustomobject]@{x=0;y=5;w=24;h=10}
    datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    targets=@([pscustomobject]@{
        refId='A'; format='table'; rawQuery=$true; rawSql=$sql
        datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    })
    fieldConfig=[pscustomobject]@{
        defaults=[pscustomobject]@{custom=[pscustomobject]@{align='auto';cellOptions=[pscustomobject]@{type='auto'};inspect=$false}}
        overrides=@(
            [pscustomobject]@{
                matcher=[pscustomobject]@{id='byName';options='Status'}
                properties=@(
                    [pscustomobject]@{id='mappings';value=@([pscustomobject]@{type='value';options=[pscustomobject]@{
                        ONLINE=[pscustomobject]@{text='ONLINE';color='green'}
                        OFFLINE=[pscustomobject]@{text='OFFLINE';color='red'}
                    }})},
                    [pscustomobject]@{id='custom.cellOptions';value=[pscustomobject]@{type='color-background';mode='basic'}}
                )
            },
            [pscustomobject]@{
                matcher=[pscustomobject]@{id='byName';options='Toner (%)'}
                properties=@(
                    [pscustomobject]@{id='unit';value='percent'},
                    [pscustomobject]@{id='thresholds';value=[pscustomobject]@{mode='absolute';steps=@(
                        [pscustomobject]@{color='red';value=$null},
                        [pscustomobject]@{color='orange';value=20},
                        [pscustomobject]@{color='green';value=40}
                    )}},
                    [pscustomobject]@{id='color';value=[pscustomobject]@{mode='thresholds'}},
                    [pscustomobject]@{id='custom.cellOptions';value=[pscustomobject]@{type='gauge';mode='gradient';valueDisplayMode='color'}}
                )
            }
        )
    }
    options=[pscustomobject]@{showHeader=$true;cellHeight='sm';footer=[pscustomobject]@{show=$false}}
}

$availabilitySummarySql=@'
WITH paged_hosts AS (
  SELECT h.hostid, h.name
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN hstgrp g ON g.groupid = hg.groupid AND g.name = 'Homologacao/Impressoras'
  JOIN host_tag client_tag ON client_tag.hostid = h.hostid AND client_tag.tag = 'client'
  JOIN host_tag sector_tag ON sector_tag.hostid = h.hostid AND sector_tag.tag = 'setor'
  WHERE h.status = 0
    AND h.name ~ '${hostname:regex}'
    AND client_tag.value ~ '${printer_client:regex}'
    AND sector_tag.value ~ '${printer_setor:regex}'
  ORDER BY h.name
  LIMIT 10 OFFSET ((CAST('${printer_page}' AS integer) - 1) * 10)
)
SELECT NOW() AS "time",
       h.name AS metric,
       AVG(history.value) * 100 AS value
FROM history_uint history
JOIN items item ON item.itemid = history.itemid AND item.key_ = 'printer.available'
JOIN paged_hosts h ON h.hostid = item.hostid
WHERE history.clock >= EXTRACT(EPOCH FROM NOW() - (CAST('${availability_period}' AS integer) * INTERVAL '1 second'))
GROUP BY h.name
ORDER BY h.name
'@

$availabilityPanel=[pscustomobject]@{
    id=7; type='bargauge'; title='Disponibilidade por impressora · período próprio'
    description='Calculado pelo seletor de disponibilidade e limitado às 10 impressoras da página atual.'
    gridPos=[pscustomobject]@{x=0;y=25;w=24;h=7}
    datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    targets=@([pscustomobject]@{
        refId='A';format='time_series';rawQuery=$true;rawSql=$availabilitySummarySql
        datasource=[pscustomobject]@{type='grafana-postgresql-datasource';uid='zabbix-postgres'}
    })
    fieldConfig=[pscustomobject]@{
        defaults=[pscustomobject]@{
            min=0;max=100;unit='percent';decimals=2;noValue='SEM DADOS'
            color=[pscustomobject]@{mode='thresholds'}
            thresholds=[pscustomobject]@{mode='absolute';steps=@(
                [pscustomobject]@{color='red';value=$null},
                [pscustomobject]@{color='orange';value=95},
                [pscustomobject]@{color='green';value=99}
            )}
        }
        overrides=@()
    }
    options=[pscustomobject]@{
        orientation='horizontal';displayMode='basic';showUnfilled=$true;minVizHeight=28;minVizWidth=0
        reduceOptions=[pscustomobject]@{values=$false;calcs=@('lastNotNull');fields=''}
        namePlacement='left';valueMode='color'
    }
}

$periodPanel=[pscustomobject]@{
    id=10; type='text'; title='Período da visão geral'
    gridPos=[pscustomobject]@{x=0;y=3;w=24;h=2}
    options=[pscustomobject]@{
        mode='markdown'
        content='[24 horas](/d/impressoras-n1?from=now-24h&to=now&var-availability_period=${availability_period}&var-printer_page=${printer_page}&${hostname:queryparam}&${printer_client:queryparam}&${printer_setor:queryparam})  ·  [7 dias](/d/impressoras-n1?from=now-7d&to=now&var-availability_period=${availability_period}&var-printer_page=${printer_page}&${hostname:queryparam}&${printer_client:queryparam}&${printer_setor:queryparam})  ·  [15 dias](/d/impressoras-n1?from=now-15d&to=now&var-availability_period=${availability_period}&var-printer_page=${printer_page}&${hostname:queryparam}&${printer_client:queryparam}&${printer_setor:queryparam})  ·  [30 dias](/d/impressoras-n1?from=now-30d&to=now&var-availability_period=${availability_period}&var-printer_page=${printer_page}&${hostname:queryparam}&${printer_client:queryparam}&${printer_setor:queryparam})'
    }
}

$dashboard.panels=@($dashboard.panels)+@($periodPanel,$priorityPanel,$availabilityPanel)
$dashboard | ConvertTo-Json -Depth 100 | Set-Content $dashboardPath -Encoding utf8
& (Join-Path $PSScriptRoot 'publish-printer-dashboard.ps1')
