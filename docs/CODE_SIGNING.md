# Code signing (stable Accessibility TCC)

HisCopy CI signs Release builds with a **persistent self-signed** certificate so
macOS Accessibility (and related TCC) can treat updates as the same app.

## Identity

| Field | Value |
| --- | --- |
| Common Name | `HisCopy Self-Signed` |
| Bundle ID | `io.github.bianyanhui.HisCopy` |
| GitHub secrets | `HISCOPY_SIGNING_CERTIFICATE_P12` (base64 PKCS#12), `HISCOPY_SIGNING_CERTIFICATE_PASSWORD` |

If those secrets are missing, the workflow falls back to **ad-hoc** signing (`codesign -s -`), which **does not** preserve TCC across builds.

## One-time after switching to this identity

1. Install HisCopy from the signed Release zip.
2. Open **系统设置 → 隐私与安全性 → 辅助功能**.
3. Remove **all** old HisCopy entries (ad-hoc builds each look like a different app).
4. Click **+** and add the new `HisCopy.app`.
5. Quit and reopen HisCopy, then **设置 → 重新检查权限**.

Later updates signed with the **same** certificate should keep Accessibility.

## Rotate / recreate the certificate (maintainers)

```bash
# After generating a new PKCS#12 with Code Signing EKU:
base64 -w0 hiscopy-codesign.p12 | gh secret set HISCOPY_SIGNING_CERTIFICATE_P12 -R BianYanhui/HisCopy
printf '%s' 'YOUR_P12_PASSWORD' | gh secret set HISCOPY_SIGNING_CERTIFICATE_PASSWORD -R BianYanhui/HisCopy
```

Keep a backup of the `.p12` and password offline. Losing them forces a new
identity and another one-time Accessibility re-authorization.

## Local unsigned builds

Xcode still uses manual / empty team for local debug. For a local stable sign,
import the same `.p12` into your login keychain and:

```bash
codesign --force --deep --sign "HisCopy Self-Signed" --timestamp=none path/to/HisCopy.app
```
