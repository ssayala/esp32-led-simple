#pragma once

#include <stddef.h>

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

// Build the applyPendingWifi() payload "ssid|pass" from a "wifi" verb's arg.
// Splits on the first space — the SSID can't contain one, but the password can;
// no space means an open network (empty password). `arg` must be non-empty
// (caller's policy). Returns false if the SSID plus separator won't fit in
// `outLen`, leaving `out` unspecified; otherwise `out` is NUL-terminated.
bool consoleBuildWifiPayload(const char* arg, char* out, size_t outLen);

// One-line command summary printed by the `help` verb. Lives here so it stays
// in sync with the verb table. No Arduino deps — caller does the I/O.
const char* consoleHelpText(void);
