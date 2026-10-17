#!/usr/bin/env python3
"""Real TLS interoperability against the production AltView receiver.

Requires adjacent eucaly and ViewTheWord checkouts. Uses synthetic fixture keys,
loopback sockets and temporary files only; no user Keychain/preferences or output
windows. Compile the current production sources, not a reference receiver clone.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]

COMMON = r'''
import Foundation
import Network
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
func write(_ object: [String: Any], _ name: String) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    try! data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
}
func command(_ name: String) -> String? {
    let url = directory.appendingPathComponent(name + ".command")
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: url)
    write(["action": value], name + "-ack"); return value
}
'''
RECEIVER = COMMON + r'''
let identity = UUID(uuidString: CommandLine.arguments[2])!
var code = Data("ABCD2345".utf8)
var boundPort: UInt16 = 0
var mediaPort = 10000
var mediaKey = "integration-media-v3-secret"
var mediaReady = false
let receiver = ReceiverServer(receiverID: identity) { status in
    if let port = status.port { boundPort = port }
    write(["listening": status.listening, "port": Int(status.port ?? 0),
        "connections": status.connections, "owner": status.ownerID?.uuidString ?? "",
        "body": status.content.body], "receiver")
}
func offer() {
    receiver.updateMediaOffer(MediaOffer(receiverID: identity, port: mediaPort, ready: mediaReady, passphrase: mediaKey))
}
receiver.start(name: "Integration receiver", key: code, advertise: false)
offer()
let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
    switch command("receiver") {
    case "ready": mediaReady = true; offer()
    case "endpoint": mediaPort = 12000; offer()
    case "restart": receiver.start(name: "Integration receiver", key: code, port: boundPort, advertise: false)
    case "reset":
        code = Data("WXYZ6789".utf8); mediaKey = "integration-rotated-media-secret"; mediaReady = false
        receiver.start(name: "Integration receiver", key: code, port: boundPort, advertise: false); offer()
    case "quit": receiver.stop(); exit(0)
    default: break
    }
}
RunLoop.main.run()
'''
SENDER = COMMON + r'''
let name = CommandLine.arguments[2]
let port = UInt16(CommandLine.arguments[3])!
let expected = UUID(uuidString: CommandLine.arguments[4])!
var connectionID = UUID()
var code = Data("ABCD2345".utf8)
let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
let sender = AltViewSenderClient(name: name) { status in
    var report: [String: Any] = ["connected": status.connected, "owns": status.ownsOutput,
        "accepted": status.feedback.accepted, "receiverID": status.receiverID?.uuidString ?? "",
        "failed": status.failureReason != nil, "message": status.message, "waiting": status.waitingToRetry]
    MEDIA_REPORT
    write(report, name)
}
func connect() { connectionID = UUID(); sender.connect(to: endpoint, key: code, expectedReceiverID: expected, connectionID: connectionID) }
func take() { TAKE }
func stop() { STOP }
connect()
let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
    switch command(name) {
    case "take": take()
    case "stop": stop()
    case "disconnect": sender.disconnect()
    case "repair": sender.disconnect(); code = Data("WXYZ6789".utf8); connect()
    case "quit": sender.disconnect(); exit(0)
    default: break
    }
}
RunLoop.main.run()
'''


def compile_executable(folder, name, sources, main):
    work = folder / name
    work.mkdir()
    entry = work / 'main.swift'
    entry.write_text(main)
    result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-o', str(work / name),
                             *map(str, sources), str(entry)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return work / name


def main():
    with tempfile.TemporaryDirectory(prefix='altview-pairing-integration-') as tmp:
        folder = Path(tmp)
        receiver_files = [ROOT / 'AltView' / file for file in [
            'Core/Protocol.swift', 'Core/ReceiverState.swift', 'Core/SnapshotMailbox.swift',
            'Network/PeerChannel.swift', 'Network/SecureConnection.swift',
            'Network/ReceiverDiscovery.swift', 'Network/ReceiverServer.swift']]
        receiver = compile_executable(folder, 'receiver', receiver_files, RECEIVER)
        executables = {}
        for app, path, prefix in [('eucaly', 'eucaly/eucaly/AltView', 'AltView'),
                                  ('scripture', 'ViewTheWord/ViewTheWord/AltView', '')]:
            base = ROOT.parent / path
            filenames = ['Protocol', 'SnapshotMailbox', 'PeerChannel', 'SecureConnection', 'ReceiverDiscovery', 'SenderClient']
            sources = [base / (prefix + file + '.swift') for file in filenames]
            if app == 'eucaly':
                media = '''report["hasMedia"] = status.media != nil
    report["mediaReady"] = status.media?.ready ?? false
    report["mediaPort"] = status.media?.port ?? 0
    report["freshHost"] = status.mediaHost == "127.0.0.1"
    report["mediaMatches"] = status.media?.passphrase == "integration-media-v3-secret"
    report["rotatedMedia"] = status.media?.passphrase == "integration-rotated-media-secret"'''
                take = '''let content = AltViewDisplayContent(body: name)
    let id = UUID(); sender.submit(content, submissionID: id); sender.takeOutput(submission: .init(id: id, content: content))'''
                stop = 'sender.releaseOutput()'
            else:
                media = 'report["hasMedia"] = false'
                take = 'sender.submit(.init(connectionID: connectionID, content: .init(body: name), intent: UUID()))'
                stop = 'sender.submit(.init(connectionID: connectionID, content: nil, intent: nil))'
            body = SENDER.replace('MEDIA_REPORT', media).replace('TAKE', take).replace('STOP', stop)
            executables[app] = compile_executable(folder, app, sources, body)
        processes = []
        def send(name, action):
            (folder / (name + '-ack.json')).unlink(missing_ok=True)
            pending = folder / (name + '.pending')
            pending.write_text(action)
            pending.replace(folder / (name + '.command'))
            wait(name + ' processed ' + action, lambda: state(name + '-ack').get('action') == action)
        def state(name):
            try:
                return json.loads((folder / (name + '.json')).read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                return {}
        def wait(label, condition, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if condition():
                    return
                if any(p.poll() is not None for p in processes):
                    raise AssertionError(f'{label}: a fixture exited')
                time.sleep(.02)
            raise AssertionError(f'{label}: timed out; state={ {n:state(n) for n in ["receiver", "eucaly", "scripture"]} }')
        try:
            identity = str(uuid.uuid4()).upper()
            processes.append(subprocess.Popen([str(receiver), str(folder), identity]))
            wait('receiver listening', lambda: state('receiver').get('listening'))
            port = str(state('receiver')['port'])
            for app, exe in executables.items():
                processes.append(subprocess.Popen([str(exe), str(folder), app, port, identity]))
            wait('both senders pair without ownership', lambda: state('receiver').get('connections') == 2 and all(state(n).get('connected') for n in executables))
            assert state('receiver')['owner'] == ''
            assert state('eucaly')['hasMedia'] and state('eucaly')['mediaMatches'] and state('eucaly')['freshHost']
            assert not state('eucaly')['mediaReady'] and not state('scripture')['hasMedia']
            send('receiver', 'ready')
            wait('readiness provisioned without take', lambda: state('eucaly').get('mediaReady'))
            assert state('receiver')['owner'] == ''
            send('receiver', 'endpoint')
            wait('fresh endpoint provisioned', lambda: state('eucaly').get('mediaPort') == 12000)
            send('scripture', 'take')
            wait('scripture output', lambda: state('receiver').get('body') == 'scripture' and state('scripture').get('accepted'))
            send('eucaly', 'take')
            wait('lyrics takeover', lambda: state('receiver').get('body') == 'eucaly' and state('eucaly').get('accepted'))
            send('eucaly', 'stop')
            wait('stop release', lambda: state('receiver').get('owner') == '')
            send('receiver', 'restart')
            wait('restart interrupts control', lambda: not state('eucaly').get('connected', True))
            wait('reconnect both', lambda: state('receiver').get('connections') == 2 and all(state(n).get('connected') for n in executables), timeout=35)
            time.sleep(.2)
            assert state('receiver')['owner'] == ''
            send('receiver', 'reset')
            wait('reset revokes old credentials', lambda: all(not state(n).get('connected', True) for n in executables))
            assert state('receiver')['owner'] == ''
            wait('old code rejected', lambda: all(state(n).get('failed') for n in executables))
            assert not state('eucaly')['hasMedia']
            for app in executables:
                send(app, 'repair')
            wait('new code repairs both senders', lambda: state('receiver').get('connections') == 2 and all(state(n).get('connected') for n in executables))
            wait('media credential rotated', lambda: state('eucaly').get('rotatedMedia'))
            assert state('receiver')['owner'] == '' and not state('eucaly')['mediaReady']
            for app in executables:
                send(app, 'take')
                wait(app + ' works after reset', lambda: state('receiver').get('body') == app and state(app).get('accepted'))
                send(app, 'stop')
                wait(app + ' releases after reset', lambda: state('receiver').get('owner') == '')
            for app, exe in executables.items():
                alias = 'mismatch-' + app
                processes.append(subprocess.Popen([str(exe), str(folder), alias, port, str(uuid.uuid4())]))
                send(alias, 'repair')
                wait(alias + ' rejects wrong pinned identity', lambda: state(alias).get('failed') and not state(alias).get('connected'))
                assert not state(alias).get('hasMedia')
            print('PASS: actual AltView receiver + eucaly + ViewTheWord: connect-only pairing, media provisioning/readiness/endpoint refresh, independent text takeover, reconnect, reset, credential rotation and repair.')
        finally:
            for process in processes:
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()

if __name__ == '__main__':
    main()
