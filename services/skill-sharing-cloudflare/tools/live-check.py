"""Read-only GitHub smoke test using a disposable, revoked D1 device credential.

Requires the account administrator's CLOUDFLARE_API_TOKEN (D1 Edit). It never
reads Cloudflare secret values, stores a plaintext device token, or writes GitHub.
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import urllib.error
import urllib.request

config = json.loads((Path(__file__).resolve().parents[1] / 'wrangler.jsonc').read_text())
service = 'https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev'
database = config['d1_databases'][0]['database_id']
api = f"https://api.cloudflare.com/client/v4/accounts/{config['account_id']}/d1/database/{database}/query"
agent = 'Autodesk-MCP-Connector/1.0.0-beta.17'


def query(sql, params):
    req = urllib.request.Request(api, method='POST', data=json.dumps({'sql': sql, 'params': params}).encode(), headers={
        'Authorization': 'Bearer ' + os.environ['CLOUDFLARE_API_TOKEN'],
        'Content-Type': 'application/json', 'User-Agent': agent,
    })
    with urllib.request.urlopen(req, timeout=30) as response:
        data = json.load(response)
    if not data.get('success') or not all(item.get('success') for item in data.get('result', [])):
        raise RuntimeError('Cloudflare database operation failed.')
    return data


def request(path, token=None):
    headers = {'User-Agent': agent, 'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(service + path, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        raw = error.read(2048)
        try:
            data = json.loads(raw)
        except ValueError:
            data = {'detail': 'Non-JSON response.'}
        return error.code, data


def main():
    status, _ = request('/health')
    print('Service health HTTP:', status)
    if status != 200:
        return 1
    status, _ = request('/v1/library')
    print('Unauthenticated library HTTP:', status)
    if status != 401:
        return 1
    identifier, token = secrets.token_hex(16), secrets.token_urlsafe(32)
    inserted = False
    try:
        query('INSERT INTO devices(id,hash,label,active) VALUES(?,?,?,1)', [identifier, hashlib.sha256(token.encode()).hexdigest(), 'Disposable live validation'])
        inserted = True
        status, data = request('/v1/library', token)
        print('Authenticated library HTTP:', status)
        if status != 200:
            # Service diagnostics contain controlled messages, never upstream bodies.
            print('Service diagnostic:', data.get('detail', 'Unavailable.'))
            return 1
        print('Approved commit:', data.get('commit'))
        print('Approved skill count:', len(data.get('skills', [])))
        print('Approved file count:', sum(len(s.get('files', {})) for s in data.get('skills', [])))
        return 0
    finally:
        if inserted:
            query('UPDATE devices SET active=0 WHERE id=?', [identifier])
            status, _ = request('/v1/library', token)
            print('Revoked device HTTP:', status)
            if status != 401:
                raise RuntimeError('Device revocation did not reject access.')


if __name__ == '__main__':
    raise SystemExit(main())
