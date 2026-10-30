"""Administrator-only enrollment utility. Never distribute ADMIN_TOKEN to PCs."""
import argparse
import getpass
import json
import os
from pathlib import Path
from urllib.parse import urlparse
import httpx

parser=argparse.ArgumentParser()
parser.add_argument('action',choices=['enroll','revoke'])
parser.add_argument('--service-url',required=True)
parser.add_argument('--label')
parser.add_argument('--device-id')
parser.add_argument('--output',default='skill-service-device.json')
a=parser.parse_args()
u=urlparse(a.service_url)
if u.scheme!='https' or u.username or u.password or u.query or u.fragment:
    parser.error('Use the HTTPS service URL without credentials, query, or fragment.')
secret=os.getenv('SKILL_SERVICE_ADMIN_TOKEN') or getpass.getpass('Service administrator token: ')
headers={'Authorization':'Bearer '+secret}
base=a.service_url.rstrip('/')
with httpx.Client(timeout=30,follow_redirects=False) as client:
    if a.action=='enroll':
        if not a.label:parser.error('--label is required for enrollment')
        r=client.post(base+'/admin/devices',headers=headers,json={'label':a.label})
        r.raise_for_status()
        config={'service_url':base,**r.json()}
        output=Path(a.output)
        # A newly created credential file is private on POSIX; deploy through your managed Windows tooling.
        fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f:json.dump(config,f,indent=2)
        print('Enrollment file saved:',output)
        print('Device ID:',config['device_id'])
        print('Deliver this file securely with setup to this device/user only. Do not publish it or reuse it across the team.')
    else:
        if not a.device_id:parser.error('--device-id is required')
        r=client.delete(base+'/admin/devices/'+a.device_id,headers=headers)
        r.raise_for_status()
        print('Device access revoked.')
