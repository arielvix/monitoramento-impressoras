# Operar com impressoras reais em produção

Este projeto pode monitorar impressoras físicas que estejam publicadas como
filas TCP/IP em um ou mais print servers Windows. O Windows descobre as filas,
consulta cada equipamento por SNMP e mantém um host Zabbix por fila. O
Grafana usa as tags `client` e `setor` desses hosts para os filtros N1.

Não suba os serviços `impressora-01` a `impressora-40` em produção: eles são
somente simuladores do laboratório. Use o Zabbix e o Grafana corporativos, ou
suba apenas os serviços centrais se este repositório for a sua stack dedicada.

## Desenho recomendado

Use um print server por localidade ou domínio de rede que já seja responsável
pelas filas. Instale o coletor nesse servidor. Ele opera em modo ativo e não
precisa receber conexões do Zabbix.

```text
Impressoras reais -- UDP/161 --> Print server Windows -- TCP/10051 --> Zabbix Server
                                      |                         \
                                      +-- HTTPS/443 ------------> API do Zabbix

Grafana ----------------------------------------------> API Zabbix e PostgreSQL interno
```

O acesso à API serve para criar e atualizar os hosts. O `zabbix_sender` usa a
porta trapper para enviar os valores coletados. Se houver segmentação de rede,
libere esses fluxos a partir do print server; não exponha SNMP a redes que não
precisam consultá-lo.

## Pré-requisitos por impressora

1. Reserve IP ou crie uma entrada DNS estável para o equipamento.
2. Crie uma porta **Standard TCP/IP** e uma fila no Windows. O coletor ignora
   filas USB, WSD, virtuais ou sem `PrinterHostAddress`.
3. Habilite SNMP de leitura no equipamento. Prefira SNMPv3 com autenticação e
   privacidade. A implementação atual do coletor usa comunidade SNMPv2c; se o
   ambiente exigir SNMPv3, adapte o bloco `CommunityData` de `collect.py` e
   teste o perfil de cada fabricante antes da implantação.
4. Permita UDP `161` somente do IP do print server até cada impressora.
5. Registre o cliente e o setor que devem aparecer na operação N1.

Alguns modelos oferecem OIDs diferentes para toner e contadores, sobretudo
equipamentos coloridos. Valide os OIDs da Printer-MIB usados pelo coletor em
uma unidade de cada modelo. OIDs não suportados ficam sem valor; eles não são
tratados como zero.

## Preparar o Zabbix corporativo

Crie um grupo de hosts de produção, por exemplo `Produção/Impressoras`, e um
template dedicado, por exemplo `Printer by Windows Collector`. Os itens do
template são do tipo **Zabbix trapper** e devem preservar as chaves usadas pelo
coletor:

- `printer.available`, `printer.toner`, `printer.pages` e `printer.jobs`;
- `printer.queue_status`, `printer.device_status` e `printer.error`;
- `printer.collector.timestamp`.

Associe ao token de API uma conta de serviço exclusiva. Ela precisa apenas
consultar, criar e atualizar hosts no grupo de impressoras e ler o template
associado. Não use o token do administrador. Guarde-o somente na pasta local
protegida do coletor e defina expiração e rotina de renovação.

Crie triggers no template conforme a política N1, por exemplo: impressora sem
resposta por mais de três coletas; timestamp do coletor atrasado; toner abaixo
do limite operacional; e fila com trabalhos pendentes acima do limite. Ajuste
os tempos para evitar alerta durante reinicialização de equipamento ou janela
de manutenção.

## Configurar um print server real

1. Instale Python, Zabbix Agent 2 e `zabbix_sender` em versões compatíveis com
   o Zabbix Server. Use TLS com certificado ou PSK no Agent 2.
2. Execute `Prepare-Runtime.ps1` e instale o coletor. O instalador do
   laboratório usa nomes e caminhos com sufixo `Lab`; em produção padronize
   serviço, tarefa e pasta para a sua organização antes de distribuir.
3. No `config.json` instalado, altere `api_url`, `sender_server`, `host_group`
   e `template` para os valores corporativos. Habilite `zabbix.enabled` apenas
   quando o template e o token já estiverem disponíveis.
4. Remova as filas `HML-Impressora-*` e os endereços `127.0.0.1` do exemplo.
   Mantenha uma entrada para cada fila que precise de comunidade, endereço,
   cliente ou setor diferente do padrão:

```json
{
  "interval": 60,
  "community": "COMUNIDADE-GERENCIADA",
  "zabbix": {
    "enabled": true,
    "api_url": "https://zabbix.empresa.gov.br/api_jsonrpc.php",
    "api_token": "TOKEN-DA-CONTA-DE-SERVICO",
    "host_group": "Produção/Impressoras",
    "template": "Printer by Windows Collector",
    "sender_server": "zabbix.empresa.gov.br",
    "sender_port": 10051,
    "sender_path": "C:\\ProgramData\\ZabbixPrint\\zabbix_sender.exe"
  },
  "queue_overrides": {
    "IMP-RECEPCAO-01": {
      "address": "10.20.30.40",
      "community": "COMUNIDADE-GERENCIADA",
      "client": "SESA",
      "setor": "Hospitais"
    }
  }
}
```

O nome da chave em `queue_overrides` precisa ser idêntico ao nome da fila
retornado por `Get-Printer`. As tags criadas no host são `client`, `setor`,
`queue` e `print_server`. Escolha valores consistentes e sem variações de
grafia, pois elas determinam os filtros no Grafana.

O envio atual com `zabbix_sender` não inclui parâmetros TLS. Antes de exigir
criptografia nesse fluxo, acrescente os parâmetros TLS/PSK ou certificado ao
comando em `collect.py` e valide-o em homologação. O mesmo vale para SNMPv3:
o guia indica onde adaptar, mas o coletor distribuído ainda consulta SNMPv2c.
Os scripts `bootstrap-*.ps1` são de laboratório e criam token com o usuário
administrador local do Zabbix; em produção, crie previamente o template, a
conta de serviço e o token de menor privilégio.

## Escala e disponibilidade

Comece com uma localidade piloto e valide uma coleta completa, os valores SNMP
e a criação dos hosts. O coletor consulta no máximo oito impressoras em
paralelo e sincroniza hosts pela API a cada ciclo. Para centenas de filas,
comece com intervalo de 60 ou 120 segundos e meça o tempo de execução, a carga
no Zabbix e a fila do `zabbix_sender`. O ciclo deve terminar antes do próximo
iniciar.

Para cerca de 800 equipamentos, distribua as filas em mais de um print server
quando a rede ou a operação já forem segmentadas. Monitore o próprio print
server, o serviço Spooler, a tarefa do coletor e a idade de
`printer.collector.timestamp`. Mantenha retenção de histórico de acordo com a
capacidade do banco e use tendências para períodos longos.

Faça cópia de segurança do PostgreSQL, das configurações Zabbix, das
datasources e da dashboard Grafana. Exporte a dashboard após cada alteração.
Teste restauração e atualização de imagens em homologação antes de aplicá-las
na produção.

## Entrada em operação

1. Cadastre uma impressora por modelo e valide disponibilidade, páginas, toner
   e erro SNMP.
2. Confirme que os hosts recebem corretamente `client` e `setor` e que os
   filtros da dashboard retornam somente o escopo esperado.
3. Simule uma indisponibilidade controlada, bloqueando temporariamente SNMP
   para uma impressora de teste, e valide trigger, evento e recuperação.
4. Amplie por lotes, acompanhando o tempo de coleta e o volume de eventos.
5. Documente o responsável por cada cliente/setor e o procedimento para troca
   de IP, fila ou equipamento.
