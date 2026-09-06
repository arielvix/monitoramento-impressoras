"""Discover Windows print queues and poll their devices; Agent 2 reads cache.json."""
import asyncio
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
from pysnmp.hlapi.v3arch.asyncio import (
    SnmpEngine, CommunityData, UdpTransportTarget, ContextData,
    ObjectType, ObjectIdentity, get_cmd,
)

ROOT = Path(__file__).resolve().parent
INVENTORY = r'''
$ErrorActionPreference='Stop'
$ports=@{}; Get-PrinterPort | ForEach-Object { $ports[$_.Name]=$_ }
$rows=@(Get-Printer | ForEach-Object {
  $p=$ports[$_.PortName]
  [pscustomobject]@{name=$_.Name;port_name=$_.PortName;address=[string]$p.PrinterHostAddress;queue_status=[string]$_.PrinterStatus; jobs=[int]$_.JobCount}
})
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
ConvertTo-Json -InputObject $rows -Compress
'''
OIDS = {
    'uptime': '1.3.6.1.2.1.1.3.0',
    'pages': '1.3.6.1.2.1.43.10.2.1.4.1.1',
    'toner_max': '1.3.6.1.2.1.43.11.1.1.8.1.1',
    'toner_level': '1.3.6.1.2.1.43.11.1.1.9.1.1',
    'device_status': '1.3.6.1.2.1.25.3.5.1.1.1',
}

METRICS = {
    'available': 'printer.available',
    'toner': 'printer.toner',
    'pages': 'printer.pages',
    'jobs': 'printer.jobs',
    'queue_status': 'printer.queue_status',
    'device_status': 'printer.device_status',
    'error': 'printer.error',
    'timestamp': 'printer.collector.timestamp',
}

def quote_sender(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'

def zabbix_api(config, method, params):
    payload = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params, 'id': 1}).encode()
    request = urllib.request.Request(
        config['api_url'], data=payload, method='POST',
        headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + config['api_token']},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)
    except urllib.error.URLError as exc:
        raise RuntimeError('Zabbix API indisponivel: ' + str(exc)) from exc
    if 'error' in result:
        raise RuntimeError('Zabbix API ' + method + ': ' + result['error'].get('data', 'erro'))
    return result['result']

def sync_printer_hosts(data, config):
    """Create/update one Zabbix host per discovered queue, then send trapper values."""
    zabbix = config.get('zabbix', {})
    if not zabbix.get('enabled') or not zabbix.get('api_token'):
        return
    groups = zabbix_api(zabbix, 'hostgroup.get', {'output': ['groupid'], 'filter': {'name': [zabbix['host_group']]}})
    if groups:
        groupid = groups[0]['groupid']
    else:
        groupid = zabbix_api(zabbix, 'hostgroup.create', {'name': zabbix['host_group']})['groupids'][0]
    templates = zabbix_api(zabbix, 'template.get', {'output': ['templateid'], 'filter': {'host': [zabbix['template']]}})
    if not templates:
        raise RuntimeError('Template de impressora nao encontrado: ' + zabbix['template'])
    templateid = templates[0]['templateid']
    hostnames = []
    for printer in data['printers']:
        # Windows prevents duplicate queue names, making it a clear hostname for N1.
        hostname = printer['name']
        hostnames.append(hostname)
        tags = [
            {'tag': 'class', 'value': 'printer'},
            {'tag': 'client', 'value': printer.get('client', 'sem-cliente')},
            {'tag': 'setor', 'value': printer.get('setor', 'sem-setor')},
            {'tag': 'source', 'value': 'windows-print-server'},
            {'tag': 'queue', 'value': printer['name']},
            {'tag': 'print_server', 'value': 'print-server-windows'},
        ]
        existing = zabbix_api(zabbix, 'host.get', {'output': ['hostid'], 'filter': {'host': [hostname]}})
        if existing:
            zabbix_api(zabbix, 'host.update', {'hostid': existing[0]['hostid'], 'name': printer['name'], 'tags': tags})
        else:
            zabbix_api(zabbix, 'host.create', {
                'host': hostname, 'name': printer['name'], 'groups': [{'groupid': groupid}],
                'templates': [{'templateid': templateid}], 'tags': tags,
            })
    sender_input = ROOT / 'zabbix_sender.input'
    lines = []
    for printer, hostname in zip(data['printers'], hostnames):
        for source, key in METRICS.items():
            value = data['timestamp'] if source == 'timestamp' else printer.get(source)
            if value is not None:
                lines.append(f'{quote_sender(hostname)} {key} {quote_sender(value)}')
    sender_input.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    sender = subprocess.run(
        [zabbix['sender_path'], '-z', zabbix['sender_server'], '-p', str(zabbix['sender_port']), '-i', str(sender_input)],
        capture_output=True, timeout=30, text=True,
    )
    if sender.returncode:
        raise RuntimeError('zabbix_sender falhou: ' + (sender.stdout + sender.stderr)[-500:])

async def collect(config):
    output = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', INVENTORY],
                            capture_output=True, timeout=20)
    if output.returncode:
        raise RuntimeError(output.stderr.decode('utf-8', errors='replace'))
    queues = json.loads(output.stdout.decode('utf-8-sig'))
    engine = SnmpEngine()
    limit = asyncio.Semaphore(8)

    async def poll(queue):
        override = config.get('queue_overrides', {}).get(queue['name'], {})
        address = override.get('address', queue['address'])
        if not address:
            return None  # USB/virtual queues do not have an SNMP endpoint.
        row = dict(queue, id=hashlib.sha256((queue['name']+'|'+queue['port_name']).encode()).hexdigest()[:16],
                   client=override.get('client', 'sem-cliente'),
                   setor=override.get('setor', 'sem-setor'),
                   address=address, available=0, error='')
        async with limit:
            try:
                target = await UdpTransportTarget.create((address, override.get('port', 161)), timeout=1, retries=1)
                error, status, index, values = await get_cmd(
                    engine, CommunityData(override.get('community', config['community']), mpModel=1),
                    target, ContextData(), *[ObjectType(ObjectIdentity(oid)) for oid in OIDS.values()])
                if error or status:
                    raise RuntimeError(str(error or status.prettyPrint()))
                for key, (_, value) in zip(OIDS, values):
                    try:
                        row[key] = int(value)
                    except (ValueError, TypeError):
                        pass  # Unsupported OIDs remain absent, never fabricated as zero.
                row['available'] = int('uptime' in row)
                if row.get('toner_max', 0) > 0 and row.get('toner_level', -1) >= 0:
                    row['toner'] = round(100 * row['toner_level'] / row['toner_max'], 2)
            except Exception as exc:
                row['error'] = str(exc)
        return row
    try:
        rows = await asyncio.gather(*(poll(q) for q in queues))
        return {'timestamp': int(time.time()), 'collector_ok': 1,
                'spooler': 1, 'printers': [r for r in rows if r is not None]}
    finally:
        engine.close_dispatcher()

def main():
    handler = RotatingFileHandler(ROOT / 'collector.log', maxBytes=1_000_000, backupCount=2)
    logging.basicConfig(handlers=[handler], level=logging.INFO)
    while True:
        started = time.monotonic()
        config = {'interval': 30}
        try:
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            data = asyncio.run(collect(config))
            temp = ROOT / 'cache.tmp'
            temp.write_text(json.dumps(data, ensure_ascii=True), encoding='utf-8')
            temp.replace(ROOT / 'cache.json')
            sync_printer_hosts(data, config)
        except Exception:
            # Preserve discovery on transient inventory failures. Timestamp becomes stale.
            logging.exception('Collection failed')
        time.sleep(max(1, config['interval'] - (time.monotonic() - started)))

if __name__ == '__main__':
    main()
