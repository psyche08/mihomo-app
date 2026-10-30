import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('profiles', Path(__file__).parents[1] / 'scripts/release-profiles.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)

class ProfilesTests(unittest.TestCase):
    def profile(self, bundle=p.HOST, days=20, uuid='00000000-0000-4000-8000-000000000001'):
        return {'UUID':uuid,'ExpirationDate':dt.datetime.utcnow()+dt.timedelta(days=days),
                'CreationDate':dt.datetime.utcnow(),'ProvisionsAllDevices':True,'Platform':['OSX'],
                'TeamIdentifier':[p.TEAM],'DeveloperCertificates':[b'fixture-cert'],
                'Entitlements':{'com.apple.application-identifier':p.TEAM+'.'+bundle,
                    'com.apple.developer.team-identifier':p.TEAM,
                    'com.apple.developer.networking.networkextension':['app-proxy-provider-systemextension'],
                    'com.apple.developer.system-extension.install':True}}
    def setUp(self):
        self.pin=patch.object(p,'LEAF',hashlib.sha1(b'fixture-cert').hexdigest().upper());self.pin.start()
    def tearDown(self): self.pin.stop()
    def test_rejects_invalid_identity_and_entitlements(self):
        self.assertTrue(p.eligible(self.profile(),p.HOST))
        for key,value in [('ExpirationDate',dt.datetime.utcnow()),('Platform',['iOS']),('ProvisionsAllDevices',False),('DeveloperCertificates',[b'other']),('TeamIdentifier',['WRONG'])]:
            d=self.profile();d[key]=value;self.assertFalse(p.eligible(d,p.HOST),key)
        for key,value in [('com.apple.application-identifier',p.TEAM+'.*'),('get-task-allow',True),('com.apple.developer.system-extension.install',False),('com.apple.developer.networking.networkextension',['app-proxy-provider'])]:
            d=self.profile();d['Entitlements'][key]=value;self.assertFalse(p.eligible(d,p.HOST),key)
    def test_manual_mapping_renewal_resume_and_tamper(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);source=root/'source';source.mkdir();state=root/'state';installed=root/'installed'
            for i,(bundle,days) in enumerate([(p.HOST,20),(p.HOST,40),(p.EXT,30)],1):
                d=self.profile(bundle,days,'00000000-0000-4000-8000-%012d'%i)
                (source/(str(i)+'.provisionprofile')).write_bytes(plistlib.dumps(d))
            with patch.object(p,'decode',lambda path:plistlib.loads(path.read_bytes())):
                p.prepare(state,[source],installed)
                options=plistlib.loads((state/'export.plist').read_bytes())
                self.assertEqual(options['signingStyle'],'manual')
                self.assertEqual(options['provisioningProfiles'][p.HOST],'00000000-0000-4000-8000-000000000002')
                self.assertEqual(set(options['provisioningProfiles']),{p.HOST,p.EXT})
                frozen=(state/'profiles.json').read_bytes()
                p.prepare(state,[],installed)
                self.assertEqual(frozen,(state/'profiles.json').read_bytes())
                (state/'export.plist').write_bytes(b'modified')
                with self.assertRaises(ValueError):p.verify(state,installed)
    def test_missing_extension_fails_before_freeze(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);source=root/'source';source.mkdir()
            (source/'host.provisionprofile').write_bytes(plistlib.dumps(self.profile()))
            with patch.object(p,'decode',lambda path:plistlib.loads(path.read_bytes())):
                with self.assertRaises(ValueError):p.prepare(root/'state',[source],root/'installed')
                self.assertFalse((root/'state/profiles.json').exists())

if __name__=='__main__':unittest.main()
