from pathlib import Path
import zipfile,json,hashlib,datetime
b=Path(__file__).parent;s=b/'source';r=s/'runtime'
# Refresh the Claude skills bundle to match the runtime skill library.
with zipfile.ZipFile(s/'Autodesk MCP Skills for Claude.zip') as old:
 key=next(n for n in old.namelist() if n.replace('\\','/')=='autodesk-mcp-bim-workflows/SKILL.md')
 entry=old.read(key).decode('utf-8-sig').replace('daily team','weekly team')
with zipfile.ZipFile(s/'Autodesk MCP Skills for Claude.zip','w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('autodesk-mcp-bim-workflows/SKILL.md',entry)
 for p in sorted((r/'.agents/skills').rglob('*')):
  if p.is_file():z.write(p,'autodesk-mcp-bim-workflows/references/'+p.relative_to(r/'.agents/skills').as_posix())
with zipfile.ZipFile(s/'Support/Autodesk-MCP-Payload.zip','w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(r.rglob('*')):
  if p.is_file():z.write(p,'Autodesk-MCP-Payload/'+p.relative_to(r).as_posix())
name='Autodesk-MCP-Connector-1.0.0-beta.17.zip'
with zipfile.ZipFile(b/name,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(s.rglob('*')):
  if p.is_file() and r not in p.parents:z.write(p,'Autodesk-MCP-Connector-1.0.0-beta.17/'+p.relative_to(s).as_posix())
h=hashlib.sha256((b/name).read_bytes()).hexdigest().upper()
(b/'latest.json').write_text(json.dumps(dict(schema_version=1,version='1.0.0-beta.17',download_url='https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/download/v1.0.0-beta.17/'+name,sha256=h,published_at=datetime.datetime.now(datetime.timezone.utc).isoformat()),indent=2)+'\n')
notes=(b/'RELEASE-NOTES.md').read_text().split('\nSHA-256:')[0]+'\nSHA-256: '+h+'\n';(b/'RELEASE-NOTES.md').write_text(notes)
with zipfile.ZipFile(b/'beta17-github-upload.zip','w',zipfile.ZIP_DEFLATED) as z:
 for n in [name,'latest.json','RELEASE-NOTES.md']:z.write(b/n,n)
with zipfile.ZipFile(b/'beta17-source-and-tests.zip','w',zipfile.ZIP_DEFLATED) as z:
 for folder in [r,b/'tests']:
  for p in sorted(folder.rglob('*')):
   if p.is_file():z.write(p,p.relative_to(b).as_posix())
 z.write(b/'build.py','build.py')
print(name,h)
