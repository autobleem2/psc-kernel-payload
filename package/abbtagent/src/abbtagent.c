// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * abbtagent - the PlayStation Classic's Bluetooth agent (AutoBleem).
 *
 * BlueZ asks an agent before it completes a cable pairing: the sixaxis plugin, when a DualShock 3 (or its
 * clone), a Navigation controller or a DualShock 4 is plugged in by USB, writes the console's address into
 * the pad and then calls AuthorizeService(device, HID) on the default agent. A console has nobody to ask -
 * with no agent registered the request fails and the pad is never paired. This agent answers that one
 * question and nothing else:
 *
 *   AuthorizeService   yes - for the HID service of a Sony pad the sixaxis plugin handles (vendor 054c,
 *                      products 0268 / 042f / 05c4 / 09cc), and only while the device is not paired yet,
 *                      which is the cable-pairing case: plugging the pad in is the consent.
 *                      no  - for anything else (an untrusted device reaching for a service over the air).
 *   Request*           no - pairing over the air is done from PSC-Bios, which registers its own agent for
 *                      the time it pairs (and so becomes BlueZ's default agent meanwhile).
 *   Display*, Cancel, Release  acknowledged.
 *
 * It registers with capability NoInputNoOutput, asks to be the default agent, and registers again whenever
 * bluetoothd (org.bluez) appears on the bus - after a restart of bluetooth.service, too. Every decision is
 * logged to stderr (the journal).
 *
 * Besides that it keeps the count of connected HID devices (a pad) and tells the 8723bu wifi driver whether
 * there is one (/proc/net/rtl8723bu/<if>/bt_host_hid, 1 or 0) - see docs/bt-pairing.md.
 */
#include <gio/gio.h>
#include <glob.h>
#include <net/if.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>
#include <linux/wireless.h>

#include "afh_map.h"

#define AGENT_PATH "/org/autobleem/agent"
#define HID_UUID "00001124-0000-1000-8000-00805f9b34fb"
#define HID_HINT_GLOB "/proc/net/rtl8723bu/*/bt_host_hid"

static const char *const cable_pads[] = {
	"usb:v054Cp0268", /* DualShock 3 (and the clones that report as one) */
	"usb:v054Cp042F", /* PS Move Navigation controller */
	"usb:v054Cp05C4", /* DualShock 4 */
	"usb:v054Cp09CC", /* DualShock 4 v2 */
	NULL,
};

static const char introspection_xml[] =
	"<node>"
	"  <interface name='org.bluez.Agent1'>"
	"    <method name='Release'/>"
	"    <method name='RequestPinCode'><arg type='o' direction='in'/><arg type='s' direction='out'/></method>"
	"    <method name='DisplayPinCode'><arg type='o' direction='in'/><arg type='s' direction='in'/></method>"
	"    <method name='RequestPasskey'><arg type='o' direction='in'/><arg type='u' direction='out'/></method>"
	"    <method name='DisplayPasskey'><arg type='o' direction='in'/><arg type='u' direction='in'/>"
	"      <arg type='q' direction='in'/></method>"
	"    <method name='RequestConfirmation'><arg type='o' direction='in'/><arg type='u' direction='in'/></method>"
	"    <method name='RequestAuthorization'><arg type='o' direction='in'/></method>"
	"    <method name='AuthorizeService'><arg type='o' direction='in'/><arg type='s' direction='in'/></method>"
	"    <method name='Cancel'/>"
	"  </interface>"
	"</node>";

static GDBusNodeInfo *introspection;
static guint registration_id;

static void log_msg(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void log_msg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fputs("abbtagent: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* a Device1 property of `device`, or NULL (the caller unrefs) */
static GVariant *device_property(GDBusConnection *conn, const char *device, const char *name)
{
	GError *err = NULL;
	GVariant *reply, *value = NULL;

	reply = g_dbus_connection_call_sync(conn, "org.bluez", device, "org.freedesktop.DBus.Properties", "Get",
					    g_variant_new("(ss)", "org.bluez.Device1", name), G_VARIANT_TYPE("(v)"),
					    G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
	if (!reply) {
		log_msg("%s: cannot read %s: %s", device, name, err->message);
		g_error_free(err);
		return NULL;
	}
	g_variant_get(reply, "(v)", &value);
	g_variant_unref(reply);
	return value;
}

static gboolean is_cable_pad(const char *modalias)
{
	for (int i = 0; cable_pads[i]; i++)
		if (strncasecmp(modalias, cable_pads[i], strlen(cable_pads[i])) == 0)
			return TRUE;
	return FALSE;
}

/* AuthorizeService: yes only for a Sony pad's HID service during cable pairing (see the header) */
static gboolean authorize_service(GDBusConnection *conn, const char *device, const char *uuid)
{
	GVariant *modalias, *paired;
	gboolean ok = FALSE;

	if (strcasecmp(uuid, HID_UUID) != 0) {
		log_msg("%s: service %s refused (not HID)", device, uuid);
		return FALSE;
	}
	modalias = device_property(conn, device, "Modalias");
	paired = device_property(conn, device, "Paired");
	if (!modalias || !paired) {
		log_msg("%s: HID refused (no Modalias/Paired)", device);
	} else if (g_variant_get_boolean(paired)) {
		log_msg("%s: HID refused (already paired: an over-the-air connection of an untrusted device)", device);
	} else if (!is_cable_pad(g_variant_get_string(modalias, NULL))) {
		log_msg("%s: HID refused (%s is not a cable-paired Sony pad)", device,
			g_variant_get_string(modalias, NULL));
	} else {
		log_msg("%s: HID authorized (%s, cable pairing)", device, g_variant_get_string(modalias, NULL));
		ok = TRUE;
	}
	if (modalias)
		g_variant_unref(modalias);
	if (paired)
		g_variant_unref(paired);
	return ok;
}

static void reject(GDBusMethodInvocation *inv, const char *why)
{
	g_dbus_method_invocation_return_dbus_error(inv, "org.bluez.Error.Rejected", why);
}

static void method_call(GDBusConnection *conn, const char *sender, const char *path, const char *iface,
			const char *method, GVariant *params, GDBusMethodInvocation *inv, gpointer data)
{
	(void)sender;
	(void)path;
	(void)iface;
	(void)data;

	if (strcmp(method, "AuthorizeService") == 0) {
		const char *device, *uuid;

		g_variant_get(params, "(&o&s)", &device, &uuid);
		if (authorize_service(conn, device, uuid))
			g_dbus_method_invocation_return_value(inv, NULL);
		else
			reject(inv, "not a cable pairing of a known pad");
	} else if (strcmp(method, "RequestPinCode") == 0 || strcmp(method, "RequestPasskey") == 0 ||
		   strcmp(method, "RequestConfirmation") == 0 || strcmp(method, "RequestAuthorization") == 0) {
		const char *device = NULL;

		g_variant_get_child(params, 0, "&o", &device);
		log_msg("%s: %s refused (pairing over the air is PSC-Bios's)", device, method);
		reject(inv, "pair from PSC-Bios");
	} else {
		/* Release, Cancel, DisplayPinCode, DisplayPasskey */
		log_msg("%s", method);
		g_dbus_method_invocation_return_value(inv, NULL);
	}
}

static const GDBusInterfaceVTable vtable = { method_call, NULL, NULL, { 0 } };

static gboolean bluez_call(GDBusConnection *conn, const char *method, GVariant *args)
{
	GError *err = NULL;
	GVariant *reply;

	reply = g_dbus_connection_call_sync(conn, "org.bluez", "/org/bluez", "org.bluez.AgentManager1", method,
					    args, NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
	if (!reply) {
		log_msg("%s failed: %s", method, err->message);
		g_error_free(err);
		return FALSE;
	}
	g_variant_unref(reply);
	return TRUE;
}

/* Host HID hint: the 8723bu wifi coex must be told that a HID device (a pad) is connected, or its firmware takes
 * the pad link for PAN and starves the wifi. The driver exposes /proc/net/rtl8723bu/<if>/bt_host_hid (0/1); there
 * is no such file on a Pi/PC or the stock kernel, and then none of this does anything. */
static int hid_count;

/* write the hint to every bt_host_hid there is (the wifi module may have been reloaded: flag back to 0) */
static void hid_hint_write(void)
{
	const char *val = hid_count > 0 ? "1" : "0";
	glob_t g;

	if (glob(HID_HINT_GLOB, 0, NULL, &g) != 0)
		return;
	for (size_t i = 0; i < g.gl_pathc; i++) {
		FILE *f = fopen(g.gl_pathv[i], "w");

		if (!f)
			continue;
		fputs(val, f);
		fclose(f);
	}
	globfree(&g);
}

static void hid_count_set(int n)
{
	if (n == hid_count)
		return;
	log_msg("HID devices connected: %d -> host HID hint %d", n, n > 0);
	hid_count = n;
	hid_hint_write();
}

/* a Device1 property dictionary (a{sv}) describes a connected HID device: HID UUID, or major class peripheral */
static gboolean is_connected_hid(GVariant *props)
{
	GVariant *v;
	gboolean connected = FALSE, hid = FALSE;

	v = g_variant_lookup_value(props, "Connected", G_VARIANT_TYPE_BOOLEAN);
	if (v) {
		connected = g_variant_get_boolean(v);
		g_variant_unref(v);
	}
	if (!connected)
		return FALSE;
	v = g_variant_lookup_value(props, "Class", G_VARIANT_TYPE_UINT32);
	if (v) {
		hid = ((g_variant_get_uint32(v) >> 8) & 0x1f) == 0x05;
		g_variant_unref(v);
	}
	v = g_variant_lookup_value(props, "UUIDs", G_VARIANT_TYPE_STRING_ARRAY);
	if (v) {
		const char **uuids = g_variant_get_strv(v, NULL);

		for (int i = 0; uuids[i]; i++)
			if (strcasecmp(uuids[i], HID_UUID) == 0)
				hid = TRUE;
		g_free(uuids);
		g_variant_unref(v);
	}
	return hid;
}

/* count the connected HID devices bluetoothd knows (GetManagedObjects) and set the hint */
static void hid_recount(GDBusConnection *conn)
{
	GError *err = NULL;
	GVariant *reply, *objs, *ifaces;
	GVariantIter oi, ii;
	const char *path, *iface;
	GVariant *props;
	int n = 0;

	reply = g_dbus_connection_call_sync(conn, "org.bluez", "/", "org.freedesktop.DBus.ObjectManager",
					    "GetManagedObjects", NULL, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
					    G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
	if (!reply) {
		log_msg("GetManagedObjects failed: %s", err->message);
		g_error_free(err);
		return;
	}
	objs = g_variant_get_child_value(reply, 0);
	g_variant_iter_init(&oi, objs);
	while (g_variant_iter_next(&oi, "{&o@a{sa{sv}}}", &path, &ifaces)) {
		g_variant_iter_init(&ii, ifaces);
		while (g_variant_iter_next(&ii, "{&s@a{sv}}", &iface, &props)) {
			if (strcmp(iface, "org.bluez.Device1") == 0 && is_connected_hid(props))
				n++;
			g_variant_unref(props);
		}
		g_variant_unref(ifaces);
	}
	g_variant_unref(objs);
	g_variant_unref(reply);
	hid_count_set(n);
}

static void hid_changed(GDBusConnection *conn, const char *sender, const char *path, const char *iface,
			const char *signal, GVariant *params, gpointer data)
{
	(void)sender;
	(void)path;
	(void)iface;
	(void)data;

	if (strcmp(signal, "PropertiesChanged") == 0) {
		/* RSSI and friends change all the time during a scan: only these three matter */
		GVariant *changed = g_variant_get_child_value(params, 1);
		GVariantDict dict;
		gboolean relevant;

		g_variant_dict_init(&dict, changed);
		relevant = g_variant_dict_contains(&dict, "Connected") || g_variant_dict_contains(&dict, "UUIDs") ||
			   g_variant_dict_contains(&dict, "Class");
		g_variant_dict_clear(&dict);
		g_variant_unref(changed);
		if (!relevant)
			return;
	}
	hid_recount(conn);
}

/* AFH host channel classification: while a wifi network sits on the 2.4 GHz band, tell every powered Bluetooth
 * controller (any dongle, any wifi chip) not to hop onto the wifi channels. Every 5 s: read the operating channel
 * of each up wlan interface (nl80211, wireless extensions as the fallback), compute the map (afh_map.h), and send
 * HCI_Set_AFH_Host_Channel_Classification through a raw HCI socket when it changed, after a controller power-up,
 * and every 60 s. Off switch: the file AFH_OFF_FILE or the environment variable ABBTAGENT_NO_AFH=1. */
#define AFH_OFF_FILE "/etc/abbtagent-no-afh"
#define AFH_RESEND_SECONDS 60
#define AFH_MAX_HCI 8
#define AFH_MAX_WIF 8

#ifndef AF_BLUETOOTH
#define AF_BLUETOOTH 31
#endif
#define BT_PROTO_HCI 1
#define HCI_GET_DEV_INFO _IOR('H', 211, int)
#define HCI_DEV_UP_FLAG 0x1
#define OP_SET_AFH_CLASSIFICATION 0x0c3f /* OGF 0x03, OCF 0x003f */

struct sockaddr_hci_raw {
	sa_family_t hci_family;
	unsigned short hci_dev;
	unsigned short hci_channel;
};

struct hci_filter_raw {
	uint32_t type_mask;
	uint32_t event_mask[2];
	uint16_t opcode;
};

/* struct hci_dev_info of the kernel (net/bluetooth/hci_sock.h), only dev_id and flags are used */
struct hci_dev_info_raw {
	uint16_t dev_id;
	char name[8];
	uint8_t bdaddr[6];
	uint32_t flags;
	uint8_t type;
	uint8_t features[8];
	uint32_t pkt_type, link_policy, link_mode;
	uint16_t acl_mtu, acl_pkts, sco_mtu, sco_pkts;
	uint32_t stat[10];
} __attribute__((packed));

struct wif {
	char name[IFNAMSIZ];
	int freq, width, center1; /* MHz; 0 = not known */
};

struct hci_ctl {
	gboolean up;
	gboolean no_afh;                 /* the controller refused the command: logged once, not tried again */
	uint8_t last[AFH_MAP_LEN];       /* the map the controller has (all allowed after a power-up) */
	gint64 sent_at;                  /* monotonic µs of the last send, 0 = none */
};

static struct hci_ctl hci_ctls[AFH_MAX_HCI];
static char afh_last_desc[256];
static gboolean afh_was_off;

static void afh_map_hex(const uint8_t *map, char *out)
{
	for (int i = 0; i < AFH_MAP_LEN; i++)
		sprintf(out + 2 * i, "%02x", map[i]);
}

/* "8-52" or "0-22,48-72" or "none": the blocked channels of a map */
static void afh_blocked_ranges(const uint8_t *map, char *out, size_t n)
{
	size_t used = 0;
	int ch = 0;

	out[0] = 0;
	while (ch < AFH_CHANNELS) {
		int first;

		if (afh_map_get(map, ch)) {
			ch++;
			continue;
		}
		first = ch;
		while (ch < AFH_CHANNELS && !afh_map_get(map, ch))
			ch++;
		if (used < n)
			used += snprintf(out + used, n - used, "%s%d-%d", used ? "," : "", first, ch - 1);
	}
	if (!out[0])
		snprintf(out, n, "none");
}

static int nl80211_width_mhz(unsigned w)
{
	switch (w) {
	case NL80211_CHAN_WIDTH_5:
		return 5;
	case NL80211_CHAN_WIDTH_10:
		return 10;
	case NL80211_CHAN_WIDTH_40:
		return 40;
	case NL80211_CHAN_WIDTH_80:
	case NL80211_CHAN_WIDTH_80P80:
		return 80;
	case NL80211_CHAN_WIDTH_160:
		return 160;
	default:
		return 20;
	}
}

/* one generic netlink request, with the replies handed to cb(attrs, len, ctx); returns 0 or -1 */
static int genl_request(int fd, uint16_t type, uint8_t cmd, int dump, const char *str_attr, int str_attr_type,
			void (*cb)(const struct nlattr *, int, void *), void *ctx)
{
	struct {
		struct nlmsghdr nh;
		struct genlmsghdr gh;
		char buf[64];
	} req;
	char *rbuf;
	int len = NLMSG_LENGTH(GENL_HDRLEN), ret = -1;

	memset(&req, 0, sizeof(req));
	req.nh.nlmsg_type = type;
	req.nh.nlmsg_flags = NLM_F_REQUEST | (dump ? NLM_F_DUMP : 0);
	req.nh.nlmsg_seq = 1;
	req.gh.cmd = cmd;
	req.gh.version = 1;
	if (str_attr) {
		struct nlattr *a = (struct nlattr *)((char *)&req + NLMSG_ALIGN(len));
		size_t sl = strlen(str_attr) + 1;

		a->nla_type = str_attr_type;
		a->nla_len = NLA_HDRLEN + sl;
		memcpy((char *)a + NLA_HDRLEN, str_attr, sl);
		len = NLMSG_ALIGN(len) + NLA_ALIGN(a->nla_len);
	}
	req.nh.nlmsg_len = len;
	if (send(fd, &req, len, 0) < 0)
		return -1;
	rbuf = g_malloc(32768);
	for (;;) {
		struct nlmsghdr *nh;
		ssize_t n = recv(fd, rbuf, 32768, 0);

		if (n <= 0)
			break;
		for (nh = (struct nlmsghdr *)rbuf; NLMSG_OK(nh, (unsigned)n); nh = NLMSG_NEXT(nh, n)) {
			if (nh->nlmsg_type == NLMSG_DONE) {
				ret = 0;
				goto out;
			}
			if (nh->nlmsg_type == NLMSG_ERROR)
				goto out;
			cb((const struct nlattr *)((char *)NLMSG_DATA(nh) + GENL_HDRLEN),
			   (int)nh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN), ctx);
			ret = 0;
			if (!dump)
				goto out;
		}
	}
out:
	g_free(rbuf);
	return ret;
}

static void nla_each(const struct nlattr *a, int len, void (*fn)(const struct nlattr *, void *), void *ctx)
{
	while (len >= (int)sizeof(*a) && a->nla_len >= sizeof(*a) && (int)a->nla_len <= len) {
		fn(a, ctx);
		len -= NLA_ALIGN(a->nla_len);
		a = (const struct nlattr *)((const char *)a + NLA_ALIGN(a->nla_len));
	}
}

static void family_attr(const struct nlattr *a, void *ctx)
{
	if ((a->nla_type & NLA_TYPE_MASK) == CTRL_ATTR_FAMILY_ID)
		memcpy(ctx, (const char *)a + NLA_HDRLEN, sizeof(uint16_t));
}

static void family_msg(const struct nlattr *a, int len, void *ctx)
{
	nla_each(a, len, family_attr, ctx);
}

struct wif_list {
	struct wif w[AFH_MAX_WIF];
	int n;
	struct wif cur;
};

static void iface_attr(const struct nlattr *a, void *ctx)
{
	struct wif_list *l = ctx;
	const char *p = (const char *)a + NLA_HDRLEN;

	switch (a->nla_type & NLA_TYPE_MASK) {
	case NL80211_ATTR_IFNAME:
		g_strlcpy(l->cur.name, p, sizeof(l->cur.name));
		break;
	case NL80211_ATTR_WIPHY_FREQ:
		memcpy(&l->cur.freq, p, 4);
		break;
	case NL80211_ATTR_CENTER_FREQ1:
		memcpy(&l->cur.center1, p, 4);
		break;
	case NL80211_ATTR_CHANNEL_WIDTH: {
		unsigned w;

		memcpy(&w, p, 4);
		l->cur.width = nl80211_width_mhz(w);
		break;
	}
	}
}

static void iface_msg(const struct nlattr *a, int len, void *ctx)
{
	struct wif_list *l = ctx;

	memset(&l->cur, 0, sizeof(l->cur));
	nla_each(a, len, iface_attr, l);
	if (l->cur.name[0] && l->n < AFH_MAX_WIF)
		l->w[l->n++] = l->cur;
}

/* the wireless interfaces and their channels from nl80211; -1 if there is no nl80211 */
static int nl80211_interfaces(struct wif_list *l)
{
	uint16_t family = 0;
	int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC), ret = -1;
	struct timeval tv = { 2, 0 };

	l->n = 0;
	if (fd < 0)
		return -1;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	if (genl_request(fd, GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 0, "nl80211", CTRL_ATTR_FAMILY_NAME, family_msg,
			 &family) == 0 &&
	    family)
		ret = genl_request(fd, family, NL80211_CMD_GET_INTERFACE, 1, NULL, 0, iface_msg, l);
	close(fd);
	return ret;
}

static gboolean iface_is_up(int sock, const char *name)
{
	struct ifreq ifr;

	memset(&ifr, 0, sizeof(ifr));
	g_strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
	return ioctl(sock, SIOCGIFFLAGS, &ifr) == 0 && (ifr.ifr_flags & IFF_UP);
}

/* wireless extensions: the frequency in MHz of an interface (a 20 MHz width is assumed), 0 if none */
static int wext_freq(int sock, const char *name)
{
	struct iwreq iwr;
	double hz;

	memset(&iwr, 0, sizeof(iwr));
	g_strlcpy(iwr.ifr_name, name, sizeof(iwr.ifr_name));
	if (ioctl(sock, SIOCGIWFREQ, &iwr) < 0)
		return 0;
	hz = iwr.u.freq.m;
	for (int e = iwr.u.freq.e; e > 0; e--)
		hz *= 10;
	if (iwr.u.freq.e == 0 && iwr.u.freq.m >= 1 && iwr.u.freq.m <= 14) /* a channel number, not a frequency */
		return iwr.u.freq.m == 14 ? 2484 : 2407 + 5 * iwr.u.freq.m;
	return (int)(hz / 1e6);
}

/* the channels of all up wireless interfaces: nl80211 first, wext for what it could not tell. Returns the count
 * of interfaces with a frequency (any band) in l->w[] */
static int wifi_channels(struct wif_list *l, const char **how)
{
	glob_t g;
	int sock = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0), n = 0;

	*how = "nl80211";
	if (nl80211_interfaces(l) < 0)
		l->n = 0;
	/* wireless interfaces that nl80211 did not list (a driver with wext only) */
	if (glob("/sys/class/net/*/wireless", GLOB_NOSORT, NULL, &g) == 0) {
		for (size_t i = 0; i < g.gl_pathc; i++) {
			char name[IFNAMSIZ];
			const char *p = g.gl_pathv[i] + strlen("/sys/class/net/");
			size_t len = strcspn(p, "/");
			gboolean known = FALSE;

			if (len == 0 || len >= sizeof(name))
				continue;
			memcpy(name, p, len);
			name[len] = 0;
			for (int k = 0; k < l->n; k++)
				known |= strcmp(l->w[k].name, name) == 0;
			if (!known && l->n < AFH_MAX_WIF) {
				memset(&l->w[l->n], 0, sizeof(l->w[0]));
				memcpy(l->w[l->n++].name, name, len + 1);
			}
		}
		globfree(&g);
	}
	for (int k = 0; k < l->n; k++) {
		struct wif *w = &l->w[k];

		if (sock < 0 || !iface_is_up(sock, w->name)) {
			w->freq = 0;
			continue;
		}
		if (w->freq == 0) {
			w->freq = wext_freq(sock, w->name);
			if (w->freq)
				*how = "WEXT";
			w->width = 20;
			w->center1 = 0;
		}
		if (w->freq)
			l->w[n++] = *w;
	}
	if (sock >= 0)
		close(sock);
	return n;
}

static gboolean afh_switched_off(void)
{
	const char *env = g_getenv("ABBTAGENT_NO_AFH");

	return (env && env[0] && strcmp(env, "0") != 0) || access(AFH_OFF_FILE, F_OK) == 0;
}

/* whether hci0..hci7 exist and are up */
static void hci_poll_up(int sock, gboolean up[AFH_MAX_HCI])
{
	for (int i = 0; i < AFH_MAX_HCI; i++) {
		struct hci_dev_info_raw di;

		memset(&di, 0, sizeof(di));
		di.dev_id = i;
		up[i] = ioctl(sock, HCI_GET_DEV_INFO, &di) == 0 && (di.flags & HCI_DEV_UP_FLAG);
	}
}

/* send the map to hci<dev>; returns the status (0 = success), -1 no answer/socket trouble */
static int hci_send_map(int dev, const uint8_t map[AFH_MAP_LEN])
{
	struct sockaddr_hci_raw sa;
	struct hci_filter_raw flt;
	uint8_t cmd[4 + AFH_MAP_LEN] = { 0x01, OP_SET_AFH_CLASSIFICATION & 0xff, OP_SET_AFH_CLASSIFICATION >> 8,
					 AFH_MAP_LEN };
	int fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BT_PROTO_HCI), status = -1;
	gint64 end = g_get_monotonic_time() + 2 * G_USEC_PER_SEC;

	if (fd < 0)
		return -1;
	memset(&flt, 0, sizeof(flt));
	flt.type_mask = 1u << 4;                    /* HCI_EVENT_PKT */
	flt.event_mask[0] = (1u << 0x0e) | (1u << 0x0f); /* command complete, command status */
	flt.opcode = OP_SET_AFH_CLASSIFICATION;
	memset(&sa, 0, sizeof(sa));
	sa.hci_family = AF_BLUETOOTH;
	sa.hci_dev = dev;
	if (setsockopt(fd, 0 /* SOL_HCI */, 2 /* HCI_FILTER */, &flt, sizeof(flt)) < 0 ||
	    bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0)
		goto out;
	memcpy(cmd + 4, map, AFH_MAP_LEN);
	if (write(fd, cmd, sizeof(cmd)) != (ssize_t)sizeof(cmd))
		goto out;
	while (g_get_monotonic_time() < end) {
		struct pollfd p = { fd, POLLIN, 0 };
		uint8_t ev[260];
		ssize_t n;

		if (poll(&p, 1, 500) <= 0)
			continue;
		n = read(fd, ev, sizeof(ev));
		if (n >= 7 && ev[0] == 0x04 && ev[1] == 0x0e && ev[4] + (ev[5] << 8) == OP_SET_AFH_CLASSIFICATION) {
			status = ev[6]; /* Command Complete: ncmd, opcode, status */
			break;
		}
		if (n >= 7 && ev[0] == 0x04 && ev[1] == 0x0f && ev[5] + (ev[6] << 8) == OP_SET_AFH_CLASSIFICATION) {
			status = ev[3]; /* Command Status: status, ncmd, opcode */
			break;
		}
	}
out:
	close(fd);
	return status;
}

/* every 5 s: work out the wanted map and bring the controllers to it */
static void afh_tick(void)
{
	struct wif_list *l = g_new0(struct wif_list, 1);
	uint8_t want[AFH_MAP_LEN];
	char desc[256] = "", hex[2 * AFH_MAP_LEN + 1], ranges[96];
	const char *how = "nl80211";
	gboolean up[AFH_MAX_HCI], off = afh_switched_off(), changed;
	gint64 now = g_get_monotonic_time();
	int hsock, n;

	afh_map_all(want);
	if (off) {
		if (!afh_was_off)
			log_msg("AFH: switched off (%s or ABBTAGENT_NO_AFH=1)", AFH_OFF_FILE);
		snprintf(desc, sizeof(desc), "switched off");
	} else {
		n = wifi_channels(l, &how);
		for (int k = 0; k < n; k++) {
			struct wif *w = &l->w[k];
			int len = strlen(desc);

			if (w->freq < 2400 || w->freq > 2500)
				continue;
			afh_map_block(want, w->center1 > 0 ? w->center1 : w->freq, w->width);
			snprintf(desc + len, sizeof(desc) - len, "%s%s %d MHz/%d", len ? ", " : "", w->name,
				 w->center1 > 0 ? w->center1 : w->freq, w->width > 0 ? w->width : 20);
		}
		if (desc[0])
			afh_map_floor(want, 2442);
		else
			snprintf(desc, sizeof(desc), "no 2.4 GHz wifi");
	}
	afh_was_off = off;
	g_free(l);

	changed = strcmp(desc, afh_last_desc) != 0;
	afh_map_hex(want, hex);
	if (changed) {
		afh_blocked_ranges(want, ranges, sizeof(ranges));
		log_msg("AFH: %s -> blocked BT ch %s, map %s (read by %s)", desc, ranges, hex, how);
		g_strlcpy(afh_last_desc, desc, sizeof(afh_last_desc));
	}

	hsock = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BT_PROTO_HCI);
	if (hsock < 0)
		return;
	hci_poll_up(hsock, up);
	close(hsock);
	for (int i = 0; i < AFH_MAX_HCI; i++) {
		struct hci_ctl *c = &hci_ctls[i];
		uint8_t all[AFH_MAP_LEN];
		gboolean restricted, differs;
		int status;

		if (!up[i]) {
			c->up = FALSE;
			continue;
		}
		afh_map_all(all);
		if (!c->up) { /* (re)powered: the controller starts with every channel allowed */
			c->up = TRUE;
			c->no_afh = FALSE;
			memcpy(c->last, all, AFH_MAP_LEN);
			c->sent_at = 0;
		}
		if (c->no_afh)
			continue;
		differs = memcmp(c->last, want, AFH_MAP_LEN) != 0;
		restricted = memcmp(want, all, AFH_MAP_LEN) != 0;
		if (!differs && !(restricted && now - c->sent_at >= AFH_RESEND_SECONDS * G_USEC_PER_SEC))
			continue;
		status = hci_send_map(i, want);
		if (status == 0) {
			if (differs)
				log_msg("AFH: hci%d map %s sent, status 0", i, hex);
			memcpy(c->last, want, AFH_MAP_LEN);
			c->sent_at = now;
		} else if (status > 0) {
			log_msg("AFH: hci%d refused the map, status 0x%02x - no more tries for it", i, status);
			c->no_afh = TRUE;
		} else {
			log_msg("AFH: hci%d: no answer to the map (will retry)", i);
		}
	}
}

static gboolean hid_tick(gpointer data)
{
	(void)data;
	hid_hint_write();
	afh_tick();
	return G_SOURCE_CONTINUE;
}

/* bluetoothd is (back) on the bus: register, and ask to be the default agent */
static void bluez_appeared(GDBusConnection *conn, const char *name, const char *owner, gpointer data)
{
	(void)name;
	(void)data;

	log_msg("bluetoothd is %s", owner);
	if (bluez_call(conn, "RegisterAgent", g_variant_new("(os)", AGENT_PATH, "NoInputNoOutput")) &&
	    bluez_call(conn, "RequestDefaultAgent", g_variant_new("(o)", AGENT_PATH)))
		log_msg("registered as the default agent");
	hid_recount(conn);
}

static void bluez_vanished(GDBusConnection *conn, const char *name, gpointer data)
{
	(void)conn;
	(void)name;
	(void)data;
	log_msg("bluetoothd went away - waiting for it");
	hid_count_set(0);
}

int main(void)
{
	GError *err = NULL;
	GDBusConnection *conn;
	GMainLoop *loop;

	conn = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
	if (!conn) {
		log_msg("no system bus: %s", err->message);
		return 1;
	}
	introspection = g_dbus_node_info_new_for_xml(introspection_xml, &err);
	if (!introspection) {
		log_msg("introspection: %s", err->message);
		return 1;
	}
	registration_id = g_dbus_connection_register_object(conn, AGENT_PATH, introspection->interfaces[0], &vtable,
							    NULL, NULL, &err);
	if (!registration_id) {
		log_msg("cannot export %s: %s", AGENT_PATH, err->message);
		return 1;
	}
	/* a Device1 property changed (Connected, UUIDs, Class), or a device appeared/went: count the pads again */
	g_dbus_connection_signal_subscribe(conn, "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged",
					   NULL, "org.bluez.Device1", G_DBUS_SIGNAL_FLAGS_NONE, hid_changed, NULL, NULL);
	g_dbus_connection_signal_subscribe(conn, "org.bluez", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded",
					   NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE, hid_changed, NULL, NULL);
	g_dbus_connection_signal_subscribe(conn, "org.bluez", "org.freedesktop.DBus.ObjectManager",
					   "InterfacesRemoved", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE, hid_changed, NULL,
					   NULL);
	g_timeout_add_seconds(5, hid_tick, NULL);
	g_bus_watch_name_on_connection(conn, "org.bluez", G_BUS_NAME_WATCHER_FLAGS_NONE, bluez_appeared,
				       bluez_vanished, NULL, NULL);

	loop = g_main_loop_new(NULL, FALSE);
	g_main_loop_run(loop);
	return 0;
}
