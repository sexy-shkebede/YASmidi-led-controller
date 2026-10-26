🌐 **Language / Язык:** **[🇷🇺 Русский](https://github.com/sexy-shkebede/YASmidi-led-controller)** | **[🇬🇧 English](https://www.google.com/search?q=https://github.com/sexy-shkebede/YASmidi-led-controller/blob/main/Readme%2520En.md)**

# segctl.sh — Live Display & RGB Controller for Yandex Station Midi

**`segctl.sh`** is a self-contained, in-memory shell script for the **Yandex Station Midi** smart speaker (`cucumber` platform). It spins up a lightweight web server directly in the speaker's RAM (`tmpfs`), serving a full-featured visual editor for the 45-segment clock display, top RGB LED ring, and RGB logo, along with a native `.binscled` / `.binscled.zst` animation studio and on-device player.

Everything runs exclusively inside `/tmp/segctl` in RAM — the script never modifies system partitions, Alice's configuration files, or startup scripts.

## Live Demo & Quick Start



You can get the live web editor up and running in under a minute:

1. **Push the script to the speaker's temporary RAM directory** from your computer via `adb`:
   ```sh
   adb push segctl.sh /tmp/segctl.sh
   ```
2. **Start the server** inside the speaker's shell (`adb shell` as `root`):
   ```sh
   sh /tmp/segctl.sh
   ```
   The script automatically verifies all 45 clock segments, the RGB ring, and required BusyBox tools, then prints the editor URL:
   ```text
   == проверка совместимости segctl ==
     [ OK ]  root есть
     [ OK ]  /tmp — tmpfs (всё в памяти, после перезагрузки чисто)
     [ OK ]  светодиоды: 45 из 45, имена совпадают
     [ OK ]  яркость пишется и читается обратно точно (сторож сработает)
     [ OK ]  максимальная яркость 255 (как ждёт редактор)
     [ OK ]  RGB-кольцо: 24 пикселей, запись работает — управление доступно
     [ OK ]  RGB-логотип: 6 пикселей — управление доступно
   Итог: полностью совместимо.

   segctl работает: открой http://192.168.1.50:8080
   Дисплей остаётся у Алисы, пока ты ничего не изменишь в редакторе.
   Остановить и всё убрать: sh /tmp/segctl.sh stop
   ```
3. **Open the URL in your browser** on a phone or PC (`http://<speaker-IP>:8080`):
   * Tap or drag across digit segments, dots, and bars to light them up on the physical speaker in real time.
   * Load built-in presets (such as *Clock 08:24*, *Alarm ringing*, or *Segment wave*), type custom text, or generate a scrolling marquee.
   * Expand **Ring (RGB)** and **Logo (RGB)** to paint individual perimeter and logo LEDs in any color, or export your animation as `.binscled.zst`.
4. **Return control to Alice when finished:**
   ```sh
   sh /tmp/segctl.sh stop
   ```
   *(If you modified the RGB ring or logo colors during your session, run `reboot` afterwards to reinitialize Alice's native LED controller).*

## Why `segctl.sh` Is Needed

The Yandex Station Midi features a 45-LED white segment clock display, a perimeter RGB LED ring, and a 6-pixel RGB logo. Creating and testing custom display animations (`.binscled.zst`) normally requires packing binary files offline, pushing them to the speaker, and running command-line utilities manually. **`segctl.sh`** streamlines the entire workflow:

* **Real-Time Hardware Control (Live Mode):** Open `http://<speaker-IP>:8080` in any browser and click or drag across segments, dots, center bars, or RGB pixels to light them up on the physical speaker immediately with any brightness level (`0–255`) or color.
* **Browser-Based Animation Studio:** Build multi-frame animations, set per-frame durations (`1–65535 ms`) and loop start points, type clock/text strings, generate scrolling marquee text, interpolate smooth transitions (`sine` or `linear` tweening), add fade-in/fade-out effects, and merge identical adjacent frames.
* **Import & Export `.binscled` / `.binscled.zst`:** Download animations as compressed `.binscled.zst` archives, raw `.binscled` binaries (for `clock_led_util`), or copy a ready-to-run `base64` one-liner for `adb shell`.
* **Automatic Display Protection Against Alice Redraws:** A background watchdog (`keeper.sh`) keeps your custom frame on the screen even when Alice refreshes the clock (typically once a minute) and automatically stops any conflicting `/data/yse/clock.pid` loop (from `YANDEX_Customizer`).
* **Non-Destructive Compatibility & Byte-Map Diagnostics:** Includes a `check` mode and a visual byte scanner to verify `root` permissions, `sysfs` paths, required BusyBox applets, and the byte layout defined in `quasar.cfg`.

## How It Works

When started, `segctl.sh` creates `/tmp/segctl` in RAM and unpacks four components:

1. **HTTP Server (`busybox inetd` + `http.sh`):** Listens on the chosen TCP port (default `8080`), serves the single-page web editor (`www/index.html`), and handles REST API endpoints (`/api/info`, `/api/state`, `/api/set`, `/api/play`, `/api/stop`, `/api/release`, `/api/ring`, `/api/ring/set`, `/api/logo/set`).
2. **Segment Display Controller (`45` white LEDs):** Writes brightness values (`0–255`) directly to `/sys/class/leds/cucumber:white:clock-*/brightness`:
   * **4 seven-segment digits:** segments `a1..g1`, `a2..g2`, `a3..g3`, `a4..g4` and adjacent dots `p1, q1, p2, q2, p4, q4, p5, q5`.
   * **Center column:** horizontal bars `h1, h2`, `m1, m2`, `l1, l2` and center colon dots `p3, q3`.
   * **Degree symbol:** top-right dot `deg`.
3. **Display Watchdog (`keeper.sh`):** Before applying your first edit, the script saves Alice's current clock frame to `/tmp/segctl/snap`. Then `keeper.sh` polls all 45 LEDs every `150 ms` against your desired state (`/tmp/segctl/want/`). If Alice redraws the clock (detected across two consecutive checks), the watchdog updates the saved snapshot in `snap` and immediately restores your frame.
4. **In-Memory Animation Player (`player.sh`):** Plays multi-frame sequences from `/tmp/segctl/anim.txt` directly on the speaker (independently of the browser tab), supporting one-shot playback or continuous looping from any chosen frame.
5. **RGB Ring & Logo Controller:** Automatically discovers `cucumber:{red,green,blue}:ring0..N` and `cucumber:{red,green,blue}:logo0..N` in `/sys/class/leds/` and writes `R`, `G`, `B` channel brightness values in real time.

## Important Note: RGB Ring (`ring`) Zeroing & Why a Speaker Reboot Is Still Required

> **Important:** If you change the colors of the top **RGB Ring (`ring`)** or **RGB Logo (`logo`)**, **you must reboot the speaker** after finishing your session — even though `segctl.sh` resets all RGB LED brightness values back to `0` (`brightness = 0`).

### Why a Reboot Is Required

1. When you click **"Release display to Alice" («Отдать дисплей Алисе»)** in the web UI or run `sh /tmp/segctl.sh stop`, the script checks for the marker files `/tmp/segctl/ring_touched` and `/tmp/segctl/logo_touched`.
2. If the RGB ring or logo was modified during the session, the `rgb_blank` function writes `0` to the `brightness` file of every `red`, `green`, and `blue` channel across all pixels of the ring (`ring0..N`) and logo (`logo0..N`).
3. While the white clock display is cleanly restored from the saved snapshot (`/tmp/segctl/snap`), the **RGB ring and logo are normally driven by Alice's internal system daemon (`quasar` / animation service)** using its own state machine and hardware triggers.
4. Writing directly to the `sysfs` RGB nodes (`/sys/class/leds/cucumber:*:ring*/brightness`) and then zeroing them out leaves the underlying LED driver state desynchronized from Alice's animation service. As a result, the ring turns off, but standard voice-assistant ring animations may not resume or render properly until the system service reinitializes the hardware.
5. **Rebooting the speaker** cleanly reinitializes the LED subsystem, restores full control of the RGB ring and logo to Alice, and wipes `/tmp` completely.

## CLI Commands Reference

Upload `segctl.sh` to `/tmp` on the speaker (for example, via `adb push segctl.sh /tmp/segctl.sh`) and run the commands as `root` inside `adb shell`.

### Command Summary

| Command | Description |
| :--- | :--- |
| `sh /tmp/segctl.sh` | Run compatibility checks and start the server on the default port (`8080`) |
| `sh /tmp/segctl.sh start` | Explicitly start the server on port `8080` |
| `sh /tmp/segctl.sh start <port>` | Start the server on a custom TCP port (e.g., `8090`) |
| `sh /tmp/segctl.sh check` | Run a non-destructive compatibility check (port `8080`) without starting anything |
| `sh /tmp/segctl.sh check <port>` | Run a compatibility check and verify that `<port>` is free |
| `sh /tmp/segctl.sh status` | Check whether `segctl` is running, print its URL, and show who currently owns the display |
| `sh /tmp/segctl.sh stop` | Stop the server, restore Alice's clock frame, zero out RGB ring/logo LEDs, and remove `/tmp/segctl` |
| `sh /tmp/segctl.sh help` | Print the built-in usage summary (also accepts `-h` or `--help`) |

### 1. Compatibility Check (`check`)

Before starting `segctl.sh` for the first time, run the non-destructive diagnostic check:

```sh
sh /tmp/segctl.sh check
```

Or test a specific port (e.g., `8090`):

```sh
sh /tmp/segctl.sh check 8090
```

The `check` command verifies **12 items**:
1. Root privileges (`id -u = 0`).
2. Whether `/tmp` is mounted as `tmpfs` (in-memory filesystem).
3. Presence of all `45 out of 45` clock segment LEDs under `/sys/class/leds/cucumber:white:clock-*`.
4. Non-destructive read/write accuracy test on `deg/brightness` (verifies that the driver reads back exact values so `keeper.sh` can detect Alice redraws).
5. Maximum brightness value `max_brightness` (expected `255`).
6. Availability of required system utilities: `inetd`, `usleep`, `setsid`, `dd`, `sh`, `kill`.
7. Support for `iflag=count_bytes,fullblock` in `dd` (used to read HTTP `POST` bodies).
8. Process-group termination via `setsid` and `kill -TERM -pid` (used to stop the player and watchdog cleanly).
9. Whether the target TCP port (`8080` or custom) is free in `netstat`.
10. Presence of any `DROP` or `REJECT` rules in `iptables`.
11. Verification of the `.binscled` byte map (`digitParts` and `degreeLocation`) against `/system/vendor/quasar/quasar.cfg`.
12. Detection and write access test for the RGB ring (`ring0..N`) and RGB logo (`logo0..N`) pixels.

### 2. Start the Server (`start`)

Start on the default port (`8080`):

```sh
sh /tmp/segctl.sh
```

Or start on a custom port (for example, `8090`):

```sh
sh /tmp/segctl.sh start 8090
```

To bypass the pre-start compatibility check, set `SEGCTL_SKIP_CHECK=1`:

```sh
SEGCTL_SKIP_CHECK=1 sh /tmp/segctl.sh start 8080
```

Once started, open the printed URL (e.g., `http://192.168.1.50:8080`) in your browser. The clock display stays under Alice's control until you make your first edit in the web UI.

### 3. Check Server Status (`status`)

Check if the server is running, view its URL, and see whether display takeover is currently active:

```sh
sh /tmp/segctl.sh status
```

### 4. Stop & Clean Up (`stop`)

Stop the web server, background animation player, and watchdog, restore Alice's saved clock frame, reset RGB ring and logo LEDs to `0`, and delete `/tmp/segctl` from RAM:

```sh
sh /tmp/segctl.sh stop
```

If you modified the **RGB Ring** or **RGB Logo** during your session, reboot the speaker afterwards to restore Alice's native ring animations:

```sh
reboot
```

## Environment Variables

You can customize paths and timing using environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `SEGCTL_DIR` | `/tmp/segctl` | Working directory in RAM where the web app and state files are unpacked |
| `SEGCTL_LEDS` | `/sys/class/leds/cucumber:white:clock-` | `sysfs` path prefix for the 45 white clock display LEDs |
| `SEGCTL_RING` | *(auto-detected)* | Manual override for the RGB ring `sysfs` path prefix |
| `SEGCTL_TICK` | `150` | Polling interval in milliseconds for the display watchdog (`keeper.sh`) |
| `SEGCTL_SKIP_CHECK` | `0` | Set to `1` to skip `check_compat` when starting the server |
