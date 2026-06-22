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
bool isSpace(char c) { return c == ' ' || c == '\t'; }
}  // namespace

ConsoleCmd parseConsoleLine(const char* line) {
  ConsoleCmd cmd = {CONSOLE_NONE, ""};
  if (!line) return cmd;

  while (isSpace(*line)) line++;       // skip leading whitespace
  if (*line == '\0') {                 // blank line -> CONSOLE_NONE
    cmd.arg = line;                    // points at the NUL inside the input
    return cmd;
  }

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

bool consoleBuildWifiPayload(const char* arg, char* out, size_t outLen) {
  const char* sp = strchr(arg, ' ');
  size_t ssidLen = sp ? (size_t)(sp - arg) : strlen(arg);
  const char* pass = sp ? sp + 1 : "";
  if (ssidLen >= outLen - 2) return false;  // ssid + '|' + NUL won't fit
  memcpy(out, arg, ssidLen);
  out[ssidLen] = '|';
  strncpy(out + ssidLen + 1, pass, outLen - ssidLen - 2);
  out[outLen - 1] = '\0';  // strncpy may not terminate if pass was truncated
  return true;
}

const char* consoleHelpText(void) {
  return
      "cmds: wifi <ssid> [pass] | apikey <key> | tickers <csv> | "
      "locations <lat,lon,label;..> | mode <all|none|csv> | sign <text> | "
      "power <on|off> | bright <0-15> | scroll <ms> | tz <posix> | "
      "timer <min|cancel> | pin-enforce <on|off> | reload | reset | info | help";
}
