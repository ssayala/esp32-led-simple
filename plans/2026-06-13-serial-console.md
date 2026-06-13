# Serial Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dev/test serial command console that drives every device feature over USB by writing the same `pending*` buffers the BLE control plane uses.

**Architecture:** A pure, host-testable line parser (`firmware/src/console.{h,cpp}`) turns a typed line into a `{verb, arg}` struct. A dispatcher in `main.cpp` maps each verb onto the existing `pending*` buffer + `*UpdatePending` flag (or `pendingCmd`), so `loop()`'s existing `applyPending*()` calls do all the real work. No feature logic is added or duplicated.

**Tech Stack:** C++ (Arduino/ESP32-S3), PlatformIO, Unity (native unit tests).

**Spec:** `specs/2026-06-13-serial-console-design.md`

---

## File Structure

- **Create `firmware/src/console.h`** — public types (`ConsoleVerb`, `ConsoleCmd`) and the `parseConsoleLine()` declaration. No Arduino dependency.
- **Create `firmware/src/console.cpp`** — pure `parseConsoleLine()` implementation. Depends only on `<string.h>`. This is the unit-tested core; it compiles on both the ESP32 target and the native host.
- **Create `firmware/test/test_console/test_console.cpp`** — Unity tests for `parseConsoleLine()`.
- **Modify `firmware/platformio.ini`** — add `[env:native]` for host tests, with a src filter so only `console.cpp` (not `main.cpp`) compiles natively.
- **Modify `firmware/src/main.cpp`** — `#include "console.h"`, add the console section (`dispatchConsoleCmd()`, `pollSerialConsole()`, helpers), and one `pollSerialConsole()` call in `loop()`.
- **Modify `firmware/FIRMWARE_GUIDE.md`** and **`firmware/WOKWI.md`** — document the console.

---

## Task 1: Pure line parser + native test harness

**Files:**
- Create: `firmware/src/console.h`
- Create: `firmware/src/console.cpp`
- Create: `firmware/test/test_console/test_console.cpp`
- Modify: `firmware/platformio.ini`

- [ ] **Step 1: Write the failing test**

Create `firmware/test/test_console/test_console.cpp`:

```cpp
#include <unity.h>
#include "console.h"

void test_empty_line(void) {
  TEST_ASSERT_EQUAL(CONSOLE_NONE, parseConsoleLine("").verb);
}
void test_whitespace_only(void) {
  TEST_ASSERT_EQUAL(CONSOLE_NONE, parseConsoleLine("   ").verb);
}
void test_unknown_verb(void) {
  TEST_ASSERT_EQUAL(CONSOLE_UNKNOWN, parseConsoleLine("frobnicate x").verb);
}
void test_verb_no_arg(void) {
  ConsoleCmd c = parseConsoleLine("help");
  TEST_ASSERT_EQUAL(CONSOLE_HELP, c.verb);
  TEST_ASSERT_EQUAL_STRING("", c.arg);
}
void test_simple_arg(void) {
  ConsoleCmd c = parseConsoleLine("tz PST8PDT");
  TEST_ASSERT_EQUAL(CONSOLE_TZ, c.verb);
  TEST_ASSERT_EQUAL_STRING("PST8PDT", c.arg);
}
void test_arg_preserves_internal_spaces(void) {
  ConsoleCmd c = parseConsoleLine("wifi My Home pass123");
  TEST_ASSERT_EQUAL(CONSOLE_WIFI, c.verb);
  TEST_ASSERT_EQUAL_STRING("My Home pass123", c.arg);
}
void test_leading_whitespace(void) {
  ConsoleCmd c = parseConsoleLine("   mode all");
  TEST_ASSERT_EQUAL(CONSOLE_MODE, c.verb);
  TEST_ASSERT_EQUAL_STRING("all", c.arg);
}
void test_multiple_spaces_between(void) {
  ConsoleCmd c = parseConsoleLine("sign    hello");
  TEST_ASSERT_EQUAL(CONSOLE_SIGN, c.verb);
  TEST_ASSERT_EQUAL_STRING("hello", c.arg);
}
void test_hyphenated_verb(void) {
  ConsoleCmd c = parseConsoleLine("pin-enforce off");
  TEST_ASSERT_EQUAL(CONSOLE_PINENFORCE, c.verb);
  TEST_ASSERT_EQUAL_STRING("off", c.arg);
}
void test_prefix_not_matched(void) {
  TEST_ASSERT_EQUAL(CONSOLE_UNKNOWN, parseConsoleLine("sig hello").verb);
}

void setUp(void) {}
void tearDown(void) {}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_empty_line);
  RUN_TEST(test_whitespace_only);
  RUN_TEST(test_unknown_verb);
  RUN_TEST(test_verb_no_arg);
  RUN_TEST(test_simple_arg);
  RUN_TEST(test_arg_preserves_internal_spaces);
  RUN_TEST(test_leading_whitespace);
  RUN_TEST(test_multiple_spaces_between);
  RUN_TEST(test_hyphenated_verb);
  RUN_TEST(test_prefix_not_matched);
  return UNITY_END();
}
```

Add to `firmware/platformio.ini` (new section at the end):

```ini
[env:native]
platform = native
test_framework = unity
build_flags = -std=gnu++17
; main.cpp needs Arduino; compile only the pure console unit natively.
build_src_filter = -<*> +<console.cpp>
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pio test -d firmware -e native`
Expected: FAIL — compilation error, `console.h: No such file or directory` (header not created yet).

- [ ] **Step 3: Create the header**

Create `firmware/src/console.h`:

```cpp
#pragma once

// Serial console command parser. Pure (no Arduino deps) so it is unit-tested
// on the host. The dispatcher that acts on these lives in main.cpp.

enum ConsoleVerb {
  CONSOLE_NONE,     // blank line
  CONSOLE_UNKNOWN,  // unrecognized verb
  CONSOLE_WIFI,
  CONSOLE_APIKEY,
  CONSOLE_TICKERS,
  CONSOLE_LOCATIONS,
  CONSOLE_MODE,
  CONSOLE_SIGN,
  CONSOLE_POWER,
  CONSOLE_BRIGHT,
  CONSOLE_SCROLL,
  CONSOLE_TZ,
  CONSOLE_TIMER,
  CONSOLE_PINENFORCE,
  CONSOLE_RELOAD,
  CONSOLE_RESET,
  CONSOLE_INFO,
  CONSOLE_HELP,
};

struct ConsoleCmd {
  ConsoleVerb verb;
  const char* arg;  // points into the input line (after the first space); "" if none
};

// Split a NUL-terminated line into verb + arg. Non-destructive: `arg` points
// into `line`, so `line` must outlive the returned struct. Leading whitespace
// is skipped; arg keeps internal spaces (so SSIDs/passwords survive).
ConsoleCmd parseConsoleLine(const char* line);
```

- [ ] **Step 4: Create the implementation**

Create `firmware/src/console.cpp`:

```cpp
#include "console.h"
#include <string.h>

namespace {
struct VerbEntry {
  const char* name;
  ConsoleVerb verb;
};
const VerbEntry kVerbs[] = {
    {"wifi", CONSOLE_WIFI},        {"apikey", CONSOLE_APIKEY},
    {"tickers", CONSOLE_TICKERS},  {"locations", CONSOLE_LOCATIONS},
    {"mode", CONSOLE_MODE},        {"sign", CONSOLE_SIGN},
    {"power", CONSOLE_POWER},      {"bright", CONSOLE_BRIGHT},
    {"scroll", CONSOLE_SCROLL},    {"tz", CONSOLE_TZ},
    {"timer", CONSOLE_TIMER},      {"pin-enforce", CONSOLE_PINENFORCE},
    {"reload", CONSOLE_RELOAD},    {"reset", CONSOLE_RESET},
    {"info", CONSOLE_INFO},        {"help", CONSOLE_HELP},
};
inline bool isSpace(char c) { return c == ' ' || c == '\t'; }
}  // namespace

ConsoleCmd parseConsoleLine(const char* line) {
  ConsoleCmd cmd = {CONSOLE_NONE, ""};
  if (!line) return cmd;

  while (isSpace(*line)) line++;       // skip leading whitespace
  if (*line == '\0') return cmd;       // blank line -> CONSOLE_NONE

  const char* verbStart = line;
  const char* p = line;
  while (*p && !isSpace(*p)) p++;      // verb token = up to next whitespace
  size_t verbLen = (size_t)(p - verbStart);

  const char* arg = p;
  while (isSpace(*arg)) arg++;         // arg = first non-space after the verb
  cmd.arg = arg;

  for (const VerbEntry& e : kVerbs) {
    if (strlen(e.name) == verbLen && strncmp(verbStart, e.name, verbLen) == 0) {
      cmd.verb = e.verb;
      return cmd;
    }
  }
  cmd.verb = CONSOLE_UNKNOWN;
  return cmd;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pio test -d firmware -e native`
Expected: PASS — `10 Tests 0 Failures 0 Ignored`.

- [ ] **Step 6: Verify the firmware target still builds (console.cpp compiles for ESP32 too)**

Run: `pio run -d firmware`
Expected: SUCCESS. (`console.cpp` is picked up automatically by `env:esp32-s3`; nothing references it yet, so it links cleanly.)

- [ ] **Step 7: Commit**

```bash
git add firmware/src/console.h firmware/src/console.cpp \
        firmware/test/test_console/test_console.cpp firmware/platformio.ini
git commit -m "console: pure serial line parser + native test harness"
```

---

## Task 2: Dispatcher + serial poll wired into the firmware

**Files:**
- Modify: `firmware/src/main.cpp` (include near line 9; console section before `void loop()` at ~line 2547; call inside `loop()` at ~line 2560)

- [ ] **Step 1: Add the include**

In `firmware/src/main.cpp`, alongside the other includes near the top (after `#include <WiFi.h>` at line 9), add:

```cpp
#include "console.h"
```

- [ ] **Step 2: Add the console section before `loop()`**

Insert this block immediately before `void loop() {` (currently line 2547). It references globals already declared earlier in the file: the `pending*` buffers and `*UpdatePending` flags, `displayBrightness`, `scrollSpeedMs`, `nvsPin`, `nvsPinEnforce`, `currentMode`, `enabledMask`, `timerPhase`, `TIMER_OFF`, `FW_VERSION`, the `BLE_*_BUF_LEN` macros, and `WiFi`.

```cpp
// ----------------------------------------------------------------------------
// Serial console — dev/test input path mirroring the BLE control plane.
// Each verb writes the same pending* buffer + *UpdatePending flag the BLE
// callbacks use, so loop()'s applyPending*() does the work. Bypasses the PIN
// gate and the command cooldown: physical USB access already allows reflashing
// the chip, so the console grants no privilege an attacker wouldn't have.
// Runs in loop() on Core 1 — safe to set flags and read display globals; it
// never calls neopixelWrite().
// ----------------------------------------------------------------------------

static void consoleSetPending(char* dest, size_t destLen, const char* src,
                              volatile bool& flag) {
  strncpy(dest, src, destLen - 1);
  dest[destLen - 1] = '\0';
  flag = true;
}

static void consolePrintInfo() {
  Serial.printf("fw=v%s mode=%d mask=0x%02X\n", FW_VERSION, currentMode,
                enabledMask);
  bool up = WiFi.isConnected();
  Serial.printf("wifi=%s ip=%s\n", up ? "connected" : "disconnected",
                up ? WiFi.localIP().toString().c_str() : "-");
  Serial.printf("pin=%s enforce=%s\n", nvsPin, nvsPinEnforce ? "on" : "off");
  Serial.printf("bright=%u scroll=%ums timer=%s\n", displayBrightness,
                (unsigned)scrollSpeedMs,
                timerPhase != TIMER_OFF ? "running" : "off");
}

static void consolePrintHelp() {
  Serial.println(
      "cmds: wifi <ssid> <pass> | apikey <key> | tickers <csv> | "
      "locations <lat,lon,label;..> | mode <all|none|csv> | sign <text> | "
      "power <on|off> | bright <0-15> | scroll <ms> | tz <posix> | "
      "timer <min|cancel> | pin-enforce <on|off> | reload | reset | info | help");
}

static void dispatchConsoleCmd(const ConsoleCmd& cmd) {
  switch (cmd.verb) {
    case CONSOLE_NONE:
      return;
    case CONSOLE_UNKNOWN:
      Serial.println("error: unknown command (try 'help')");
      return;
    case CONSOLE_HELP:
      consolePrintHelp();
      return;
    case CONSOLE_INFO:
      consolePrintInfo();
      return;

    case CONSOLE_WIFI: {
      // BLE buffer wants "ssid|pass"; split arg on the first space.
      const char* sp = strchr(cmd.arg, ' ');
      if (!sp || sp == cmd.arg || *(sp + 1) == '\0') {
        Serial.println("usage: wifi <ssid> <pass>");
        return;
      }
      char joined[BLE_WIFI_BUF_LEN];
      size_t ssidLen = (size_t)(sp - cmd.arg);
      if (ssidLen >= sizeof(joined) - 2) {
        Serial.println("error: ssid too long");
        return;
      }
      memcpy(joined, cmd.arg, ssidLen);
      joined[ssidLen] = '|';
      strncpy(joined + ssidLen + 1, sp + 1, sizeof(joined) - ssidLen - 2);
      joined[sizeof(joined) - 1] = '\0';
      consoleSetPending(pendingWifiStr, sizeof(pendingWifiStr), joined,
                        wifiUpdatePending);
      Serial.println("ok: wifi");
      return;
    }
    case CONSOLE_APIKEY:
      consoleSetPending(pendingApiKey, sizeof(pendingApiKey), cmd.arg,
                        apiKeyUpdatePending);
      Serial.println("ok: apikey");
      return;
    case CONSOLE_TICKERS:
      consoleSetPending(pendingTickerStr, sizeof(pendingTickerStr), cmd.arg,
                        tickerUpdatePending);
      Serial.println("ok: tickers");
      return;
    case CONSOLE_LOCATIONS:
      consoleSetPending(pendingLocsStr, sizeof(pendingLocsStr), cmd.arg,
                        locsUpdatePending);
      Serial.println("ok: locations");
      return;
    case CONSOLE_MODE:
      consoleSetPending(pendingModeStr, sizeof(pendingModeStr), cmd.arg,
                        modeUpdatePending);
      Serial.println("ok: mode");
      return;
    case CONSOLE_SIGN:
      consoleSetPending(pendingStatusStr, sizeof(pendingStatusStr), cmd.arg,
                        statusUpdatePending);
      Serial.println("ok: sign");
      return;
    case CONSOLE_POWER:
      consoleSetPending(pendingPowerStr, sizeof(pendingPowerStr), cmd.arg,
                        powerUpdatePending);
      Serial.println("ok: power");
      return;
    case CONSOLE_TZ:
      consoleSetPending(pendingTzStr, sizeof(pendingTzStr), cmd.arg,
                        tzUpdatePending);
      Serial.println("ok: tz");
      return;

    case CONSOLE_BRIGHT: {
      // applyPendingDisplayCfg() expects "bright|scroll"; keep current scroll.
      char buf[sizeof(pendingDisplayCfgStr)];
      snprintf(buf, sizeof(buf), "%s|%u", cmd.arg, (unsigned)scrollSpeedMs);
      consoleSetPending(pendingDisplayCfgStr, sizeof(pendingDisplayCfgStr), buf,
                        displayCfgUpdatePending);
      Serial.println("ok: bright");
      return;
    }
    case CONSOLE_SCROLL: {
      char buf[sizeof(pendingDisplayCfgStr)];
      snprintf(buf, sizeof(buf), "%u|%s", displayBrightness, cmd.arg);
      consoleSetPending(pendingDisplayCfgStr, sizeof(pendingDisplayCfgStr), buf,
                        displayCfgUpdatePending);
      Serial.println("ok: scroll");
      return;
    }

    // Command-style verbs route through pendingCmd (16-byte buffer).
    case CONSOLE_TIMER: {
      char buf[sizeof(pendingCmd)];
      int n = snprintf(buf, sizeof(buf), "timer %s", cmd.arg);
      if (n < 0 || n >= (int)sizeof(buf)) {
        Serial.println("error: timer arg too long");
        return;
      }
      consoleSetPending(pendingCmd, sizeof(pendingCmd), buf, cmdPending);
      Serial.println("ok: timer");
      return;
    }
    case CONSOLE_PINENFORCE: {
      char buf[sizeof(pendingCmd)];
      int n = snprintf(buf, sizeof(buf), "pin-enforce %s", cmd.arg);
      if (n < 0 || n >= (int)sizeof(buf)) {
        Serial.println("error: pin-enforce arg too long");
        return;
      }
      consoleSetPending(pendingCmd, sizeof(pendingCmd), buf, cmdPending);
      Serial.println("ok: pin-enforce");
      return;
    }
    case CONSOLE_RELOAD:
      consoleSetPending(pendingCmd, sizeof(pendingCmd), "reload", cmdPending);
      Serial.println("ok: reload");
      return;
    case CONSOLE_RESET:
      consoleSetPending(pendingCmd, sizeof(pendingCmd), "reset", cmdPending);
      Serial.println("ok: reset");
      return;
  }
}

// Non-blocking: accumulate one line, then parse + dispatch. Buffer sized to the
// largest payload (locations CSV) plus the verb word and separators.
void pollSerialConsole() {
  static char line[BLE_LOCS_BUF_LEN + 32];
  static size_t len = 0;
  static bool overflow = false;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (overflow) {
        Serial.println("error: line too long");
        overflow = false;
        len = 0;
      } else if (len > 0) {
        line[len] = '\0';
        dispatchConsoleCmd(parseConsoleLine(line));
        len = 0;
      }
    } else if (overflow) {
      continue;  // swallow the rest of an over-long line
    } else if (len < sizeof(line) - 1) {
      line[len++] = c;
    } else {
      overflow = true;
    }
  }
}
```

- [ ] **Step 3: Call the poll at the top of `loop()`**

In `loop()`, immediately before the existing line `if (wifiUpdatePending) applyPendingWifi();` (currently line 2560), add:

```cpp
  pollSerialConsole();  // serial console feeds the same pending* flags below
```

- [ ] **Step 4: Build the firmware**

Run: `pio run -d firmware`
Expected: SUCCESS, no warnings about `dispatchConsoleCmd` (all `ConsoleVerb` cases are handled).

- [ ] **Step 5: Re-run the native unit tests (no regression)**

Run: `pio test -d firmware -e native`
Expected: PASS — `10 Tests 0 Failures 0 Ignored`.

- [ ] **Step 6: Manual smoke test (device or Wokwi)**

Flash (`pio run -d firmware -t upload`) or start the Wokwi sim, open the serial monitor, and verify:
- `help` → prints the command list.
- `info` → prints `fw=…`, `wifi=…`, `pin=…`, `bright=… scroll=… timer=…`.
- `bright 2` → display dims; `info` shows `bright=2`; power-cycle and confirm it persisted (NVS).
- `sign HELLO` → `HELLO` shows on the matrix and overrides ambient.
- `timer 1` → countdown starts; `timer cancel` → resumes ambient.
- `wifi <ssid> <pass>` then `apikey <key>` → `[fetch]` lines appear in serial.
- `frobnicate` → `error: unknown command (try 'help')`.

- [ ] **Step 7: Commit**

```bash
git add firmware/src/main.cpp
git commit -m "console: wire serial dispatcher + poll into loop()"
```

---

## Task 3: Documentation

**Files:**
- Modify: `firmware/FIRMWARE_GUIDE.md`
- Modify: `firmware/WOKWI.md`

- [ ] **Step 1: Document the console in FIRMWARE_GUIDE.md**

Add a new `## Serial console (dev/test)` section. Use this content:

```markdown
## Serial console (dev/test)

A USB-serial command path that mirrors the BLE control plane — handy for local
testing and the **only** way to provision in Wokwi (BLE isn't simulated). Each
command writes the same `pending*` buffer + `*UpdatePending` flag a BLE write
would, so `loop()`'s `applyPending*()` applies it identically.

Open the serial monitor (115200 baud) and type, e.g.:

    wifi MyNetwork mypassword
    apikey d1abc...
    tickers AAPL,MSFT,GOOG
    mode all
    sign HELLO
    timer 5
    info

`info` prints current state; `help` lists every verb. The parser lives in
`src/console.{h,cpp}` (pure, host-tested via `pio test -e native`); the verb
dispatch is in `main.cpp`.

**Security:** the console bypasses the PIN gate. This is intentional — physical
USB access already allows reflashing the chip, so it grants no extra privilege.
`wifi` splits on the first space, so the SSID cannot contain a space (the
password can).
```

- [ ] **Step 2: Point WOKWI.md at the console**

In `firmware/WOKWI.md`, under the "Exercising the weather/stock fetch path"
section, replace the `#ifdef`-seed guidance's opening sentence with a pointer to
the console. Add this paragraph at the top of that section:

```markdown
The simplest way to provision in the sim is the **serial console** (see
FIRMWARE_GUIDE.md → "Serial console") — BLE isn't simulated, but serial is. In
the Wokwi serial monitor type `wifi Wokwi-GUEST ` (empty password) and
`apikey <key>`, then watch the `[fetch]` lines. This avoids baking secrets into
the build.
```

- [ ] **Step 3: Commit**

```bash
git add firmware/FIRMWARE_GUIDE.md firmware/WOKWI.md
git commit -m "docs: document the serial console"
```

---

## Notes for the implementer

- **Do not** add a build flag to gate the console — it is compiled in
  unconditionally by design (see the security note).
- **Do not** re-validate argument contents in the dispatcher (bad timezone, bad
  mode token, bad timer value). The existing `applyPending*()` functions already
  log and reject malformed input; the console only routes raw payloads.
- The `wifi` first-space split means SSIDs with spaces aren't supported over
  serial. That's an accepted limitation (the BLE path uses an explicit `|`).
- If `pio test -e native` can't find Unity, run `pio pkg install` once; PlatformIO
  fetches the Unity framework automatically for `test_framework = unity`.
