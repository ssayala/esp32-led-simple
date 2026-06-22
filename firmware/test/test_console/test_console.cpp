#include <unity.h>
#include <string.h>
#include "console.h"

void test_null_input(void) {
  ConsoleCmd c = parseConsoleLine(nullptr);
  TEST_ASSERT_EQUAL(CONSOLE_NONE, c.verb);
  TEST_ASSERT_EQUAL_STRING("", c.arg);
}
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

// ---------------------------------------------------------------------------
// consoleBuildWifiPayload — split "ssid pass" into the "ssid|pass" payload.
// ---------------------------------------------------------------------------
void test_wifi_ssid_and_pass(void) {
  char out[64];
  TEST_ASSERT_TRUE(consoleBuildWifiPayload("MyNet secret123", out, sizeof(out)));
  TEST_ASSERT_EQUAL_STRING("MyNet|secret123", out);
}
void test_wifi_open_network_no_pass(void) {
  char out[64];
  TEST_ASSERT_TRUE(consoleBuildWifiPayload("Wokwi-GUEST", out, sizeof(out)));
  TEST_ASSERT_EQUAL_STRING("Wokwi-GUEST|", out);
}
void test_wifi_password_keeps_spaces(void) {
  // Only the first space splits — the password may contain more.
  char out[64];
  TEST_ASSERT_TRUE(consoleBuildWifiPayload("Net pass with spaces", out,
                                           sizeof(out)));
  TEST_ASSERT_EQUAL_STRING("Net|pass with spaces", out);
}
void test_wifi_ssid_too_long_rejected(void) {
  char out[8];  // "ssid" (4) + '|' + NUL needs the ssid < 6 chars here
  TEST_ASSERT_FALSE(consoleBuildWifiPayload("LongSsidName pw", out, sizeof(out)));
}
void test_wifi_password_truncates_to_fit(void) {
  // ssid fits, password is clamped to the buffer (matches firmware behavior).
  char out[10];  // holds "ab|" + 6 pass chars + NUL
  TEST_ASSERT_TRUE(consoleBuildWifiPayload("ab longpassword", out, sizeof(out)));
  TEST_ASSERT_EQUAL_STRING("ab|longpa", out);
}

void setUp(void) {}
void tearDown(void) {}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_null_input);
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
  RUN_TEST(test_wifi_ssid_and_pass);
  RUN_TEST(test_wifi_open_network_no_pass);
  RUN_TEST(test_wifi_password_keeps_spaces);
  RUN_TEST(test_wifi_ssid_too_long_rejected);
  RUN_TEST(test_wifi_password_truncates_to_fit);
  return UNITY_END();
}
