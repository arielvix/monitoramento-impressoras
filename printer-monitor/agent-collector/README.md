# Print server Windows com Agent 2 ativo

Fluxo: filas reais do Windows (`Get-Printer` e `Get-PrinterPort`) -> SNMP
consultado neste Windows -> `cache.json` -> sincronizacao de hosts e envio
de metricas ao Zabbix. O Agent 2 continua ativo para supervisionar o
coletor e o Spooler do print server.

## Ambiente instalado

- Host Zabbix do coletor: `print-server-windows`, grupo `Homologacao/Print Server`.
- Cada fila com SNMP vira um host proprio no grupo `Homologacao/Impressoras`.
- Template dos hosts de impressoras: `Printer by Windows Collector - Lab`.
- Servico: `Zabbix Agent 2 [print-server-windows]`.
- Tarefa de inicializacao: `ZabbixPrintLabCollector`, executada como SYSTEM.
- Instalacao e logs: `C:\ProgramData\ZabbixPrintLab`.
- Destino ativo: `127.0.0.1:11051`, Zabbix Docker local.
- Quarenta filas de teste: `HML-Impressora-01` ate `HML-Impressora-40`.

As filas de teste usam driver ja instalado Microsoft Print To PDF e portas
TCP locais apenas para existir no spooler. Nao envie documentos a essas filas:
os simuladores respondem SNMP, nao implementam um protocolo de impressao.
As filas e drivers preexistentes sao preservados.

O `config.json` associa cada fila de teste a sua porta UDP publicada pelo
Docker (`11161` a `11200`) e pode definir as tags `client` e `setor`.
Impressoras de rede reais sao descobertas por seu
PrinterHostAddress e consultadas em UDP/161. Filas virtuais/USB sem endereco
SNMP sao ignoradas. Ajuste comunidade e excecoes por fila no `config.json`
instalado, com permissao de administrador. O coletor rele essa configuracao
a cada ciclo.

## Hosts individuais e frequencia

O coletor executa a cada 30 segundos. Depois de encontrar uma fila com
endereco SNMP, cria ou atualiza seu host no Zabbix e envia disponibilidade,
toner preto, paginas, trabalhos pendentes, estado Windows, estado SNMP,
mensagem de erro e data da coleta. A primeira inclusao pode levar um ciclo.
O host `print-server-windows` monitora o estado do Spooler e a coleta local.

No laboratorio, a sincronizacao usa um token de API salvo somente na pasta
protegida do coletor e o `zabbix_sender` para publicar as metricas. Em um
ambiente real, use um usuario/token de API com somente as permissoes de grupo
e host necessarias e TLS para o envio ao Zabbix.

Toner/contador usam indices de exemplo da Printer-MIB: podem precisar de
adaptacao ao modelo real, sobretudo para impressoras coloridas. OIDs nao
suportados ficam ausentes; nao sao convertidos em zero. Em falha SNMP,
disponibilidade vira 0 e as demais metricas antigas deixam de atualizar.
Em falha de descoberta Windows, o cache anterior e preservado e sua data
fica desatualizada; consulte tambem `collector.log`. Nenhuma notificacao
ou trigger de alerta foi criada por este instalador.

## Validacao

No Zabbix, acesse Data collection > Hosts e abra o grupo
`Homologacao/Impressoras`: cada fila aparece como host separado, com as tags
`client` e `setor`. Em
Monitoring > Latest data, escolha uma dessas impressoras para ver seus itens.
O host do print server mostra somente a saude do coletor.

Teste de queda: `docker compose stop impressora-02`. Em um ou dois ciclos,
a disponibilidade da segunda fila passa a 0. Recupere com
`docker compose start impressora-02`.

Para mudar toner/paginas, edite o registro em `snmp-simulator` e reinicie
apenas a impressora correspondente. Os valores dos simuladores sao fixos;
o coletor os consulta novamente em cada ciclo.

## Reinstalacao neste laboratorio

Execute `scripts/bootstrap-print-server.ps1` e
`scripts/bootstrap-printer-hosts.ps1` para provisionar o Zabbix.
Com o runtime local preparado, execute `Install-Lab.ps1` como administrador
para instalar/reparar o servico, coletor e filas. A pasta de instalacao tem
escrita restrita a Administradores e SYSTEM porque executa codigo como servico.
O runtime local e artefato de instalacao e nao e versionado no Git.

Para outra maquina, prepare Python com as dependencias de `requirements.txt`
e Agent 2, importe o template e adapte o caminho do JSON, Hostname e
ServerActive. Fora deste laboratorio local, configure TLS entre Agent e
Zabbix e use o endereco do servidor apropriado.

Referencia: [Agent 2 Windows](https://www.zabbix.com/documentation/7.0/en/manual/appendix/config/zabbix_agent2_win).
