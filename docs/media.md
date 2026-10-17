# eucaly Media on macOS

eucaly Media replaces AltView’s Confidence page and clock. It receives the picture
from an existing eucaly **Audience** output, including live video and images,
with live video file audio. AltView’s eucaly Lyrics text receiver remains independent.

## Connect the Macs

1. Update AltView, eucaly and ViewTheWord together. Protocol 3 deliberately
   replaces the previous pairing protocol. Connect the Macs to the same local
   network; Ethernet is recommended.
2. In AltView, leave Connections receiving. Its eight-character receiver code
   authenticates setup for both Lyrics and Media. Enter this code, not an SRT
   passphrase: AltView generates and shares its separate 32-character SRT secret
   automatically. Pairing does not open a display
   or start Media. AltView still opens on **eucaly Media** by default.
3. In eucaly Settings → Manage Outputs, add a Lyrics or Media output. Choose the
   AltView receiver and enter its code directly below the receiver picker, then
   click **Connect**. Pairing works while either output is disabled. Leave the code empty to
   reconnect with its saved Keychain pairing.
4. Assign the same receiver to Lyrics, Media, or both, then enable each desired
   output separately. Media-only use needs no Lyrics row or Lyrics lease. Media
   still uses an existing local Audience window as its picture source.
5. For Media, select the source Audience output and a 50/60 fps maximum to match production.
   In AltView choose the HDMI display and audio device, open that display, and
   click **Start Receiving**. Enable the eucaly Media output and **Show Slides**
   (or **Retry Media** after resolving capture permission). Configuration and
   enablement alone never start capture or transmission.

Start with an **80 ms recovery buffer** at both ends. **20 ms · Wired LAN** is
available for a clean wired installation; the measured limits below explain why
it is a choice, rather than the default. Wi-Fi testing can use 120–200 ms. The
larger SRT recovery request wins, so change both apps to evaluate 20 ms.

The selected Audience output must be enabled, assigned and open. Its monitor
keeps its resolution; only the network copy is scaled to 1080p. Preview browsing
never becomes the source. A changed source or settings requires a fresh Show or
Retry Media. Include background music applies immediately to a running stream.

## Pairing and media credentials

There is one stable `receiverID`, advertised by `_altview._tcp`. eucaly maintains
one authenticated control channel per receiver, independently of output enablement
and publishing. Pairing, discovery, restoration and configuration never take text
ownership or start SRT. ViewTheWord uses the same protocol and receiver pinning
for scripture; it does not negotiate Media or receive its credential.

AltView generates a separate random 32-character media secret and saves it in
Keychain before provisioning it. This is not the short pairing code padded to fit
SRT. `mediaProvisioningV1` negotiates a `media` object in authenticated welcome and
feedback messages: receiver UUID, current port, readiness, endpoint hostname and
secret. Readiness becomes true only after the real SRT listener binds. The sender
uses the actual authenticated TCP peer's IPv4 address, or the receiver's
provisioned local hostname when TCP chose IPv6. SRT currently needs IPv4
connectivity; hostnames are resolved afresh for each attempt.

The receiver associates its Keychain media secret with the stable receiver UUID
and pairing-code digest. eucaly stores the control key, receiver pin and negotiated
media secret together in its receiver Keychain record. Secrets never enter
Bonjour, preferences, saved output JSON or application logs. The saved media
output contains receiver identity and stream settings; its old host/port cannot
authorize a connection. A currently authenticated, ready control session is
required before every SRT attempt. Disconnection clears live provisioning; an
established stream checks control readiness/endpoint changes during playback.

**Disconnect Receiver** stops that receiver's Media transmission and releases
its Lyrics. Re-pairing/explicit reconnect requires Show or Retry Media again.
Transient network loss can resume a previously started stream on the same source.
**Reset Pairing** in AltView stops text and Media, disconnects senders, and rotates
both credentials. The receiver UUID and display assignments remain. Every sender
must enter the new code; old secrets cannot reconnect. A reset that cannot save
its new code stays stopped and reports failure. A Keychain save failure on a
sender is visible and retains only that process's session pairing.

Previous independent `mediaReceiverID` associations, per-output SRT passwords,
manual media endpoints and `_altviewmedia._udp` discovery are retired. They are
not silently associated by Mac name or address. For an existing Media row, select
the Mac's current control receiver and pair once in its output settings. Existing
stable control pairings remain usable when their key and receiver UUID match;
missing or mismatched pins require explicit pairing. The old single-output
preference migration is removed. No compatibility downgrade is attempted.

## Audio

Live video file audio is included, following the live player’s volume, mute and
pause controls. Images have silence. **Include background music** is a per-output
eucaly option, saved **off by default**. Preview audio, other apps, captured-app
audio and live webpage audio are excluded. Muted visual background videos stay
muted. The network stream includes continuous silent audio while a still image
or paused video is displayed, so switching media does not change its format.

AltView decodes the stream once and plays audio once, shared by its preview and
HDMI display. Choose the HDMI audio device before Start Receiving. To change a
device, stop receiving, use **Refresh Audio Devices** and select it again; reconnect a missing saved device or
choose another explicitly. **Mute received audio** affects AltView playback.

Decoded video goes directly to AltView's timed display layer, using the same
timestamp origin as audio. There is no additional library display clock or
90-frame video queue. A mailbox retains up to eight decoded pictures to preserve
short bursts, discarding the oldest pictures if the UI falls behind. The sender
still keeps only its newest unencoded picture.

New captured pictures use ScreenCaptureKit's WindowServer display clock
(falling back to the sample timestamp) and are sent as they arrive. Presentation
timestamps follow unique ticks at the lower of the native display rate and the
selected 50/60 fps ceiling, removing capture-event jitter while retaining gaps.
Native displays already within that ceiling bypass the redundant rate gate.
There is no second timer sampling the latest picture. Still or paused
slides receive a low-rate keepalive after 500 ms without a new picture. The
composed Audience output determines activity, including overlays and transitions;
the underlying movie's frame rate alone does not describe the full composition.
This avoids unnecessary picture encoding during stills without promising a
particular reduction in total latency. Transient capture suspension can recover
for up to three seconds; suspended pictures are not repeated as keepalives.

The MPEG-TS writer anchors both tracks to the first unencoded source timestamp.
Audio carries the transport clock while still pictures reduce video activity.
Separate audio/video encoder startup times must not create independent zero
points and move video hundreds of milliseconds ahead of the audio clock.
PES timestamps subtract the common origin with rational `CMTime` arithmetic
before rounding to 90 kHz, keeping exact 60 fps intervals at 1,500 transport ticks.
The presentation layer leaves live frame durations unspecified: the previous
PTS interval inferred by the TS reader cannot describe the next frame's duration.
The display layer's readiness flag is advisory for this real-time input: short
bursts are enqueued without silently dropping pictures. At most 24 future frame
deadlines are tracked per canvas; genuine overload flushes that queue while
retaining the displayed picture. The decoded mailbox still bounds UI overload.

The receiver starts audio with 80 ms of playout lead time, then queues PCM buffers
contiguously on the audio device's sample clock. MPEG-TS timestamp rounding must
not create a separate gap or overlap at every AAC packet boundary. An underrun,
source timestamp discontinuity or excessive queue restarts the shared audio/video
origin; queued audio is bounded to 300 ms. This playout lead time is separate from
the SRT recovery buffer. Recovery flushes old video deadlines while retaining the
last displayed picture until a replacement arrives, preventing brief black flashes
in both preview and the external display. Late, future and out-of-order video
callbacks do not restart clean audio. Pictures queued before a recovered audio
origin are discarded. Stop Receiving and disconnection still clear the picture.
Playback recovery events appear in macOS unified logging
under subsystem `com.suku.AltView`, category `media-playback`, without media content
or credentials. Native display-layer recovery uses category `media-video`.

## Recovery and limits

**Stop Receiving** immediately clears media picture and sound and closes the SRT
listener; it does not stop eucaly Lyrics text. **Close Display** closes only the HDMI
window. eucaly Stop, disabled/deleted outputs and lost source windows retire
capture/audio queues. AltView clears a disconnected or silent video source after
approximately three seconds and waits for reconnection. A network outage retries
while the original source is still valid. Capture failure requires Retry Media.

The transport is H.264/AAC in MPEG-TS over encrypted SRT, with bounded application
mailboxes and socket queues and a short playout buffer. Both ends must use the
same passphrase; it is stored in Keychain, never in saved output JSON. SRT listens
on the configured UDP port. If a firewall blocks it, allow incoming AltView
connections. A wrong secret or occupied port can appear as a connection failure;
verify both before retrying. SRT media does not use text leases. Connection and
socket errors remain visible during retries; discovery errors allow manual addressing.

20 ms is available for a clean wired LAN; increasing the recovery buffer improves packet
recovery at the cost of delay. These values are transport buffers, **not measured
end-to-end latency** or a promise of NDI-equivalent delay. Measure video/audio
synchronization and camera alignment on the actual two Macs, Ethernet network and
ATEM before live use. Sender capture, hardware codecs, audio hardware and HDMI
also contribute latency. The receiver does not perform ATEM delay compensation.

## Recovery-buffer implementation and measurements (18 October 2026)

Both vendored `SRTSocketURL` copies now apply `transtype` first and remaining
options deterministically. Previously dictionary iteration could apply
`transtype=live` after `latency`, resetting receive latency to SRT's 120 ms default.
Real encrypted socket regressions in **both apps** now assert the actual negotiated
values, rather than just URL construction:

| Receiver / sender request | Negotiated recovery buffer |
| --- | --- |
| 20 / 20 ms | 20 ms |
| 40 / 40 ms | 40 ms |
| 80 / 20 ms | 80 ms |
| 20 / 80 ms | 80 ms |

The production H.264/AAC motion loopback at 20 ms decoded **158/180** submitted
1080p60 frames in the focused run. AAC measured RMS **0.070708**, maximum adjacent
sample step **0.005851**, and **0** timestamp-gap samples after startup. Frame
counts reflect cold hardware-codec startup and machine load; this is functional
local transport evidence, not a two-Mac frame-rate or HDMI-latency measurement.

The separate playback scheduler was swept through real device-clock rendering,
with the test tone silenced downstream. Each run delayed audio startup by 150 ms,
used three-packet batches, one-sample MPEG-TS timestamp rounding, and injected
arrival jitter of 0/60/10/30 ms. The focused run measured:

| Playback lead | Underruns during delivery | Longest interior silence, captured samples |
| --- | --- | --- |
| 20 ms | 4 | 2270 |
| 40 ms | 1 | 2104 |
| 60 ms | 1 | 2215 |
| 80 ms | 0 | 0 |

**80 ms remains the production playback lead**. It was the only candidate to
finish the focused sweep without an underrun or interior silence. With all three
app suites competing concurrently, even 80 ms recorded one underrun (2441 captured
silence samples); host/device load matters as well as injected network jitter.
The sweep records those observations rather than imposing a hardware timing
performance gate on the functional suite. Smaller leads do not have sufficient
evidence for a default change. The 20 ms UI choice
changes SRT recovery only. Recovery tests also retain the last video picture,
restart the shared A/V origin after a forced underrun, reject stale callbacks,
recover source discontinuities and bound queued audio to 300 ms.

These are different stages: negotiated SRT packet recovery, decoder delivery,
scheduled audio/video playback, and physical HDMI/audio output. No total latency
is inferred by adding the configured buffers. Remaining checks are two-Mac wired
loss/retransmission/late-drop statistics, sustained clock drift and underruns,
physical HDMI audio routing, camera/ATEM alignment and end-to-end latency.

`python3 scripts/test-pairing-integration.py` compiles the production AltView
receiver and both adjacent sender checkouts. It exercises actual encrypted
connect-only pairing, provisioning, readiness/endpoint refresh, text takeover,
reconnect, reset, credential rotation, repair and wrong receiver pins without
using the user's Keychain, preferences or display windows. App suites separately
cover Keychain persistence, independent disabled output setup and listener binding.

The first version is Apple Silicon macOS only. Transport and decoded playback are separated
from AppKit and window capture, and the underlying dependencies include tvOS
slices. An Apple TV UI/HDMI host is future work; no tvOS app is delivered here.

## Verification

Automated tests cover encrypted SRT H.264/AAC loopback, repeated decoded 1080p
frames, stopping/rebinding a waiting listener, bounded queues, saved output
settings and migration, shared live-file audio taps and pause cleanup. Existing
eucaly Lyrics text, ownership, display assignment and layout regressions also run.
Device-clock rendering tests measure the PCM after the playback scheduler, with
test tones silenced downstream. They cover rounded packet timestamps, delayed
startup, batched delivery, underrun recovery, source discontinuities and queue bounds.
The transport test sends changing synthetic pictures at 60 fps through the real
1080p hardware encoder, encrypted socket and decoder, alongside continuous audio.
It checks presentation order and continued delivery, and reports decoded frame
counts separately because cold encoder startup and machine load affect throughput.
Scheduling tests verify that future video timestamps reach the host promptly and
that short decoded bursts remain ordered and bounded.
Picture-recovery regressions check delayed audio startup, underruns, stale video
callbacks and explicit stop; a native display-layer test verifies that a timeline
flush retains the rendered image.
Physical capture permission, two-Mac loss/recovery, real HDMI audio routing and
end-to-end latency require a hardware rehearsal.

For a sustained local check after `make build`, run:

```sh
python3 scripts/verify-media-cadence.py /path/to/countdown-60fps.mp4 \
  --seconds 30 --minimum-decoded-fps 59 --report build/countdown-cadence.json
```

The private fixture compiles the production capture, transport, playback and
canvas against Release streaming libraries. It uses encrypted 1080p localhost
SRT, a five-second warmup, native display-layer metrics, and a saved displayed
image. The video must continue beyond the warmup and measurement; looping would
invalidate the check. `--start-at 20` can skip an intro. Use a source-appropriate
FPS floor for a 30 fps file; `--recovery-ms 20` matches the Wired LAN setting.
Queue loss, native drops, overload flushes and audio
rebuffers fail the check. The audio bus is silent, so this does not replace an
audible program-audio or HDMI test. Run without competing builds or captures.

## Performance review (2026-10-17)

The existing capture path uses 1080p NV12 surfaces, a three-frame capture queue,
hardware H.264 with frame reordering disabled, and a single pending source frame.
Receiver preview and projection share one decoder and one audio engine. The audio
lead time remains 80 ms after the receiving Mac's speaker test confirmed clean sound.

This pass removes the duplicate video scheduler, moves blocking socket reads off
Swift's cooperative executor, eliminates a socket-actor status query per datagram,
and parses H.264/HEVC units once per frame. The release-mode NAL parser benchmark
(`testAnnexBParserPreservesNALUnitsInLargeFrames`, 600 × 50,016 bytes) took 70.6 ms
before and 17.8 ms after on the development Mac. This is a synthetic parser
measurement, not a fourfold improvement in whole-app performance or physical latency.

Unrelated random pixels in every stress-test frame caused VideoToolbox to report
explicit frame drops at the current bitrate while the receiver decoded almost
every delivered frame. Codec submission used about 0.31 s of the 3 s run. This is
consistent with the low-latency encoder's bitrate/quality tradeoff described in
[Apple's VideoToolbox overview](https://developer.apple.com/videos/play/wwdc2021/10158/).
The sustained-throughput regression therefore uses a detailed moving image;
the existing bitrate, resolution and quality settings remain unchanged.

Remaining areas to measure on the actual installation:

- Multiple media destinations currently own separate capture and encoder sessions.
  Sharing capture/encoding for matching source and codec settings is the largest
  architectural opportunity when several receivers are active; audio inclusion,
  per-destination secrets, reconnect and independent teardown must remain separate.
- Capture uses a timer to repeat still images and pace output. Measure its phase
  relative to capture delivery before changing it; direct delivery needs to preserve
  still-picture cadence and audio synchronization.
- Long-duration runs should measure sender/receiver audio-clock drift, rebuffer
  events, network loss, CPU/GPU load and memory. Lowering playout or SRT recovery
  buffers without those measurements can trade clean audio for dropouts.
- The application mailboxes and socket queues are bounded. Some vendor codec and
  muxer AsyncStreams remain unbounded between serial consumers; sustained overload
  needs profiling and an explicit reconnect/backpressure policy, not arbitrary
  dropping of compressed reference frames.

`Vendor/MediaStreaming/PATCHES.md` records upstream versions and local fixes.
**AltView → Third-Party Notices…** lists BSD, MPL and Apache notices and SRT source
availability. No NDI SDK is included.


## Countdown cadence verification (2026-10-18)

The final production capture, encrypted H.264/AAC localhost transport, playback
and native canvas were measured against Release streaming libraries on this M1
Mac with 60 Hz displays. Each sample follows a five-second warmup and measures
30 seconds. The original file is `worship-countdown-5min-4k 2.mp4`, a 3840×2160,
30 fps source; its check starts at 20 seconds to skip the intro. Both sources
stream as 1080p with a 60 fps ceiling. The fixture uses a silent program-audio bus.

| Source | SRT recovery | Decoded fps | Native displayed fps | Native drops | Audio rebuffers |
| --- | --- | ---: | ---: | ---: | ---: |
| Generated 1080p60 countdown | 80 ms | 60.00 | 60.00 | 0 | 0 |
| Original 4K30 countdown | 80 ms | 30.03 | 30.03 | 0 | 0 |
| Generated 1080p60 countdown | 20 ms | 59.87 | 59.73 | 4 | 0 |
| Original 4K30 countdown | 20 ms | 30.03 | 30.03 | 0 | 0 |

Every row recorded zero sender/receiver mailbox drops, zero renderer overload
flushes and a real displayed image. The clean 60 fps run had exactly 16.667 ms
PTS spacing throughout the measurement. The original file at 20 ms had 33.333 ms
spacing at the median and 99th percentile; its largest gap was 50 ms.

The 20 ms 60 fps check is **not a zero-drop pass**: it recorded four native drops
and a 33.333 ms maximum PTS gap. Additional desktop activity also produced lower
capture/presentation rates; a separate run with extra idle app windows measured
52.52 displayed fps, 100 native drops and one audio underrun. These measurements
establish a clean 60 fps localhost case at 80 ms, rather than guaranteeing it at
20 ms or under arbitrary desktop load. The receiver's saved 20 ms choice remains
available. Frame-rate adaptation reduces repeated encoding; recovery and device
playout buffers still contribute to latency.

The complete suites passed 245 AltView and 515 eucaly XCTest cases, plus 104
offline feed/release checks per repository. The final eucaly media rerun passed
17 tests. Regression coverage includes jitter, fractional display rates,
high-refresh limiting, keepalive ordering, exact 1,500-tick 60 fps PES intervals,
shared A/V origin, native backpressure and live frame-duration handling.

Both signed arm64 Release apps were installed in `~/Applications`, their strict
signatures and installed binaries verified, and native startup checked. Previous
apps are preserved in `build/media-cadence/replaced/`. Saved library, playlist,
stopped audio and closed projection state were retained. The installed apps were
then closed to isolate the final fixture measurements.

Reports, displayed-frame PNGs and logs are in `build/media-cadence/`; the report
names are `60fps-final-release.json`, `original-final-release.json`,
`60fps-isolated-20ms.json` and `original-isolated-20ms.json`. The original app
workflow, physical HDMI and audible program-audio checks remain separate from
this production-code fixture measurement.
