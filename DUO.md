# Moonlight Duo Desktop

This fork keeps Moonlight's history and GPLv3 license. The scene-lifecycle and live layer resize changes originate in [upstream PR #729](https://github.com/moonlight-stream/moonlight-ios/pull/729). The fork adds a desktop-specific layout and controls to the upstream GameStream client.

## Connect from iPhone

1. Sign in to Tailscale on Windows and iPhone using the same tailnet. In Tailscale on Windows, use **Copy IP address** for the PC's IPv4 address.
2. Add that address in Moonlight manually. Enter the four-digit PIN in the Sunshine Web UI on the PC, then select **Desktop** on the phone. The same address works at home and over cellular.
3. Start with 1080p, 60 FPS and 15–20 Mbps. Raise bitrate on a good connection, or drop to 720p and 10 Mbps for a weaker link. The custom app's Desktop stream can use automatic resolution or the resolution set in Moonlight Settings.

In official Moonlight, set **On-Screen Controls** to **Off** for desktop use. With **Touch Mode → Touchscreen** selected, start a new stream. Tap where you want to click, pinch the picture to zoom, and drag with two fingers to pan while zoomed. Tap with three fingers at once to open or hide the phone keyboard for Windows typing.

## Desktop controls

- Tap once or twice in trackpad mode for a click or double-click. Tap with two fingers for a right-click. Hold one finger briefly and move it to drag. Move two fingers to scroll.
- In direct touch mode, tap the Windows object, hold for right-click, or move your finger from the object to drag. Move two fingers to scroll. Pinch to zoom, then drag with two fingers to pan the zoomed view.
- Tap the keyboard icon to type. The desktop menu contains Ctrl, Alt, Shift, Windows, and shortcuts such as Copy, Paste, File Explorer and Task Manager. An external mouse and keyboard use Moonlight's existing input support.
- Use **Switch monitor** to change which display Sunshine streams, or **Windows shortcuts → Move window left/right** to move the focused app between displays. With a physical keyboard in official Moonlight, request the first or second output with Ctrl+Alt+Shift+F1 or F2.
- Use **Layout → Automatic**, **Full screen** or **Laptop**. Automatic laptop mode uses Apple's public hinge and reserved-region APIs when the hinge divides the window horizontally. Manual laptop mode also works with no hinge information and uses the lower pane as the trackpad.
- Desktop reflows as the window changes. In matching-resolution mode, a substantial settled size change reconnects to request the new resolution. Sunshine resumes the Windows desktop session. The stream can briefly pause during the switch. **Use resolution from Settings** keeps the same requested resolution throughout.
- **Fit entire desktop** keeps every edge visible. **Fill screen (crop edges)** uses the whole viewport. If Sunshine is encoding an ultrawide or 16:9 display with padding, set **Host display shape** to the capture display's aspect ratio. A host display mode that matches the active phone viewport lets you fit the entire desktop and fill the screen at the same time.

## Windows host setup

The host installer expects the verified Sunshine AMD64 lite archive and Tailscale AMD64 MSI in the downloads folder passed to [Install-Host.ps1](Setup/Windows/Install-Host.ps1). The pinned releases are [Sunshine v2026.914.233613](https://github.com/SunshineStream/Sunshine/releases/tag/v2026.914.233613) and [Tailscale 1.104.7](https://pkgs.tailscale.com/stable/).

Run the script in administrator PowerShell. Complete the first-time Sunshine login on localhost and sign in to Tailscale. The script restricts Sunshine's listening address to the PC's Tailscale address after both steps, keeps UPnP off and requires encrypted Moonlight sessions. The Sunshine Web UI then uses the same Tailscale address on port 47990 and requires its own login.

Sunshine captures one Windows display. The PC must be awake and Windows must still see the capture display. Hardware encoding is NVIDIA NVENC. The script uses DirectX capture, does not install a virtual monitor, and leaves Windows' physical display modes in place.

Sunshine's **Configuration → Audio/Video → Display Id** sets the default captured monitor. Use the device ID from the startup log. The [display matching helper](Setup/Windows/Set-DisplayMatching.ps1) also accepts a display ID and can enable automatic matching of supported modes during a session. Its disable switch keeps the selected monitor at its normal resolution.

## Build and install

- [The GitHub Actions workflow](.github/workflows/ci.yml) builds with Xcode 27.2 on a GitHub-hosted Mac. It resolves the pinned dependencies, compiles an iPhone release and builds and launches an iPhone Duo simulator copy. The device artifact contains an unsigned IPA and a SHA-256 checksum. iPhone installation requires signing.
- Use Xcode 27.1 or newer on a Mac for device signing. Open `Moonlight.xcodeproj`, select the **Moonlight** scheme, choose your team in **Signing & Capabilities**, then build to your registered device. The iOS bundle ID is `com.antonvantra.moonlight.duo`.
- For internal TestFlight with Xcode, archive the Moonlight scheme using your team. In Organizer, choose Distribute App, then TestFlight Internal Only. Xcode can use Apple's cloud-managed signing from your own session.
- To sign and upload from Windows, run the [TestFlight workflow](.github/workflows/testflight.yml) on the GitHub-hosted Mac. Use an Apple Distribution certificate reserved for this app and an App Store Connect profile for the explicit Moonlight Duo bundle ID. Invite a separate Developer account with access to Moonlight Duo only, then have that account create its own individual API key. The workflow checks which apps the key can see before it imports the signing certificate.
- In App Store Connect, open the app's **TestFlight** tab after processing. Complete any declarations Apple requests, add the build to an internal testing group, and add your own tester account. Install from Apple's TestFlight app. [Apple's internal testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/).
- For Windows USB installation, use the official [iLoader](https://github.com/nab138/iloader) build with Apple Devices. Connect and trust the iPhone, then sign in to iLoader with a separate personal Apple account and choose **Import IPA**. Select the downloaded Moonlight Duo IPA. The tool signs it before installing. Enable Developer Mode if iOS prompts you. Free personal signing expires after seven days and needs renewal.

## Verification

The native geometry tests cover the outer and inner screen sizes, portrait rotation, split panes, even stream resolutions, cropped and fitted coordinates, and the resolution-change threshold. They run both locally and on the Mac runner. The simulator check launches the app on iPhone Duo, but physical-device acceptance still covers streaming in both screen poses, mouse and keyboard input, screen-off capture, and a Wi-Fi-to-cellular stream.

The TestFlight workflow's **preflight** mode checks Xcode without any Apple credentials. Before using **upload**, add the following only to the branch-restricted **moonlight-testflight** GitHub environment.

- **MOONLIGHT_CERTIFICATE** and **MOONLIGHT_CERTIFICATE_PASSWORD** hold the base64-encoded PFX and its password.
- **MOONLIGHT_PROFILE** holds the base64-encoded App Store Connect provisioning profile.
- **MOONLIGHT_UPLOAD_KEY_ID** and **MOONLIGHT_UPLOAD_PRIVATE_KEY** hold the individual key ID and the contents of its P8 file.

The upload job creates an internal-only export and sends it to Apple. The private signing files are temporary and the signed IPA stays out of the public workflow artifacts.
