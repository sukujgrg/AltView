#!/usr/bin/env python3
"""Run the actual three repositories' TLS senders/receiver with isolated fixture data.

Requires local Bonjour and neighboring checkouts; does not load operator preferences,
Keychain, apps, displays, or saved content. No source copies or protocol mocks.
"""
import argparse
import json
import platform
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eucaly', type=Path, default=root.parent / 'eucaly')
    parser.add_argument('--viewtheword', type=Path, default=root.parent / 'ViewTheWord')
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
            for role in sources:
                log = (directory / (role + '.log')).open('w+')
                logs.append(log)
                processes.append(subprocess.Popen([str(build / role), temporary, identity, role], stdout=log, stderr=log))

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
            send('eucaly', 'hidden-navigation')
            send('ViewTheWord', 'hide')
            wait('audience blanking and hidden lyric browsing preserve the verse', lambda: read().get('body') == 'Primary verse' and not read().get('visible', True))
            assert read()['confidence']['body'] == 'Primary verse'
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
            send('eucaly', 'disconnect')
            wait('disconnecting eucaly preserves Scripture', lambda: read().get('connections') == 1 and read().get('body') == 'Primary verse')
            send('eucaly', 'reconnect')
            wait('connect-only reconnect preserves Scripture', lambda: read().get('connections') == 2 and read().get('body') == 'Primary verse' and read().get('owner') == 'ViewTheWord')
            send('receiver', 'clear')
            wait('Clear cancels stale presentation restoration', lambda: read().get('owner') is None and not read().get('confidence', {}).get('body'))
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
