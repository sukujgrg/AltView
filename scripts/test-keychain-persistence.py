#!/usr/bin/env python3
"""Verify the real KeyStore across separate Developer ID signed sandboxed processes.

Requires a local signing identity and unlocked login Keychain. Uses three unique
test-only accounts under AltView's service and removes them even after failure.
No operator preferences, pairing entries, app version, or releases are changed.
"""
import argparse
import platform
import plistlib
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-identity', required=True,
                        help='Local Developer ID Application signing identity name or SHA-1.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    run_id = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix='altview-keychain-') as temporary:
        directory = Path(temporary)
        bundle = directory / 'KeychainPersistence.app'
        contents = bundle / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        executable = contents / 'MacOS' / 'KeychainPersistence'
        info = dict(CFBundleIdentifier='com.suku.AltView.KeychainFixture',
                    CFBundleExecutable=executable.name, CFBundleName='AltView Keychain Fixture',
                    CFBundlePackageType='APPL', CFBundleVersion='1', LSUIElement=True,
                    LSMinimumSystemVersion='12.0')
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = directory / 'fixture.entitlements'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-target', platform.machine() + '-apple-macos12.0',
                        '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(directory / 'ModuleCache'),
                        str(root / 'AltView/Network/SecureConnection.swift'),
                        str(root / 'scripts/fixtures/keychain-persistence.swift'), '-o', str(executable)], check=True)
        subprocess.run(['codesign', '--force', '--sign', args.signing_identity, '--options', 'runtime',
                        '--timestamp=none', '--entitlements', str(entitlements), str(bundle)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(bundle)], check=True)
        signature = subprocess.run(['codesign', '-d', '--verbose=4', str(bundle)],
                                   capture_output=True, text=True, check=True).stderr
        if 'Authority=Developer ID Application:' not in signature:
            raise RuntimeError('This fixture requires a Developer ID Application identity.')
        signed = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
        assert plistlib.loads(signed)['com.apple.security.app-sandbox'] is True

        def run(mode):
            # Each invocation has a fresh address space and no in-memory pairing.
            subprocess.run([str(executable), mode, run_id], check=True, timeout=20)

        try:
            for mode in ['save', 'read', 'update', 'read-updated']:
                run(mode)
        finally:
            run('cleanup')
        run('read-empty')
        print('PASS: Developer ID signed App Sandbox login Keychain save, relaunch, update, account isolation, and cleanup.')


if __name__ == '__main__':
    main()
