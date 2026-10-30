"""Run through stdin inside the built image; uses no GitHub credentials."""
import asyncio
import os
import secrets
import httpx
from service import create_app


class FakeGitHub:
    def library(self):
        return {}, 'test-commit', 'test-tree', []


async def main():
    assert os.getuid() == 10001, 'Service must run as the intake user'
    admin = secrets.token_urlsafe(40)
    app = create_app('/data/smoke.sqlite3', admin, FakeGitHub())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='https://test.local') as client:
        assert (await client.get('/health')).status_code == 200
        assert (await client.get('/v1/library')).status_code == 401
        result = await client.post('/admin/devices', headers={'Authorization': 'Bearer ' + admin}, json={'label': 'container-test'})
        assert result.status_code == 200, result.status_code
        headers = {'Authorization': 'Bearer ' + result.json()['device_token']}
        assert (await client.get('/v1/library', headers=headers)).json()['commit'] == 'test-commit'
    print('PASS: non-root import, writable SQLite storage, health, enrollment, authenticated library')


asyncio.run(main())
