# eucaly Media on macOS

eucaly Media replaces AltView’s Confidence page and clock. It receives the picture
from an existing eucaly **Audience** output, including live video and images,
with live video file audio. AltView’s Audience text receiver remains independent.

## Connect the Macs

1. Connect both Macs to the same local network. Ethernet is recommended; Wi-Fi
   also works. Connect the AltView
   Mac’s HDMI output to ATEM. In macOS Displays, use an extended 1920 × 1080
   display and a refresh rate matching the ATEM production (50 or 60 Hz).
2. Open **eucaly Media** in AltView. Select the HDMI monitor and **Open Display**.
   Select its HDMI device under Audio so received video audio reaches ATEM.
3. Copy the media passphrase, then click **Start Receiving**. The receiver is now
   advertised through Bonjour on the listening port (default **10000**). Allow
   local-network access if macOS requests it.
4. In eucaly, open **Settings → Manage Outputs → + → AltView Media Output**.
   Select the existing Audience output as its source. Choose the AltView Mac in
   **Receiver** and enter its media passphrase. **Manual address** lets you enter
   its IPv4 address or local hostname and port instead. This is separate from text pairing.
5. Select 50 or 60 fps to match the production. Start with **80 ms** recovery
   buffer on both Macs. Enable the media output, load Current and **Show Slides**.
   If capture permission is requested, allow eucaly under Screen Recording, then
   use **Retry Media**. eucaly captures only its selected Audience window.

For Wi-Fi testing, start with **120 or 200 ms** recovery buffer on both ends.
Use the receiving Mac’s Wi-Fi IPv4 address when entering a manual address. Guest
Wi-Fi or client isolation can prevent the Macs from communicating. The recovery
buffer adds transport delay; it does not measure total picture/audio delay.

Bonjour uses `_altviewmedia._udp`, independently of Audience text discovery.
Only the receiver identity and protocol version are advertised; the service
record supplies its hostname and port. Passphrases remain in Keychain and are
entered once per output. eucaly remembers the selected receiver by stable UUID,
refreshes its endpoint for reconnects and waits for that same receiver when it
is offline. It never substitutes another receiver or dials a saved stale IP.
**Stop Receiving** withdraws the advertisement. Manual addressing remains available
when Bonjour is blocked across network segments.

The Audience output must be enabled, assigned and open. Its existing composition
and physical resolution are used as-is; only the network copy is scaled to
1920 × 1080. The media output allocates no additional monitor or playback owner.
Preview browsing never becomes the source. Configure and enable alone does not
start transmission. After changing a running output’s endpoint or source, Show Slides or
Retry Media explicitly starts the new configuration. After changing its
passphrase, use Retry Media. The background-music switch applies immediately
to an already running stream.

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
listener; it does not stop Audience text. **Close Display** closes only the HDMI
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

40 ms is available for a clean LAN; increasing the recovery buffer improves packet
recovery at the cost of delay. These values are transport buffers, **not measured
end-to-end latency** or a promise of NDI-equivalent delay. Measure video/audio
synchronization and camera alignment on the actual two Macs, Ethernet network and
ATEM before live use. Sender capture, hardware codecs, audio hardware and HDMI
also contribute latency. The receiver does not perform ATEM delay compensation.

The first version is Apple Silicon macOS only. Transport and decoded playback are separated
from AppKit and window capture, and the underlying dependencies include tvOS
slices. An Apple TV UI/HDMI host is future work; no tvOS app is delivered here.

## Verification

Automated tests cover encrypted SRT H.264/AAC loopback, repeated decoded 1080p
frames, stopping/rebinding a waiting listener, bounded queues, saved output
settings and migration, shared live-file audio taps and pause cleanup. Existing
Audience text, ownership, display assignment and layout regressions also run.
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
