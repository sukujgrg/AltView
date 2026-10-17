#!/usr/bin/env python3
"""Measure the real SCK -> H.264/AAC/SRT localhost -> AltView native renderer.

Run after `make build` in AltView. Requires the adjacent eucaly checkout,
macOS 14.4+ and an unlocked GUI session. Captures only its own two fixture
windows; existing app state, preferences and pairing are unused.
Results distinguish source cadence, queue loss, decode and native presentation.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import json

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video', type=Path)
    parser.add_argument('--seconds', type=float, default=20)
    parser.add_argument('--start-at', type=float, default=0, help='Seek past an intro before playback')
    parser.add_argument('--recovery-ms', type=int, default=80, help='SRT recovery buffer, matching the receiver setting')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--products', type=Path, default=ROOT / 'build/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/AltView/BuildProductsPath/Release',
                        help='Built streaming libraries; defaults to the Release archive products')
    parser.add_argument('--capture-only', action='store_true', help='Diagnostic: drain capture without encoding or playback')
    parser.add_argument('--minimum-decoded-fps', type=float, help='Fail below this decoded frame rate')
    args = parser.parse_args()
    if not args.video.is_file() or not 0 < args.seconds <= 300:
        parser.error('Provide an existing video and 0 < seconds <= 300')
    if not 20 <= args.recovery_ms <= 1000:
        parser.error('Provide 20 <= recovery-ms <= 1000')
    work = ROOT / 'build/media-cadence'
    work.mkdir(parents=True, exist_ok=True)
    products = args.products.resolve()
    if not (products / 'SRTHaishinKit.o').is_file():
        parser.error('Run make build first, or pass --products with built streaming libraries')
    # Compile the exact production presentation/canvas declarations, without
    # the controller's app-wide navigation and pairing dependencies.
    canvas = (ROOT / 'AltView/UI/EucalyMediaOutput.swift').read_text().split('\nstruct MediaAudioDevice:', 1)[0]
    (work / 'EucalyMediaCanvas.swift').write_text(canvas)
    (work / 'main.swift').write_text((ROOT / 'scripts/verify-media-cadence.swift').read_text())
    app = work / 'MediaCadence.app'
    executable = app / 'Contents/MacOS/MediaCadence'
    executable.parent.mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.suku.MediaCadence', 'CFBundleName': 'MediaCadence',
        'CFBundleExecutable': 'MediaCadence', 'CFBundlePackageType': 'APPL',
        'NSHighResolutionCapable': True,
    }))
    eucaly = ROOT.parent / 'eucaly/eucaly/Output'
    sources = [ROOT / 'AltView/Media/SRTMedia.swift', ROOT / 'AltView/Media/SRTMediaPlayback.swift',
               work / 'EucalyMediaCanvas.swift', eucaly / 'SRTAudienceCapture.swift',
               eucaly / 'SRTProgramAudio.swift', work / 'main.swift']
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-O', '-g', '-I', str(products),
               '-I', str(products / 'include'),
               '-F', str(products), '-L', str(products), '-lsrt', '-lc++', '-framework', 'OpenSSL',
               '-Xlinker', '-rpath', '-Xlinker', str(products), '-o', str(executable)]
    command += [str(products / (name + '.o')) for name in ['HaishinKit', 'SRTHaishinKit', 'Logboard', 'SRT']]
    subprocess.run(command + list(map(str, sources)), check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    args.report.unlink(missing_ok=True)
    subprocess.run(['/usr/bin/open', '-W', '-n', '--stdout', str(work / 'fixture-runtime.log'),
                    '--stderr', str(work / 'fixture-runtime.log'), str(app), '--args',
                    str(args.video.resolve()), str(args.seconds), str(args.report.resolve()),
                    'capture' if args.capture_only else 'video', str(args.start_at), str(args.recovery_ms)],
                   check=True, timeout=args.seconds + 60)
    report = json.loads(args.report.read_text())
    if args.capture_only:
        return
    failures = []
    if not report['fixture_active'] or not report['source_key_window']:
        failures.append('Fixture lost focus; keep both fixture windows visible for a valid presentation check')
    for name in ['sender_mailbox_drops', 'receiver_mailbox_drops', 'renderer_overload_flushes',
                 'native_dropped_frames', 'audio_rebuffers']:
        if report[name] != 0:
            failures.append(f'{name}={report[name]}')
    if report['capture_error'] or report['audio_errors']:
        failures.append('Capture/audio output failed')
    if not report['native_metrics_available'] or report['native_total_frames'] <= 0:
        failures.append('No native presentation metrics')
    if args.minimum_decoded_fps is not None and report['decoded_fps'] < args.minimum_decoded_fps:
        failures.append(f"Decoded {report['decoded_fps']:.3f} fps < {args.minimum_decoded_fps}")
    if not report.get('displayed_image_available'):
        failures.append('No image was actually displayed')
    if failures:
        raise SystemExit('Cadence check failed: ' + '; '.join(failures))


if __name__ == '__main__':
    main()
