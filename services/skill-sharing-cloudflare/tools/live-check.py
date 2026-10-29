"""GitHub smoke test using a disposable, revoked D1 device credential.

Requires the account administrator's CLOUDFLARE_API_TOKEN (D1 Edit). It never
reads Cloudflare secret values or stores a plaintext device token. GitHub is
read-only unless --submit-test explicitly creates a harmless draft review PR.
"""
import argparse
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


def request(path, token=None, body=None):
    headers = {'User-Agent': agent, 'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(service + path, headers=headers, data=None if body is None else json.dumps(body).encode())
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


def main(submit_test=False):
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
        if submit_test:
            name = 'central-sharing-validation'
            candidate = {'skills': [{'name': name, 'files': {'SKILL.md':
                '---\nname: central-sharing-validation\ndescription: Harmless central sharing validation fixture.\n---\n\n'
                'This fixture checks that saved skills reach an owner-reviewed draft pull request.\n'
                'It performs no CAD actions and contains no project data.\n'
                'It is not a production workflow and requires owner review before publication.\n'}}]}
            first_status, first = request('/v1/submissions', token, candidate)
            print('Submission HTTP:', first_status)
            if first_status != 200 or first.get('status') not in ('submitted_for_approval', 'already_submitted'):
                print('Submission result:', first.get('detail', first.get('status')))
                return 1
            print('Review PR:', first.get('pull_request'))
            second_status, second = request('/v1/submissions', token, candidate)
            if second_status != 200 or second.get('status') != 'already_submitted' or second.get('pull_request') != first.get('pull_request'):
                raise RuntimeError('Repeated submission did not reuse the original PR.')
            print('Duplicate submission: reused the same PR.')
            library_status, approved = request('/v1/library', token)
            if library_status != 200 or any(s.get('name') == name for s in approved.get('skills', [])):
                raise RuntimeError('Unapproved test fixture appeared in the distributed library or library check failed.')
            print('Approval boundary: test fixture absent from approved downloads.')
        return 0
    finally:
        if inserted:
            query('UPDATE devices SET active=0 WHERE id=?', [identifier])
            status, _ = request('/v1/library', token)
            print('Revoked device HTTP:', status)
            if status != 401:
                raise RuntimeError('Device revocation did not reject access.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--submit-test', action='store_true', help='Create/reuse a harmless draft skill-review PR; never merge it.')
    args = parser.parse_args()
    raise SystemExit(main(args.submit_test))
