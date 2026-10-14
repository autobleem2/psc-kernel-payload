/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * AFH host channel map: which Bluetooth channels may be used while a wifi network sits on the 2.4 GHz band.
 * Pure functions (no I/O) so that afh_test.c can check them on the host. Included by abbtagent.c.
 *
 * The map is the 10-byte argument of HCI_Set_AFH_Host_Channel_Classification: 79 bits, LSB first, bit k is
 * Bluetooth channel k (2402 + k MHz), 1 = may be used. Bit 79 (the top bit of byte 9) is reserved and stays 0.
 */
#ifndef AFH_MAP_H
#define AFH_MAP_H

#include <stdint.h>
#include <string.h>

#define AFH_MAP_LEN 10
#define AFH_CHANNELS 79
#define AFH_MIN_ALLOWED 20 /* the Bluetooth spec wants at least 20 channels used */
#define AFH_MARGIN_MHZ 2   /* guard on both sides of the wifi band */

static inline void afh_map_all(uint8_t map[AFH_MAP_LEN])
{
	memset(map, 0xff, AFH_MAP_LEN - 1);
	map[AFH_MAP_LEN - 1] = 0x7f;
}

static inline int afh_map_get(const uint8_t map[AFH_MAP_LEN], int ch)
{
	return (map[ch >> 3] >> (ch & 7)) & 1;
}

static inline int afh_map_allowed(const uint8_t map[AFH_MAP_LEN])
{
	int n = 0;

	for (int ch = 0; ch < AFH_CHANNELS; ch++)
		n += afh_map_get(map, ch);
	return n;
}

/* block the channels within width/2 + margin of `center` (MHz); a width <= 0 is taken as 20 MHz */
static inline void afh_map_block(uint8_t map[AFH_MAP_LEN], int center, int width)
{
	int lo, hi;

	if (width <= 0)
		width = 20;
	lo = center - width / 2 - AFH_MARGIN_MHZ;
	hi = center + width / 2 + AFH_MARGIN_MHZ;
	for (int ch = 0; ch < AFH_CHANNELS; ch++)
		if (2402 + ch >= lo && 2402 + ch <= hi)
			map[ch >> 3] &= (uint8_t)~(1u << (ch & 7));
}

/* keep at least AFH_MIN_ALLOWED channels: give back the blocked ones farthest from the band centre `center` */
static inline void afh_map_floor(uint8_t map[AFH_MAP_LEN], int center)
{
	int allowed = afh_map_allowed(map);

	while (allowed < AFH_MIN_ALLOWED) {
		int best = -1, best_d = -1;

		for (int ch = 0; ch < AFH_CHANNELS; ch++) {
			int d = 2402 + ch - center;

			if (d < 0)
				d = -d;
			if (!afh_map_get(map, ch) && d > best_d) {
				best = ch;
				best_d = d;
			}
		}
		if (best < 0)
			break;
		map[best >> 3] |= (uint8_t)(1u << (best & 7));
		allowed++;
	}
}

/* the map for one wifi channel: freq = operating frequency, width in MHz, center1 = centre of the (wide)
 * channel, 0 if unknown. Outside the 2.4 GHz band nothing is blocked. */
static inline void afh_map_for(int freq, int width, int center1, uint8_t map[AFH_MAP_LEN])
{
	int center = center1 > 0 ? center1 : freq;

	afh_map_all(map);
	if (freq < 2400 || freq > 2500)
		return;
	afh_map_block(map, center, width);
	afh_map_floor(map, center);
}

#endif
