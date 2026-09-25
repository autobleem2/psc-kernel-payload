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
 */
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#define AGENT_PATH "/org/autobleem/agent"
#define HID_UUID "00001124-0000-1000-8000-00805f9b34fb"

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

/* bluetoothd is (back) on the bus: register, and ask to be the default agent */
static void bluez_appeared(GDBusConnection *conn, const char *name, const char *owner, gpointer data)
{
	(void)name;
	(void)data;

	log_msg("bluetoothd is %s", owner);
	if (bluez_call(conn, "RegisterAgent", g_variant_new("(os)", AGENT_PATH, "NoInputNoOutput")) &&
	    bluez_call(conn, "RequestDefaultAgent", g_variant_new("(o)", AGENT_PATH)))
		log_msg("registered as the default agent");
}

static void bluez_vanished(GDBusConnection *conn, const char *name, gpointer data)
{
	(void)conn;
	(void)name;
	(void)data;
	log_msg("bluetoothd went away - waiting for it");
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
	g_bus_watch_name_on_connection(conn, "org.bluez", G_BUS_NAME_WATCHER_FLAGS_NONE, bluez_appeared,
				       bluez_vanished, NULL, NULL);

	loop = g_main_loop_new(NULL, FALSE);
	g_main_loop_run(loop);
	return 0;
}
