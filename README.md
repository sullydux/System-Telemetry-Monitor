# System Monitor Dashboard

A native macOS app — built entirely in Swift and SwiftUI — that shows live,
on-host telemetry for your Mac and includes built-in CPU / RAM / GPU stress
benchmarks plus a synthetic local-LLM estimator.

It is **local-only**. No LAN server, no webpage, no browser dashboard, no
remote API, no internet dependency. Every read and every benchmark runs on the
Mac you're monitoring, and all state stays in memory or in a local file under
`~/Library/Application Support/`.

> Dark "terminal telemetry" aesthetic. Teal accent. Monospace numbers. Panel
> cards with thin borders. Looks like a status board for a machine.

---

## What it does

- **VITALS** — live readouts for CPU (overall + per-core), memory, GPU, disk
  usage + I/O, network throughput, battery/power, and system info (chip, OS,
  serial, uptime).
- **LIVE LOCAL PREVIEW** — three thin bars (CPU / RAM / GPU) refreshed at 1 Hz.
- **DEVICE NAME** — rename the machine for display purposes, saved as a local
  preference only.
- **AI STRESS BENCHMARK** (separate window) — CPU, RAM, GPU, and synthetic
  LLM-Stats tests, plus a Full Suite that runs all four and scores them.
- **CONNECTION LOG** — a scrolling, read-only log of in-app events.

### The benchmark tests

| Test       | What it does |
|------------|--------------|
| **CPU**    | Spins up N worker threads, each multiplying matrices via Accelerate (`cblas_sgemm`) until the deadline. Reports total matmuls and synthetic throughput. |
| **RAM**    | Allocates a target % of total RAM and sweeps it read-modify-write until the deadline. Reports bytes moved and bandwidth. |
| **GPU**    | Runs a Metal matmul kernel in a loop. Reports backend, device, and throughput. Reports *unavailable* honestly if no Metal device exists. |
| **LLM Stats** | **Synthetic only — no model is ever downloaded.** Estimates the memory footprint, KV-cache size, and tokens/sec a real local LLM of a given size/quantization would need on this hardware. |
| **Full Suite** | Runs CPU → RAM → GPU → LLM back to back and computes a combined 0–100 score. Sub-test errors are captured, not fatal. |

Every completed run is written to a local JSON file and a human-readable text
report under `~/Library/Application Support/Sullybase-Telemetry/stress-results/`.

---

## Requirements

- A Mac with **Apple Silicon** (the GPU test and chip-name detection assume
  Metal / Apple Silicon).
- **macOS 13 (Ventura) or newer.**
- The **macOS Command Line Tools** — that's it. **You do not need Xcode.**

The whole app builds and runs from the terminal with SwiftPM. The `build.sh`
script wraps `swift build` and assembles a signed `.app` bundle for you.

---

## Setup (no Xcode required)

### 1. Install the Command Line Tools

If you've never run anything Swift-related on this Mac, install the tools once:

```bash
xcode-select --install
```

A system prompt appears — click **Install** and wait for it to finish. This
gives you `swift`, `clang`, the macOS SDK, `codesign`, and everything else the
build needs. **No full Xcode download is required.**

Verify it worked:

```bash
swift --version
xcrun --show-sdk-path
```

### 2. Get the source

```bash
git clone <this repo's URL>
cd "System Telemetry Monitor"
```

### 3. Build the app

```bash
./build.sh
```

That's the whole build. It will:

1. Compile the Swift sources with `swift build -c release`.
2. Assemble a `System Monitor Dashboard.app` bundle under `./build/`.
3. Ad-hoc codesign it (no paid Apple Developer account needed).

When it finishes you'll see:

```
✓ Build complete
  App    : .../build/System Monitor Dashboard.app
```

---

## Run it

### From the terminal

```bash
# Build + launch in one step:
./build.sh run

# Or open an already-built bundle:
open "build/System Monitor Dashboard.app"
```

### From Finder

Double-click `build/System Monitor Dashboard.app`.

### First-launch Gatekeeper prompt

Because the app is **ad-hoc signed** (no App Store / Developer ID certificate),
macOS will show a dialog the first time:

> *"System Monitor Dashboard" cannot be opened because Apple cannot check it for malicious software.*

That's expected for any locally-built app. To allow it:

- **macOS Ventura (13) and later (recommended):** right-click the app →
  **Open** → confirm **Open** in the dialog. It will launch normally and won't
  prompt again.
- **Alternative (terminal):**
  ```bash
  xattr -dr com.apple.quarantine "build/System Monitor Dashboard.app"
  ```

---

## `build.sh` reference

```bash
./build.sh            # release build + bundle + ad-hoc sign   (default)
./build.sh debug      # debug build — compiles faster, runs slower
./build.sh run        # release build, then launch the app
```

The script is safe to re-run — it wipes and rebuilds the `.app` bundle each
time. It requires nothing beyond the Command Line Tools.

---

## Project layout

```
.
├── Package.swift                 # SwiftPM manifest (macOS 13 target)
├── build.sh                      # CLI build → .app bundle → ad-hoc sign
├── Resources/
│   └── Info.plist                # Bundle descriptor (consumed by build.sh)
└── Sources/SystemMonitorDashboard/
    ├── SystemMonitorDashboardApp.swift   # @main entry, scene/window wiring
    ├── AppState.swift                    # Central observable state model
    ├── Telemetry.swift                   # On-host CPU/RAM/GPU/disk/net/power reads
    ├── BenchmarkEngine.swift             # CPU/RAM/GPU/LLM/suite test engine
    ├── MainWindow.swift                  # VITALS, device name, preview, log
    ├── BenchmarkWindow.swift             # Test config + progress + last result
    ├── Persistence.swift                 # Local JSON + log file I/O
    ├── Theme.swift                       # Colors, fonts, Panel, bars, buttons
    └── Format.swift                      # Number / rate / byte formatting
```

After building, the app bundle lands in `./build/`.

---

## Where data lives

Everything the app writes goes under:

```
~/Library/Application Support/Sullybase-Telemetry/
├── preferences.json              # device name, LLM settings
├── stress-results.json           # benchmark history (last 200)
├── connection.log                # rolling event log
└── stress-results/
    └── run-<timestamp>-<test>.txt   # one text report per completed run
```

You can open the results folder from the benchmark window's
**Open Results Folder** button, or directly:

```bash
open "$HOME/Library/Application Support/Sullybase-Telemetry/stress-results"
```

---

## Security model (do not weaken)

This is the whole reason the app is safe to run locally:

- **Local-only.** No LAN server. No webpage. No browser dashboard. No remote
  API. No inbound control surface of any kind.
- **No internet dependency.** The app functions fully offline.
- **Secrets stay in memory** unless explicitly saved as a local preference.
- The Info.plist ships with `NSAllowsArbitraryLoads = false` so the OS never
  even prompts to allow network listeners.

If you fork or extend the app, keep all of the above intact.

---

## Troubleshooting

**`swift: command not found`**
Run `xcode-select --install` and try again.

**`codesign failed` warning from `build.sh`**
Harmless. The app still runs locally; you may just get a Gatekeeper prompt
the first time (see First-launch above).

**Build succeeds but the app won't open (unidentified developer)**
Right-click the app → **Open** → confirm, or run
`xattr -dr com.apple.quarantine "build/System Monitor Dashboard.app"`.

**GPU test reports unavailable**
The GPU test needs a Metal device. It will report unavailable honestly on Macs
without one rather than fabricate a result. Verify with `system_profiler SPDisplaysDataType`.

**Want to wipe all local data?**
```bash
rm -rf "$HOME/Library/Application Support/Sullybase-Telemetry"
```

---

## License

See the repository. Built as a local-first, offline-only tool.
