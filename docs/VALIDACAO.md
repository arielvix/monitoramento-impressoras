# Roteiro de validação

Use este roteiro antes de liberar o monitoramento para a operação N1. Execute
os testes inicialmente na homologação e depois em um lote pequeno de
impressoras reais. Registre data, responsável, quantidade de filas e resultado
de cada etapa.

## Critérios de aceite

| Área | Resultado esperado |
| --- | --- |
| Descoberta | Cada fila TCP/IP válida do Windows cria ou atualiza um host Zabbix. |
| Dados | Disponibilidade, contador, toner quando suportado, fila e horário da coleta chegam ao Zabbix. |
| Classificação | Todo host possui as tags `client`, `setor`, `queue` e `print_server`. |
| Dashboard | Filtros retornam o mesmo escopo das tags; cada página mostra no máximo dez impressoras. |
| Incidente | A perda de SNMP de uma fila de teste vira indisponibilidade e retorna a normal ao recuperar. |
| Escala | O ciclo inteiro termina antes do próximo intervalo configurado. |

## 1. Validar a stack

No servidor Docker, confirme que Zabbix, PostgreSQL e Grafana estão ativos:

```powershell
docker compose ps
```

Abra o Zabbix e o Grafana pelas portas configuradas no `.env`. No Grafana,
verifique que as fontes Zabbix e PostgreSQL estão saudáveis. Publique a
dashboard caso ainda não esteja disponível:

```powershell
.\scripts\update-printer-dashboard-priority.ps1
```

No laboratório, a dashboard deve abrir em
`http://127.0.0.1:13000/d/impressoras-n1`.

## 2. Validar a fila Windows e o SNMP

Em um print server, escolha uma fila de teste e confirme que ela tem endereço
de rede, nome e estado esperados:

```powershell
Get-Printer -Name 'NOME-DA-FILA' | Format-List Name,PortName,PrinterStatus,JobCount
Get-PrinterPort | Where-Object Name -eq 'NOME-DA-PORTA' |
  Format-List Name,PrinterHostAddress
```

Confirme que a regra de firewall permite UDP `161` do print server para o IP
da impressora. Teste os OIDs com uma ferramenta SNMP autorizada pela
organização. O teste deve consultar pelo menos `sysUpTime`, contador de páginas
e estado do dispositivo. Para cada fabricante e modelo, anote os OIDs que
respondem e os que não são implementados.

Antes da coleta, confira que o nome exato da fila aparece em
`queue_overrides` no `config.json` quando for necessário definir endereço,
comunidade, cliente ou setor. Em produção, não mantenha endereços de
simuladores `127.0.0.1` nem filas `HML-Impressora-*`.

## 3. Validar o coletor Windows

Após instalar o runtime e o coletor, confirme o serviço Agent 2 e a tarefa
agendada:

```powershell
Get-Service 'Zabbix Agent 2*'
Get-ScheduledTask -TaskName 'ZabbixPrintLabCollector'
```

Espere pelo menos um intervalo de coleta e abra a pasta do coletor, normalmente
`C:\ProgramData\ZabbixPrintLab`. O `cache.json` deve conter a fila, endereço,
tags, disponibilidade e timestamp recentes. O `collector.log` não deve ter
falhas repetidas de API, SNMP ou `zabbix_sender`.

Use o script fornecido para validar o estado básico da instalação:

```powershell
.\scripts\verify-print-server.ps1
```

Em produção, adapte o nome da tarefa e a pasta se eles foram padronizados sem
o sufixo `Lab`.

## 4. Validar hosts e itens Zabbix

No Zabbix, abra **Data collection > Hosts** e filtre o grupo de impressoras.
Para a fila escolhida, confirme:

1. O host tem o mesmo nome da fila Windows.
2. O template de impressoras está vinculado.
3. As tags `client` e `setor` correspondem ao cadastro operacional.
4. Em **Monitoring > Latest data**, os itens `printer.available` e
   `printer.collector.timestamp` têm valores recentes.
5. `printer.pages`, `printer.toner`, `printer.jobs`, `printer.queue_status`,
   `printer.device_status` e `printer.error` têm comportamento coerente com o
   equipamento.

Toner ou contador ausente pode indicar OID não suportado pelo modelo; não é
uma falha se a disponibilidade e o timestamp estiverem recentes. Nunca aceite
um timestamp desatualizado como impressora saudável.

## 5. Validar a dashboard N1

Abra `Impressoras N1` e realize os testes abaixo.

1. Selecione um valor de `client`; somente as impressoras daquela tag devem
   permanecer nos painéis.
2. Selecione um `setor`; a lista deve reduzir ao setor correspondente.
3. Use `hostname` para localizar uma fila conhecida.
4. Altere o período geral entre `24h`, `7d`, `15d` e `30d`; todos os cards
   gerais devem acompanhar a seleção.
5. Nos cards de disponibilidade com gráfico, altere somente o período do
   próprio card; os outros painéis devem permanecer no período geral.
6. Navegue pelas páginas; cada página deve conter no máximo dez impressoras e
   a ordenação deve priorizar incidentes antes das impressoras saudáveis.

Verifique ainda que não há cards com a mesma métrica repetida sem necessidade.

## 6. Testar incidentes com segurança

Use somente uma fila e uma impressora marcadas para teste. Não desligue um
equipamento em produção que esteja atendendo usuários.

1. Restrinja temporariamente UDP `161` entre o print server e a impressora de
   teste, ou use uma ACL de teste no equipamento.
2. Aguarde três ciclos de coleta, ou o intervalo definido pela trigger.
3. Confirme `printer.available = 0`, a mensagem em `printer.error`, o evento
   Zabbix e a prioridade visual no Grafana.
4. Restaure a comunicação SNMP e confirme a recuperação automática.
5. Crie uma tarefa de impressão de teste e confira se `printer.jobs` e
   `printer.queue_status` acompanham o estado da fila.

Valide também uma falha do coletor em homologação, interrompendo apenas a
tarefa de teste. A idade de `printer.collector.timestamp` precisa sinalizar
que a coleta parou, mesmo que o último valor de disponibilidade ainda exista.

## 7. Validar capacidade

Amplie por lotes, por exemplo 10, 50, 100 e depois a quantidade planejada. Em
cada lote, meça o tempo entre a criação do `cache.json` e a conclusão do envio
ao Zabbix. O coletor usa até oito consultas SNMP simultâneas; aumente o
intervalo para `60` ou `120` segundos se o ciclo se aproximar do próximo
agendamento.

Para 800 filas, acompanhe CPU e memória do print server, latência e perda de
pacotes SNMP, fila do Zabbix Server, escrita do PostgreSQL e volume de eventos.
Distribua as filas entre print servers quando houver localidades ou redes
separadas. Defina a retenção de histórico antes do crescimento, usando trends
para análises de longo prazo.

## 8. Liberar para operação

Libere o lote somente após todos os critérios de aceite estarem atendidos.
Documente a relação fila, IP, modelo, cliente, setor e print server. Entregue
ao N1 o endereço da dashboard, o filtro inicial recomendado e o procedimento
de escalonamento para indisponibilidade, toner baixo, fila parada e coleta
desatualizada.
