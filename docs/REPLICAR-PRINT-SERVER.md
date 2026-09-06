# Replicar o monitoramento de impressoras

Este guia instala um print server Windows que descobre filas locais, consulta
as impressoras por SNMP e cria um host Zabbix para cada fila. O Grafana mostra
somente dez impressoras por página e permite filtrar por cliente e setor.

## Requisitos

### Servidor da stack

- Linux com Docker Engine ou Windows com Docker Desktop;
- Docker Compose v2;
- mínimo de 4 vCPU, 8 GiB de RAM e 30 GiB livres para o laboratório. Para 800
  impressoras, aumente o volume do PostgreSQL conforme a retenção de histórico;
- acesso HTTPS de saída na primeira inicialização para baixar as imagens Docker
  e o plugin Zabbix do Grafana;
- portas locais livres: TCP `18080` (Zabbix web), TCP `13000` (Grafana) e TCP
  `11051` (trapper Zabbix). Ajuste-as no `.env` se já estiverem em uso.

### Print server Windows

- Windows Server 2019 ou superior, ou Windows 10/11 Pro/Enterprise;
- recurso **Gerenciamento de impressão** instalado, com os cmdlets
  `Get-Printer`, `Get-PrinterPort` e `Add-Printer` disponíveis;
- conta de Administrador local para instalar o Agent 2, criar a tarefa
  agendada e cadastrar as portas e filas de teste;
- Python 3.12 ou superior instalado em uma pasta acessível ao Administrador;
- binários `zabbix_agent2.exe` e `zabbix_sender.exe` compatíveis com a versão
  principal do Zabbix Server;
- conectividade UDP `161` do Windows até cada impressora e TCP `10051` do
  Windows até o Zabbix Server. O Agent 2 trabalha em modo ativo, portanto não
  exige porta de entrada aberta no Windows.

### Zabbix e Grafana

- usuário Zabbix com acesso de leitura e escrita ao grupo de impressoras,
  hosts, templates, itens e tokens de API;
- Grafana com o plugin `alexanderzobnin-zabbix-app`, instalado
  automaticamente pela composição na primeira subida;
- PostgreSQL do Zabbix acessível ao Grafana apenas pela rede interna Docker.
  Ele é usado para a prioridade N1, paginação e filtros de tags.

### Informações que devem ser definidas antes da instalação

- endereço e comunidade SNMP de cada impressora;
- convenção de nomes das filas Windows;
- valor das tags `client` e `setor` de cada fila;
- credenciais fortes no `.env`. Nunca versione o arquivo `.env`, tokens de API
  ou senhas de equipamentos.

## 1. Subir a stack

1. Clone o repositório e copie `.env.example` para `.env`.
2. Preencha as credenciais locais. O `.env` não deve ser enviado ao Git.
3. Suba os serviços:

```powershell
docker compose up -d
docker compose ps
```

O Grafana usa duas fontes: a API Zabbix para os itens e o PostgreSQL do Zabbix
para a lista de prioridade, filtros e paginação.

## 2. Preparar o runtime Windows

No diretório `printer-monitor/agent-collector`, extraia o pacote Windows do
Zabbix e informe a pasta que contém os dois executáveis. Informe também a raiz
da instalação do Python, a pasta que contém `python.exe`.

```powershell
Set-Location .\printer-monitor\agent-collector
.\Prepare-Runtime.ps1 `
  -ZabbixBinDirectory 'C:\Temp\zabbix-7\bin' `
  -PythonHome 'C:\Python312'
```

O comando cria `runtime` com os binários e o ambiente Python contendo
`pysnmp`. Essa pasta é local e permanece ignorada pelo Git.

## 3. Definir impressoras, clientes e setores

No ambiente real, crie as filas e portas de impressora normalmente no Windows.
O coletor usa `Get-Printer` e `Get-PrinterPort`; filas sem endereço IP são
ignoradas. Em `printer-monitor/agent-collector/config.json`, preencha uma
entrada por exceção ou simulador:

```json
"NOME-DA-FILA": {
  "address": "10.20.30.40",
  "port": 161,
  "community": "public",
  "client": "SESA",
  "setor": "Hospitais"
}
```

As tags criadas no host Zabbix são `client` e `setor`. Elas alimentam os
filtros da dashboard. O arquivo de exemplo já distribui 40 simuladores entre
SESA, SEJUS e DETRAN. Em produção, ajuste essas atribuições para refletir sua
estrutura real. Para gerar mais simuladores, execute:

```powershell
.\scripts\expand-printer-lab.ps1 -Total 800
docker compose up -d
```

Simular 800 dispositivos exige bastante memória e CPU do Docker. Para 800
impressoras reais, não gere simuladores: cadastre as filas no Windows e mantenha
as entradas de endereço, `client` e `setor` no `config.json`.

## 4. Instalar o coletor e provisionar o Zabbix

Execute os comandos a seguir como Administrador no Windows que hospeda as
filas. O instalador cria a tarefa `ZabbixPrintLabCollector`, instala o Agent 2
ativo e usa `C:\ProgramData\ZabbixPrintLab` como pasta protegida.

```powershell
.\printer-monitor\agent-collector\Install-Lab.ps1
.\scripts\bootstrap-print-server.ps1
.\scripts\bootstrap-printer-hosts.ps1
```

O segundo script cria o host técnico do print server. O terceiro cria o grupo
`Homologacao/Impressoras`, o template `Printer by Windows Collector - Lab` e
um token local para o coletor. A cada ciclo de 30 segundos, o coletor cria ou
atualiza um host individual por fila e envia disponibilidade, toner, páginas,
fila e estados.

## 5. Publicar a dashboard

```powershell
.\scripts\update-printer-dashboard-priority.ps1
```

Abra `http://127.0.0.1:13000/d/impressoras-n1`. A dashboard inclui filtros de
cliente, setor, hostname, período próprio da disponibilidade e página. A lista
de páginas é dinâmica: 800 hosts produzem 80 páginas de dez impressoras.

## Validação e operação

```powershell
.\scripts\verify-print-server.ps1
```

No Zabbix, confirme os hosts no grupo `Homologacao/Impressoras`. Para testar
uma indisponibilidade do laboratório, pare um simulador e aguarde um ciclo:

```powershell
docker compose stop impressora-02
docker compose start impressora-02
```

Em produção, substitua as credenciais de exemplo, restrinja o token ao grupo
de impressoras e use TLS no Agent 2 e no envio ao servidor Zabbix.
