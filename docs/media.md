# eucaly Media on macOS

eucaly Media replaces AltView’s Confidence page and clock. It receives the picture
from an existing eucaly **Audience** output, including live video and images,
with live video file audio. AltView’s Audience text receiver remains independent.

## Connect the Macs

1. Connect both Macs by wired Ethernet to the same network. Connect the AltView
   Mac’s HDMI output to ATEM. In macOS Displays, use an extended 1920 × 1080
   display and a refresh rate matching the ATEM production (50 or 60 Hz).
2. Open **eucaly Media** in AltView. Select the HDMI monitor and **Open Display**.
   Select its HDMI device under Audio so received video audio reaches ATEM.
3. Copy the media passphrase. Note the listening port (default **10000**) and the
   receiving Mac’s Ethernet IPv4 address, then click **Start Receiving**. Allow
   local-network access if macOS requests it.
4. In eucaly, open **Settings → Manage Outputs → + → AltView Media Output**.
   Select the existing Audience output as its source. Enter the AltView Mac’s
   address, port and media passphrase. These are separate from text pairing.
5. Select 50 or 60 fps to match the production. Start with **80 ms** recovery
   buffer on both Macs. Enable the media output, load Current and **Show Slides**.
   If capture permission is requested, allow eucaly under Screen Recording, then
   use **Retry Media**. eucaly captures only its selected Audience window.

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

## Recovery and limits

**Stop Receiving** immediately clears media picture and sound and closes the SRT
listener; it does not stop Audience text. **Close Display** closes only the HDMI
window. eucaly Stop, disabled/deleted outputs and lost source windows retire
capture/audio queues. AltView clears a disconnected or silent video source after
approximately three seconds and waits for reconnection. A network outage retries
while the original source is still valid. Capture failure requires Retry Media.

The transport is H.264/AAC in MPEG-TS over encrypted SRT, with bounded capture,
decoder and playback queues and a short playout buffer. Both ends must use the
same passphrase; it is stored in Keychain, never in saved output JSON. SRT listens
on the configured UDP port. If a firewall blocks it, allow incoming AltView
connections. A wrong secret or occupied port can appear as a connection failure;
verify both before retrying. SRT media does not use text leases or Bonjour pairing.

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
Physical capture permission, two-Mac loss/recovery, real HDMI audio routing and
end-to-end latency require a hardware rehearsal.

`Vendor/MediaStreaming/PATCHES.md` records upstream versions and local fixes.
**AltView → Third-Party Notices…** lists BSD, MPL and Apache notices and SRT source
availability. No NDI SDK is included.
