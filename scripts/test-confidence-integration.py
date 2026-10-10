#!/usr/bin/env python3
"""Run the actual three repositories' TLS senders/receiver with isolated fixture data.

Requires local Bonjour and neighboring checkouts; does not load operator preferences,
Keychain, apps, displays, or saved content. No source copies or protocol mocks.
"""
import argparse
import json
import platform
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eucaly', type=Path, default=root.parent / 'eucaly')
    parser.add_argument('--viewtheword', type=Path, default=root.parent / 'ViewTheWord')
    parser.add_argument('--sandbox-receiver', action='store_true',
                        help='Sign the isolated receiver with AltView App Sandbox permissions; needs codesign and local networking.')
    args = parser.parse_args()
    build = root / 'build' / 'ConfidenceIntegration'
    build.mkdir(parents=True, exist_ok=True)
    swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    shared = ['Protocol.swift', 'SnapshotMailbox.swift', 'SecureConnection.swift', 'PeerChannel.swift', 'SenderClient.swift', 'ReceiverDiscovery.swift', 'PairingStore.swift']
    receiver_sources = [root / 'AltView' / part for part in ['Core/Protocol.swift', 'Core/ReceiverState.swift', 'Core/SnapshotMailbox.swift', 'Network/SecureConnection.swift', 'Network/PeerChannel.swift', 'Network/ReceiverServer.swift', 'Network/ReceiverDiscovery.swift']]
    sources = {
        'receiver': receiver_sources + [root / 'scripts/fixtures/confidence-receiver.swift'],
        'eucaly': [args.eucaly / 'eucaly/AltView' / ('AltView' + name) for name in shared] + [root / 'scripts/fixtures/confidence-sender.swift'],
        'ViewTheWord': [args.viewtheword / 'ViewTheWord/AltView' / name for name in shared] + [root / 'scripts/fixtures/confidence-sender.swift'],
    }
    for role, files in sources.items():
        missing = [str(path) for path in files if not path.is_file()]
        if missing:
            raise RuntimeError('Missing integration sources: ' + ', '.join(missing))
        command = [swiftc, '-sdk', sdk, '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(build / 'ModuleCache'), '-o', str(build / role)]
        if role == 'eucaly':
            command += ['-D', 'EUCALY']
        subprocess.run(command + [str(file) for file in files], check=True)
    with tempfile.TemporaryDirectory(prefix='confidence-', dir=build) as temporary:
        directory = Path(temporary)
        identity = str(uuid.uuid4())
        processes = []
        logs = []
        try:
            receiver_executable = build / 'receiver'
            if args.sandbox_receiver:
                bundle_id = 'com.suku.AltView.ConfidenceIntegration'
                bundle = directory / 'ConfidenceReceiver.app'
                contents = bundle / 'Contents'
                (contents / 'MacOS').mkdir(parents=True)
                receiver_executable = contents / 'MacOS' / 'receiver'
                shutil.copy2(build / 'receiver', receiver_executable)
                info = plistlib.loads((root / 'AltView/Info.plist').read_bytes())
                info.update(CFBundleIdentifier=bundle_id, CFBundleExecutable='receiver',
                            CFBundleName='AltView Confidence Integration', CFBundlePackageType='APPL',
                            CFBundleVersion='1', LSMinimumSystemVersion='14.0')
                (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
                entitlements = plistlib.loads((root / 'AltView/AltView.entitlements').read_bytes())
                mach_key = 'com.apple.security.temporary-exception.mach-lookup.global-name'
                entitlements[mach_key] = [name.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle_id)
                                          for name in entitlements.get(mach_key, [])]
                # Only test command/status files need access outside the fixture
                # container. Network and process lookup use the app's real policy.
                entitlements['com.apple.security.temporary-exception.files.absolute-path.read-write'] = [str(directory.resolve()) + '/']
                entitlement_file = directory / 'receiver.entitlements'
                entitlement_file.write_bytes(plistlib.dumps(entitlements))
                subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlement_file), str(bundle)], check=True)
            for role in sources:
                log = (directory / (role + '.log')).open('w+')
                logs.append(log)
                executable = receiver_executable if role == 'receiver' else build / role
                processes.append(subprocess.Popen([str(executable), temporary, identity, role], stdout=log, stderr=log))

            def read(role='receiver'):
                try:
                    return json.loads((directory / (role + '-status.json')).read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    return {}

            def wait(description, predicate, seconds=30):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if any(process.poll() is not None for process in processes):
                        raise RuntimeError('Integration process exited: ' + description)
                    if predicate():
                        print('PASS:', description, flush=True)
                        return
                    time.sleep(0.05)
                raise AssertionError(description + ': ' + repr(read()))

            def send(role, command):
                destination = directory / (role + '-command')
                stage = destination.with_suffix('.tmp')
                stage.write_text(command)
                stage.replace(destination)

            wait('both real senders discover This Mac and connect without taking text', lambda: read().get('connections') == 2 and all(read(role).get('local') and read(role).get('connected') for role in ['eucaly', 'ViewTheWord']))
            assert read().get('owner') is None and read()['body'] == ''
            first_port = read()['port']
            send('eucaly', 'publish')
            wait('eucaly explicitly presents primary lyric', lambda: read().get('body') == 'Primary lyric' and read().get('confidence', {}).get('body') == 'Primary lyric')
            send('ViewTheWord', 'publish')
            wait('ViewTheWord explicitly takes text from eucaly', lambda: read().get('body') == 'Primary verse' and read().get('owner') == 'ViewTheWord')
            assert read()['confidence']['title'] == 'John 3:16' and read()['confidence']['footer'] == 'Primary translation'
            wait('both translations reach Confidence while Audience remains primary only', lambda: read().get('confidence', {}).get('secondary') == {'body': 'Secondary verse', 'footer': 'Secondary translation'} and read().get('body') == 'Primary verse')
            send('eucaly', 'hidden-navigation')
            send('ViewTheWord', 'hide')
            wait('audience blanking and hidden lyric browsing preserve the verse', lambda: read().get('body') == 'Primary verse' and not read().get('visible', True))
            assert read()['confidence']['body'] == 'Primary verse'
            assert read()['confidence']['secondary']['body'] == 'Secondary verse'
            send('ViewTheWord', 'primary-only')
            wait('removing secondary clears it while hidden Audience keeps primary', lambda: read().get('confidence', {}).get('secondary') is None and read().get('body') == 'Primary verse' and not read().get('visible', True))
            send('ViewTheWord', 'stop')
            wait('Stop clears text without restoring lyrics', lambda: read().get('owner') is None and read().get('body') == '')
            send('eucaly', 'next')
            wait('new explicit lyric can take text after Stop', lambda: read().get('confidence', {}).get('body') == 'Next primary lyric')
            send('eucaly', 'stop')
            wait('both presentations stopped', lambda: read().get('owner') is None)
            send('receiver', 'pause')
            wait('receiver pause clears stale text', lambda: read().get('port') is None and not read().get('confidence', {}).get('body'))
            send('receiver', 'resume')
            wait('real senders rediscover changed dynamic loopback port without taking text', lambda: read().get('port') is not None and read()['port'] != first_port and read().get('connections') == 2 and all(read(role).get('connected') and read(role).get('port') == read()['port'] for role in ['eucaly', 'ViewTheWord']))
            assert read().get('owner') is None and read()['body'] == ''
            send('ViewTheWord', 'publish')
            wait('Scripture projects after restart', lambda: read().get('body') == 'Primary verse')
            wait('both translations restore after fresh negotiation', lambda: read().get('confidence', {}).get('secondary', {}).get('body') == 'Secondary verse')
            send('eucaly', 'disconnect')
            wait('disconnecting eucaly preserves Scripture', lambda: read().get('connections') == 1 and read().get('body') == 'Primary verse')
            send('eucaly', 'reconnect')
            wait('connect-only reconnect preserves Scripture', lambda: read().get('connections') == 2 and read().get('body') == 'Primary verse' and read().get('owner') == 'ViewTheWord')
            send('receiver', 'clear')
            wait('Clear cancels stale presentation restoration', lambda: read().get('owner') is None and not read().get('confidence', {}).get('body'))
            send('eucaly', 'media')
            wait('local media report has verified loopback process identity and no lyrics', lambda: read().get('mediaWindow') == 77 and read().get('localSource') and read()['confidence']['body'] == '')
            assert read().get('mediaSourceIssue') is None
            send('eucaly', 'hide')
            wait('media audience Hide retains projection mode', lambda: read().get('mediaWindow') == 77 and not read().get('visible', True))
            send('eucaly', 'recreated')
            wait('recreated window replaces the exact reported source', lambda: read().get('mediaWindow') == 88 and read().get('localSource'))
            send('eucaly', 'clear')
            wait('Clear removes obsolete media', lambda: read().get('mediaWindow') is None and read()['confidence']['body'] == '')
            send('eucaly', 'media')
            wait('fresh media can follow Clear', lambda: read().get('mediaWindow') == 77)
            send('ViewTheWord', 'next')
            wait('existing text sender replaces media through normal ownership', lambda: read().get('mediaWindow') is None and read().get('owner') == 'ViewTheWord')
            wait('media takeover restores dual Confidence without adding secondary to Audience', lambda: read().get('confidence', {}).get('secondary', {}).get('body') == 'Secondary verse' and read().get('body') == 'Next primary verse')
            send('eucaly', 'reclaim-media')
            wait('Eucaly can explicitly reclaim media', lambda: read().get('mediaWindow') == 77)
            assert read()['confidence'].get('secondary') is None
            send('eucaly', 'disconnect')
            wait('presenter disconnect clears media without restoring Scripture', lambda: read().get('mediaWindow') is None and read().get('owner') is None)
            print('All real-source confidence integration checks passed.', flush=True)
        except Exception:
            for log in logs:
                log.flush(); log.seek(0)
                print(log.name + '\n' + log.read()[-6000:])
            raise
        finally:
            for process in processes:
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            for log in logs:
                log.close()


if __name__ == '__main__':
    main()
