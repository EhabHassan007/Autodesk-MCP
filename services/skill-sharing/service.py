"""Private skill intake: authenticated devices -> owner-reviewed GitHub PRs."""
from contextlib import contextmanager
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import sqlite3
import threading
import time

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

MAX_BODY = 2 * 1024 * 1024
EXTENSIONS = {'.md', '.txt', '.json', '.yaml', '.yml', '.toml', '.py', '.ps1', '.js', '.ts', '.sh', '.csv', '.xml'}
SENSITIVE = re.compile(r'github_pat_|gh[pousr]_[A-Za-z0-9_]+|-----BEGIN .*PRIVATE KEY|(?:password|api[_ -]?key|access[_ -]?token)\s*[:=]\s*\S+|[a-z]:\\users\\|[\w.+-]+@[\w.-]+\.[a-z]{2,}', re.I)


def validate_skills(data, scan=True):
    if not isinstance(data, dict) or set(data) != {'skills'} or not isinstance(data['skills'], list):
        raise ValueError('Expected a skills list.')
    if not 1 <= len(data['skills']) <= 100:
        raise ValueError('Provide between 1 and 100 skills.')
    result, total = {}, 0
    for skill in data['skills']:
        if not isinstance(skill, dict) or set(skill) != {'name', 'files'}:
            raise ValueError('Invalid skill object.')
        name, files = skill['name'], skill['files']
        if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name) or name in result:
            raise ValueError('Invalid or duplicate skill name.')
        if not isinstance(files, dict) or 'SKILL.md' not in files or not 1 <= len(files) <= 100:
            raise ValueError('Each skill needs SKILL.md and at most 100 files.')
        seen = set()
        for path, content in files.items():
            if not isinstance(path, str) or not isinstance(content, str):
                raise ValueError('Files must be named UTF-8 text strings.')
            parts = path.split('/')
            if any(p in ('', '.', '..') or p.startswith('.') for p in parts) or '\\' in path or ':' in path or len(path) > 240:
                raise ValueError('Invalid relative skill path.')
            if path.casefold() in seen or PurePosixPath(path).suffix.lower() not in EXTENSIONS:
                raise ValueError('Unsupported or duplicate file path.')
            seen.add(path.casefold())
            size = len(content.encode('utf-8'))
            total += size
            if size > 256 * 1024 or total > MAX_BODY or '\x00' in content:
                raise ValueError('Skill content exceeds limits or is binary.')
            if scan and SENSITIVE.search(content):
                raise ValueError('Potential sensitive content found; review locally before submitting.')
        if not re.search(r'^name:\s*' + re.escape(name) + r'\s*$', files['SKILL.md'], re.M):
            raise ValueError('SKILL.md name must match its folder.')
        result[name] = dict(sorted(files.items()))
    return dict(sorted(result.items()))


def canonical_digest(skills):
    return hashlib.sha256(json.dumps(skills, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


class GitHub:
    def __init__(self):
        self.repo = os.environ['GITHUB_REPOSITORY']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', self.repo):
            raise ValueError('Invalid configured repository.')
        self.app_id = os.environ['GITHUB_APP_ID']
        self.installation_id = os.environ['GITHUB_INSTALLATION_ID']
        self.private_key = Path(os.environ['GITHUB_PRIVATE_KEY_FILE']).read_text()
        self.base = os.getenv('GITHUB_BASE_BRANCH', 'main')
        self.reviewer = os.getenv('GITHUB_REVIEWER', self.repo.split('/')[0])
        self.token, self.expires = '', 0
        self.cached_library, self.cached_at = None, 0
        self.client = httpx.Client(base_url='https://api.github.com', timeout=30, follow_redirects=False)

    def request(self, method, path, body=None, allowed=(200, 201), app=False):
        if app:
            now = int(time.time())
            token = jwt.encode({'iat': now - 60, 'exp': now + 540, 'iss': self.app_id}, self.private_key, algorithm='RS256')
        else:
            if time.time() > self.expires:
                data = self.request('POST', f'/app/installations/{self.installation_id}/access_tokens', {
                    'repositories': [self.repo.split('/')[1]],
                    'permissions': {'contents': 'write', 'pull_requests': 'write'},
                }, app=True)
                self.token, self.expires = data['token'], time.time() + 3000
            token = self.token
        response = self.client.request(method, path, json=body, headers={
            'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'Autodesk-Skill-Intake',
        })
        if response.status_code not in allowed:
            # Do not leak credentials or submitted content in errors/logs.
            raise RuntimeError(f'GitHub request failed with HTTP {response.status_code}.')
        return response.json() if response.content else None

    def library(self):
        if self.cached_library and time.time() - self.cached_at < 60:
            return self.cached_library
        ref = self.request('GET', f'/repos/{self.repo}/git/ref/heads/{self.base}')
        if self.cached_library and self.cached_library[1] == ref['object']['sha']:
            self.cached_at = time.time()
            return self.cached_library
        commit = self.request('GET', f'/repos/{self.repo}/git/commits/{ref["object"]["sha"]}')
        tree = self.request('GET', f'/repos/{self.repo}/git/trees/{commit["tree"]["sha"]}?recursive=1')
        if tree.get('truncated'):
            raise RuntimeError('Repository tree is too large; configure a dedicated skill repository.')
        files = {}
        prefix = '.agents/skills/'
        for item in tree['tree']:
            if not item['path'].startswith(prefix) or item['type'] != 'blob':
                continue
            if item.get('mode') != '100644' and item.get('mode') != '100755':
                continue
            relative = item['path'][len(prefix):]
            if '/' not in relative or PurePosixPath(relative).suffix.lower() not in EXTENSIONS:
                continue
            if item.get('size', 0) > 256 * 1024:
                raise RuntimeError('Approved skill file is too large.')
            name, path = relative.split('/', 1)
            blob = self.request('GET', f'/repos/{self.repo}/git/blobs/{item["sha"]}')
            files.setdefault(name, {})[path] = base64.b64decode(blob['content']).decode('utf-8-sig')
        skills = {n: f for n, f in files.items() if 'SKILL.md' in f}
        if skills:
            validate_skills({'skills': [{'name': n, 'files': f} for n, f in skills.items()]}, scan=False)
        self.cached_library = (skills, ref['object']['sha'], commit['tree']['sha'], tree['tree'])
        self.cached_at = time.time()
        return self.cached_library

    def submit(self, skills, digest):
        branch = 'skill-intake/central-' + digest[:32]
        existing = self.request('GET', f'/repos/{self.repo}/pulls?state=all&head={self.repo.split("/")[0]}:{branch}')
        if existing:
            return existing[0]['html_url']
        approved, head, tree_sha, tree = self.library()
        if all(approved.get(name) == files for name, files in skills.items()):
            return 'already_approved'
        path = f'/repos/{self.repo}/git/ref/heads/{branch}'
        ref = self.request('GET', path, allowed=(200, 404))
        if not ref or 'object' not in ref:
            edits = []
            new_paths = {f'.agents/skills/{name}/{p}' for name, files in skills.items() for p in files}
            for item in tree:
                if item['type'] == 'blob' and any(item['path'].startswith(f'.agents/skills/{name}/') for name in skills) and item['path'] not in new_paths:
                    edits.append({'path': item['path'], 'mode': item['mode'], 'type': 'blob', 'sha': None})
            for name, files in skills.items():
                for filename, content in files.items():
                    edits.append({'path': f'.agents/skills/{name}/{filename}', 'mode': '100644', 'type': 'blob', 'content': content})
            created_tree = self.request('POST', f'/repos/{self.repo}/git/trees', {'base_tree': tree_sha, 'tree': edits})
            commit = self.request('POST', f'/repos/{self.repo}/git/commits', {
                'message': 'Propose saved Autodesk workflows for review', 'tree': created_tree['sha'], 'parents': [head],
            })
            self.request('POST', f'/repos/{self.repo}/git/refs', {'ref': f'refs/heads/{branch}', 'sha': commit['sha']})
        pr = self.request('POST', f'/repos/{self.repo}/pulls', {
            'title': 'Saved skill review: ' + ', '.join(skills)[:180], 'head': branch, 'base': self.base,
            'draft': True, 'body': 'Automatically collected workflow candidates. Local and server checks are heuristic. Review every file before approval. No automatic merge or release publication.\n\nBatch: `' + digest + '`',
        })
        if self.reviewer:
            try:
                self.request('POST', f'/repos/{self.repo}/pulls/{pr["number"]}/requested_reviewers', {'reviewers': [self.reviewer]})
            except RuntimeError:
                pass  # The PR still exists if owner review assignment is restricted.
        return pr['html_url']


def create_app(database, admin_token, github):
    if len(admin_token) < 32:
        raise ValueError('ADMIN_TOKEN must be at least 32 characters.')
    Path(database).parent.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    @contextmanager
    def db():
        c = sqlite3.connect(database, timeout=30)
        try:
            c.execute('PRAGMA journal_mode=WAL')
            with c:
                yield c
        finally:
            c.close()
    with db() as c:
        c.executescript('''CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, hash TEXT UNIQUE, label TEXT, active INTEGER);
        CREATE TABLE IF NOT EXISTS batches(digest TEXT PRIMARY KEY, url TEXT);
        CREATE TABLE IF NOT EXISTS rate(device TEXT PRIMARY KEY, hour INTEGER, count INTEGER);''')
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    class BodyLimit:
        def __init__(self, app): self.app = app
        async def __call__(self, scope, receive, send):
            if scope['type'] != 'http':
                return await self.app(scope, receive, send)
            body = bytearray()
            while True:
                message = await receive()
                if message['type'] == 'http.disconnect': return
                body.extend(message.get('body', b''))
                if len(body) > MAX_BODY:
                    response = JSONResponse({'detail':'Request too large.'}, status_code=413)
                    return await response(scope, receive, send)
                if not message.get('more_body', False): break
            delivered = False
            async def replay():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {'type':'http.request','body':bytes(body),'more_body':False}
                return await receive()
            await self.app(scope, replay, send)
    app.add_middleware(BodyLimit)

    def bearer(request):
        header = request.headers.get('authorization', '')
        if not header.startswith('Bearer '):
            raise HTTPException(401, 'Authorization required.')
        return header[7:]

    def admin(request):
        if not secrets.compare_digest(bearer(request), admin_token):
            raise HTTPException(403, 'Administrator access required.')

    def device(request, consume=False):
        digest = hashlib.sha256(bearer(request).encode()).hexdigest()
        with db() as c:
            row = c.execute('SELECT id FROM devices WHERE hash=? AND active=1', (digest,)).fetchone()
            if not row:
                raise HTTPException(401, 'Device credential invalid or revoked.')
            if consume:
                hour = int(time.time() // 3600)
                rate = c.execute('SELECT hour,count FROM rate WHERE device=?', (row[0],)).fetchone()
                count = rate[1] + 1 if rate and rate[0] == hour else 1
                if count > 20:
                    raise HTTPException(429, 'Submission limit reached; retry later.')
                c.execute('INSERT OR REPLACE INTO rate VALUES(?,?,?)', (row[0], hour, count))
            return row[0]

    @app.get('/health')
    def health():
        return {'status': 'ok'}

    @app.post('/admin/devices')
    async def enroll(request: Request):
        admin(request)
        try:
            data = await request.json()
        except ValueError:
            raise HTTPException(422, 'Invalid enrollment request.')
        label = data.get('label', '') if isinstance(data, dict) else ''
        if not isinstance(label, str) or not 1 <= len(label) <= 80:
            raise HTTPException(422, 'A short device label is required.')
        token, identifier = secrets.token_urlsafe(32), secrets.token_hex(16)
        with db() as c:
            c.execute('INSERT INTO devices VALUES(?,?,?,1)', (identifier, hashlib.sha256(token.encode()).hexdigest(), label))
        return {'device_id': identifier, 'device_token': token}

    @app.delete('/admin/devices/{identifier}')
    def revoke(identifier: str, request: Request):
        admin(request)
        with db() as c:
            c.execute('UPDATE devices SET active=0 WHERE id=?', (identifier,))
        return {'revoked': True}

    @app.post('/v1/submissions')
    async def submit(request: Request):
        device(request, consume=True)
        try:
            skills = validate_skills(await request.json())
        except (ValueError, TypeError):
            raise HTTPException(422, 'Invalid or flagged skill content. Review the local candidates.')
        digest = canonical_digest(skills)
        # Serialize GitHub operations and retry the same deterministic branch after interruptions.
        # Deploy one worker/instance for this SQLite version.
        def perform_submission():
            with lock:
                with db() as c:
                    saved = c.execute('SELECT url FROM batches WHERE digest=?', (digest,)).fetchone()
                if saved:
                    return {'status': 'already_submitted', 'pull_request': saved[0], 'digest': digest}
                try:
                    url = github.submit(skills, digest)
                except Exception:
                    raise HTTPException(502, 'GitHub submission failed. Retry later; no approval was recorded.')
                with db() as c:
                    c.execute('INSERT OR REPLACE INTO batches VALUES(?,?)', (digest, url))
                return {'status': 'already_approved' if url == 'already_approved' else 'submitted_for_approval', 'pull_request': url, 'digest': digest}
        return await run_in_threadpool(perform_submission)

    @app.get('/v1/library')
    def library(request: Request):
        device(request, consume=True)
        with lock:
            try:
                skills, commit, _, _ = github.library()
            except Exception:
                raise HTTPException(502, 'Approved library is temporarily unavailable.')
        return {'commit': commit, 'skills': [{'name': n, 'files': f} for n, f in skills.items()]}

    return app


def production_app():
    return create_app(os.getenv('DATABASE_PATH', '/data/intake.sqlite3'), os.environ['ADMIN_TOKEN'], GitHub())
