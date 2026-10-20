#!/usr/bin/env bash
set -euo pipefail
app="${CI_DEVELOPER_ID_SIGNED_APP_PATH:?Cloud Developer ID export required}"
if [[ "$app" != *.app ]]; then
  app="$(/usr/bin/find "$app" -maxdepth 4 -type d -name MihomoDNSProbe.app -print -quit)"
fi
[[ -d "$app" && "$app" == */MihomoDNSProbe.app ]]
/usr/bin/codesign --verify --deep --strict "$app"
for relative in '' \
  '/Contents/Library/SystemExtensions/dev.linsheng.mihomo-dns-probe.extension.systemextension' \
  '/Contents/Resources/Clients/MihomoDNSSelected.app' \
  '/Contents/Resources/Clients/MihomoDNSSelected.app/Contents/Library/LoginItems/MihomoDNSHelper.app' \
  '/Contents/Resources/Clients/MihomoDNSControl.app'; do
  code="$app$relative"
  /usr/bin/codesign --verify --strict "$code"
  details="$(/usr/bin/codesign -dvv "$code" 2>&1)"
  [[ "$details" == *'TeamIdentifier=89LGY6BD53'* && "$details" == *'Authority=Developer ID Application:'* ]]
done
/usr/bin/python3 - "$app" <<'PY'
import plistlib,subprocess,sys,pathlib
app=pathlib.Path(sys.argv[1])
for code in [app,app/'Contents/Library/SystemExtensions/dev.linsheng.mihomo-dns-probe.extension.systemextension']:
    ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(code)],stderr=subprocess.DEVNULL))
    required={'dns-proxy-systemextension','app-proxy-provider-systemextension'}
    assert set(ent['com.apple.developer.networking.networkextension'])==required
    assert not ent.get('com.apple.security.get-task-allow',False)
    if code==app: assert ent['com.apple.developer.system-extension.install'] is True
    else: assert ent['com.apple.security.app-sandbox'] is True
    profile=code/'Contents/embedded.provisionprofile'
    assert profile.exists(), 'missing provisioning profile'
    p=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(profile)]))
    assert p['TeamIdentifier']==['89LGY6BD53']
    assert required.issubset(p['Entitlements']['com.apple.developer.networking.networkextension'])
print('Independent DNS probe Developer ID signatures and provisioned capabilities verified')
PY
