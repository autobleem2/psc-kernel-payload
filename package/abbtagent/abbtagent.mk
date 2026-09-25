################################################################################
#
# abbtagent - the console's Bluetooth agent: authorizes the cable pairing of
# Sony pads (BlueZ's sixaxis plugin asks an agent, and a console has nobody
# to ask). Source: package/abbtagent/src/abbtagent.c
#
################################################################################

ABBTAGENT_VERSION = 1.0
ABBTAGENT_SITE = $(BR2_EXTERNAL_PSC_PATH)/package/abbtagent/src
ABBTAGENT_SITE_METHOD = local
ABBTAGENT_LICENSE = GPL-2.0+
ABBTAGENT_DEPENDENCIES = libglib2 host-pkgconf

define ABBTAGENT_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -std=gnu99 -Wall -Wextra \
		-o $(@D)/abbtagent $(@D)/abbtagent.c \
		`$(PKG_CONFIG_HOST_BINARY) --cflags --libs gio-2.0` $(TARGET_LDFLAGS)
endef

# the unit, and its link under bluetooth.target.wants: started whenever the console's bluetooth.target is
# reached (a Bluetooth adapter is there), as bluetooth.service is (scripts/verify.sh allows exactly these)
define ABBTAGENT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/abbtagent $(TARGET_DIR)/usr/sbin/abbtagent
	$(INSTALL) -D -m 0644 $(ABBTAGENT_PKGDIR)/abbtagent.service \
		$(TARGET_DIR)/lib/systemd/system/abbtagent.service
	mkdir -p $(TARGET_DIR)/etc/systemd/system/bluetooth.target.wants
	ln -sf /lib/systemd/system/abbtagent.service \
		$(TARGET_DIR)/etc/systemd/system/bluetooth.target.wants/abbtagent.service
endef

$(eval $(generic-package))
