import tempfile
import unittest
from pathlib import Path
import httpx
from service import create_app, validate_skills

ADMIN = 'a' * 40
SKILL = {'name': 'revit-check', 'files': {'SKILL.md': '---\nname: revit-check\ndescription: Test\n---\nRead document information.'}}

class FakeGitHub:
    def __init__(self): self.calls = 0; self.fail = False
    def submit(self, skills, digest):
        self.calls += 1
        if self.fail: raise RuntimeError('simulated outage')
        return 'https://github.com/example/repo/pull/7'
    def library(self): return {'revit-check': SKILL['files']}, 'abc', 'tree', []

class Tests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.gh = FakeGitHub()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=create_app(str(Path(self.tmp.name)/'db.sqlite'), ADMIN, self.gh)), base_url='https://test.local')
        r = await self.client.post('/admin/devices', headers={'Authorization': 'Bearer '+ADMIN}, json={'label':'PC1'})
        self.assertEqual(r.status_code, 200)
        self.device = r.json()
        self.headers = {'Authorization': 'Bearer '+self.device['device_token']}
    async def asyncTearDown(self):
        await self.client.aclose()
        self.tmp.cleanup()
    async def test_auth(self):
        self.assertEqual((await self.client.post('/v1/submissions', json={'skills':[SKILL]})).status_code, 401)
        self.assertEqual((await self.client.post('/admin/devices', headers=self.headers, json={'label':'bad'})).status_code, 403)
    async def test_dedup_and_revocation(self):
        for _ in range(2):
            r = await self.client.post('/v1/submissions', headers=self.headers, json={'skills':[SKILL]})
            self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.gh.calls,1)
        await self.client.delete('/admin/devices/'+self.device['device_id'], headers={'Authorization':'Bearer '+ADMIN})
        self.assertEqual((await self.client.get('/v1/library',headers=self.headers)).status_code,401)
    async def test_failed_submission_retries(self):
        self.gh.fail=True
        self.assertEqual((await self.client.post('/v1/submissions',headers=self.headers,json={'skills':[SKILL]})).status_code,502)
        self.gh.fail=False
        self.assertEqual((await self.client.post('/v1/submissions',headers=self.headers,json={'skills':[SKILL]})).status_code,200)
        self.assertEqual(self.gh.calls,2)
    async def test_validation_and_size(self):
        for filename, content in [('../secret.txt','x'),('bad.exe','x'),('secret.md','password=example'),('x.md','\x00')]:
            bad={'name':'revit-check','files':dict(SKILL['files'],**{filename:content})}
            r=await self.client.post('/v1/submissions',headers=self.headers,json={'skills':[bad]})
            self.assertEqual(r.status_code,422,r.text)
        self.assertEqual(self.gh.calls,0)
        self.assertEqual((await self.client.post('/v1/submissions',headers=self.headers,content=b'x'*(2*1024*1024+1))).status_code,413)
    async def test_library_and_rate(self):
        self.assertEqual((await self.client.get('/v1/library',headers=self.headers)).json()['commit'],'abc')
        for _ in range(19): await self.client.get('/v1/library',headers=self.headers)
        self.assertEqual((await self.client.get('/v1/library',headers=self.headers)).status_code,429)

if __name__=='__main__': unittest.main()

class GitHubContractTests(unittest.TestCase):
    def test_only_draft_branch_and_reuse(self):
        from service import GitHub
        gh = object.__new__(GitHub)
        gh.repo='owner/repo';gh.base='main';gh.reviewer='owner'
        gh.library=lambda: ({},'head-sha','tree-sha',[])
        calls=[]
        def request(method,path,body=None,allowed=(200,201),app=False):
            calls.append((method,path,body))
            if method=='GET' and '/pulls?' in path:return []
            if method=='GET' and '/git/ref/' in path:return {'message':'Not Found'}
            if path.endswith('/git/trees'):return {'sha':'new-tree'}
            if path.endswith('/git/commits'):return {'sha':'new-commit'}
            if path.endswith('/pulls'):return {'html_url':'https://github.com/owner/repo/pull/1','number':1}
            return {}
        gh.request=request
        result=gh.submit({'revit-check':SKILL['files']},'f'*64)
        self.assertEqual(result,'https://github.com/owner/repo/pull/1')
        pr=next(body for method,path,body in calls if method=='POST' and path.endswith('/pulls'))
        self.assertTrue(pr['draft']);self.assertEqual(pr['base'],'main')
        refs=next(body for method,path,body in calls if path.endswith('/git/refs'))
        self.assertTrue(refs['ref'].startswith('refs/heads/skill-intake/central-'))
        self.assertFalse(any('/merge' in path or '/releases' in path for _,path,_ in calls))
        # An existing PR is returned without creating another branch or PR.
        calls.clear()
        gh.request=lambda *args,**kwargs:[{'html_url':result}]
        self.assertEqual(gh.submit({'revit-check':SKILL['files']},'f'*64),result)
