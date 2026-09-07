# Monitoramento de impressoras com Zabbix e Grafana

Laboratório independente para descobrir filas de um print server Windows,
consultar as impressoras por SNMP e criar um host Zabbix para cada fila.

O Grafana oferece prioridade N1, filtro por cliente e setor, período próprio de
disponibilidade e paginação de dez impressoras. A paginação cresce conforme o
número de hosts: 800 impressoras geram 80 páginas.

## Início rápido

```powershell
Copy-Item .env.example .env
docker compose up -d
```

Depois, siga o guia [REPLICAR-PRINT-SERVER.md](docs/REPLICAR-PRINT-SERVER.md)
para preparar o Windows, configurar os clientes e setores e publicar a
dashboard.

Para implantação com equipamentos físicos, leia o
[guia de produção](docs/PRODUCAO-IMPRESSORAS-REAIS.md).

Use o [roteiro de validação](docs/VALIDACAO.md) para homologar a stack e as
impressoras reais antes da liberação ao N1.

## Componentes

- Zabbix 7 com PostgreSQL;
- Grafana com fontes Zabbix e PostgreSQL;
- coletor Windows com Agent 2 ativo e `zabbix_sender`;
- simuladores SNMP para quarenta impressoras;
- scripts de provisionamento e validação.
