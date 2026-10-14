// SPDX-License-Identifier: GPL-2.0-or-later
/* Host unit test of the AFH map (afh_map.h). Run: gcc -Wall -Wextra -o afh_test afh_test.c && ./afh_test */
#include <stdio.h>

#include "afh_map.h"

static int fails;

/* blocked channels of `map` as "a-b" (one range; the cases below have one) or "none" */
static void blocked_str(const uint8_t map[AFH_MAP_LEN], char *out, size_t n)
{
	int first = -1, last = -1;

	for (int ch = 0; ch < AFH_CHANNELS; ch++)
		if (!afh_map_get(map, ch)) {
			if (first < 0)
				first = ch;
			last = ch;
		}
	if (first < 0)
		snprintf(out, n, "none");
	else
		snprintf(out, n, "%d-%d", first, last);
}

static void check(const char *name, int freq, int width, int center1, const char *want, int want_allowed)
{
	uint8_t map[AFH_MAP_LEN];
	char got[32];
	int allowed;

	afh_map_for(freq, width, center1, map);
	blocked_str(map, got, sizeof(got));
	allowed = afh_map_allowed(map);
	if (strcmp(got, want) != 0 || allowed != want_allowed || (map[9] & 0x80)) {
		printf("FAIL %-28s blocked %s (want %s), allowed %d (want %d)\n", name, got, want, allowed, want_allowed);
		fails++;
	} else {
		printf("ok   %-28s blocked %s, allowed %d\n", name, got, allowed);
	}
}

int main(void)
{
	uint8_t map[AFH_MAP_LEN];

	check("ch 3 HT40+ (2422/40, c 2432)", 2422, 40, 2432, "8-52", 34);
	check("ch 1 20 MHz", 2412, 20, 2412, "0-22", 56);
	check("ch 1 20 MHz, no center1", 2412, 20, 0, "0-22", 56);
	check("ch 11 20 MHz", 2462, 20, 2462, "48-72", 54);
	check("ch 13 HT40- (2472/40, c 2462)", 2472, 40, 2462, "38-78", 38);
	check("ch 14 20 MHz (2484)", 2484, 20, 2484, "70-78", 70);
	check("5 GHz (5180)", 5180, 20, 5180, "none", 79);
	check("5 GHz (5180, 80 MHz)", 5180, 80, 5210, "none", 79);
	check("no freq", 0, 0, 0, "none", 79);

	/* the floor: a 40 MHz block would leave 34; an absurd 100 MHz wide band blocks all, 20 stay */
	afh_map_for(2442, 100, 2442, map);
	if (afh_map_allowed(map) != AFH_MIN_ALLOWED) {
		printf("FAIL floor: %d allowed\n", afh_map_allowed(map));
		fails++;
	} else {
		/* the ones given back are the farthest from 2442: both ends: ch 0-10 and 70-78 */
		int ok = 1;

		for (int ch = 0; ch < AFH_CHANNELS; ch++)
			if (afh_map_get(map, ch) != (ch <= 10 || ch >= 70))
				ok = 0;
		printf("%s floor: 100 MHz wide band keeps %d channels, farthest first\n", ok ? "ok  " : "FAIL",
		       afh_map_allowed(map));
		fails += !ok;
	}

	/* two wifi networks (ch 1 and ch 11) together, then the floor */
	afh_map_all(map);
	afh_map_block(map, 2412, 20);
	afh_map_block(map, 2462, 20);
	afh_map_floor(map, 2437);
	if (afh_map_allowed(map) != 31 || afh_map_get(map, 0) || !afh_map_get(map, 30) || afh_map_get(map, 60)) {
		printf("FAIL two networks: %d allowed\n", afh_map_allowed(map));
		fails++;
	} else {
		printf("ok   two networks (ch 1 + ch 11): %d allowed\n", afh_map_allowed(map));
	}

	/* the all-allowed map is ff x9, 7f */
	afh_map_all(map);
	if (map[0] != 0xff || map[8] != 0xff || map[9] != 0x7f) {
		printf("FAIL all-allowed bytes\n");
		fails++;
	} else {
		printf("ok   all-allowed map = ff x9, 7f\n");
	}

	printf(fails ? "%d FAILED\n" : "all passed\n", fails);
	return fails != 0;
}
