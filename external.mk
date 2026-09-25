# BR2_EXTERNAL PSC - the payload's own packages.
include $(sort $(wildcard $(BR2_EXTERNAL_PSC_PATH)/package/*/*.mk))
