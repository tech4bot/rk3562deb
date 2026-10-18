// SPDX-License-Identifier: GPL-2.0-only
/*
 * Hynetek HUSB320 USB Type-C controller driver
 *
 * Copyright (C) 2026 Hongyang Zhao <hongyang.zhao@....com>
 */

#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/property.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/usb/role.h>
#include <linux/usb/typec.h>
#include <linux/usb/typec_altmode.h>

#define HUSB320_REG_DEVICE_ID		0x01
#define HUSB320_REG_DEVICE_TYPE		0x02
#define HUSB320_REG_PORT_ROLE		0x03
#define HUSB320_REG_CONTROL		0x04
#define HUSB320_REG_CONTROL1		0x05
#define HUSB320_REG_MANUAL		0x09
#define HUSB320_REG_RESET		0x0a
#define HUSB320_REG_MASK			0x0e
#define HUSB320_REG_MASK1		0x0f
#define HUSB320_REG_STATUS		0x11
#define HUSB320_REG_TYPE			0x13
#define HUSB320_REG_INTERRUPT		0x14
#define HUSB320_REG_INTERRUPT1		0x15

#define HUSB320_DEVICE_ID_VERSION	GENMASK(7, 4)
#define HUSB320_DEVICE_ID_REVISION	GENMASK(3, 0)
#define HUSB320_DEVICE_ID_VERSION_1	1
#define HUSB320_DEVICE_TYPE		0x03

#define HUSB320_PORT_ROLE_TRY		GENMASK(5, 4)
#define HUSB320_PORT_ROLE_MODE		GENMASK(2, 0)
#define HUSB320_PORT_ROLE_SOURCE		BIT(0)
#define HUSB320_PORT_ROLE_SINK		BIT(1)
#define HUSB320_PORT_ROLE_DRP		BIT(2)
#define HUSB320_TRY_NONE			0
#define HUSB320_TRY_SINK			1
#define HUSB320_TRY_SOURCE		2

#define HUSB320_CONTROL_HOST_CURRENT	GENMASK(2, 1)
#define HUSB320_CONTROL_INT_MASK		BIT(0)
#define HUSB320_HOST_CURRENT_DEFAULT	1
#define HUSB320_HOST_CURRENT_1_5A	2
#define HUSB320_HOST_CURRENT_3_0A	3

#define HUSB320_CONTROL1_ENABLE		BIT(3)

#define HUSB320_MANUAL_ERROR_RECOVERY	BIT(0)

#define HUSB320_RESET_SW			BIT(0)

/* The datasheet defines the fault mask, but reserves the matching IRQ bit. */
#define HUSB320_MASK_FAULT		BIT(5)
#define HUSB320_MASK_AUTOSINK		BIT(3)
#define HUSB320_MASK1_FORCE		GENMASK(2, 1)

#define HUSB320_STATUS_ORIENTATION	GENMASK(5, 4)
#define HUSB320_STATUS_ORIENTATION_CC1	1
#define HUSB320_STATUS_ORIENTATION_CC2	2
#define HUSB320_STATUS_CURRENT		GENMASK(2, 1)
#define HUSB320_STATUS_ATTACHED		BIT(0)

#define HUSB320_TYPE_DEBUG_SOURCE	BIT(6)
#define HUSB320_TYPE_DEBUG_SINK		BIT(5)
#define HUSB320_TYPE_SINK		BIT(4)
#define HUSB320_TYPE_SOURCE		BIT(3)
#define HUSB320_TYPE_AUDIO_VBUS		BIT(1)
#define HUSB320_TYPE_AUDIO		BIT(0)

#define HUSB320_INT_ORIENTATION		BIT(6)
#define HUSB320_INT_VBUS_CHANGE		BIT(4)
#define HUSB320_INT_AUTOSINK		BIT(3)
#define HUSB320_INT_CURRENT_CHANGE	BIT(2)
#define HUSB320_INT_DETACH		BIT(1)
#define HUSB320_INT_ATTACH		BIT(0)
#define HUSB320_INT_VALID		(HUSB320_INT_ORIENTATION | \
					 HUSB320_INT_VBUS_CHANGE | \
					 HUSB320_INT_AUTOSINK | \
					 HUSB320_INT_CURRENT_CHANGE | \
					 HUSB320_INT_DETACH | \
					 HUSB320_INT_ATTACH)
#define HUSB320_INT1_VALID		GENMASK(2, 1)

enum husb320_state {
	HUSB320_STATE_UNATTACHED,
	HUSB320_STATE_SOURCE,
	HUSB320_STATE_SINK,
	HUSB320_STATE_DEBUG_SOURCE,
	HUSB320_STATE_DEBUG_SINK,
	HUSB320_STATE_AUDIO,
};

struct husb320 {
	struct device *dev;
	struct regmap *regmap;
	struct gpio_desc *enable_gpio;
	struct regulator *vbus;
	struct usb_role_switch *role_sw;
	struct typec_capability cap;
	struct typec_port *port;
	struct typec_partner *partner;
	struct fwnode_handle *connector;
	/* Serializes controller access and Type-C state updates. */
	struct mutex lock;
	enum typec_port_type port_type;
	enum typec_role preferred_role;
	enum typec_pwr_opmode source_opmode;
	enum husb320_state state;
	enum usb_role usb_role;
	int connector_mode;
	bool has_data;
	bool mode_valid;
	bool shutting_down;
	bool state_valid;
	bool vbus_on;
};

static const struct regmap_config husb320_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = HUSB320_REG_INTERRUPT1,
};

static enum typec_role husb320_default_power_role(struct husb320 *husb)
{
	switch (husb->port_type) {
	case TYPEC_PORT_SRC:
		return TYPEC_SOURCE;
	case TYPEC_PORT_SNK:
		return TYPEC_SINK;
	case TYPEC_PORT_DRP:
	default:
		if (husb->preferred_role == TYPEC_SOURCE)
			return TYPEC_SOURCE;

		return TYPEC_SINK;
	}
}

static enum typec_data_role husb320_default_data_role(struct husb320 *husb)
{
	switch (husb->cap.data) {
	case TYPEC_PORT_DFP:
		return TYPEC_HOST;
	case TYPEC_PORT_UFP:
		return TYPEC_DEVICE;
	case TYPEC_PORT_DRD:
	default:
		return husb320_default_power_role(husb) == TYPEC_SOURCE ?
			TYPEC_HOST : TYPEC_DEVICE;
	}
}

static void husb320_set_unattached_roles(struct husb320 *husb)
{
	enum typec_role power_role = husb320_default_power_role(husb);

	typec_set_pwr_role(husb->port, power_role);
	if (husb->has_data)
		typec_set_data_role(husb->port,
				    husb320_default_data_role(husb));
	typec_set_pwr_opmode(husb->port,
			     power_role == TYPEC_SOURCE ?
			     husb->source_opmode : TYPEC_PWR_MODE_USB);
}

static int husb320_set_vbus(struct husb320 *husb, bool enable)
{
	int ret;

	if (!husb->vbus || husb->vbus_on == enable)
		return 0;

	if (enable)
		ret = regulator_enable(husb->vbus);
	else
		ret = regulator_disable(husb->vbus);
	if (ret)
		return ret;

	husb->vbus_on = enable;

	return 0;
}

static int husb320_set_mode(struct husb320 *husb, int mode)
{
	int ret;

	if (husb->mode_valid && husb->connector_mode == mode)
		return 0;

	ret = typec_set_mode(husb->port, mode);
	if (ret)
		return ret;

	husb->connector_mode = mode;
	husb->mode_valid = true;

	return 0;
}

static void husb320_unregister_partner(struct husb320 *husb)
{
	if (!husb->partner)
		return;

	typec_unregister_partner(husb->partner);
	husb->partner = NULL;
}

static int husb320_register_partner(struct husb320 *husb,
				    enum typec_accessory accessory)
{
	struct typec_partner_desc desc = {
		.accessory = accessory,
		.usb_pd = false,
	};

	if (husb->partner)
		return 0;

	husb->partner = typec_register_partner(husb->port, &desc);
	if (IS_ERR(husb->partner)) {
		int ret = PTR_ERR(husb->partner);

		husb->partner = NULL;
		return ret;
	}

	return 0;
}

static int husb320_disconnect(struct husb320 *husb)
{
	int err = 0;
	int ret;

	ret = husb320_set_vbus(husb, false);
	if (ret)
		err = ret;

	ret = usb_role_switch_set_role(husb->role_sw, USB_ROLE_NONE);
	if (ret) {
		if (!err)
			err = ret;
	} else {
		husb->usb_role = USB_ROLE_NONE;
	}

	ret = husb320_set_mode(husb, TYPEC_STATE_SAFE);
	if (ret && !err)
		err = ret;

	husb320_unregister_partner(husb);

	if (typec_get_orientation(husb->port) != TYPEC_ORIENTATION_NONE) {
		ret = typec_set_orientation(husb->port, TYPEC_ORIENTATION_NONE);
		if (ret && !err)
			err = ret;
	}

	husb320_set_unattached_roles(husb);

	husb->state = HUSB320_STATE_UNATTACHED;
	husb->state_valid = !err;

	return err;
}

static int husb320_hw_disable(struct husb320 *husb);

static void husb320_error_recovery(struct husb320 *husb)
{
	int cleanup_ret;
	int disable_ret;
	int recovery_ret;

	cleanup_ret = husb320_disconnect(husb);
	recovery_ret = regmap_write(husb->regmap, HUSB320_REG_MANUAL,
				    HUSB320_MANUAL_ERROR_RECOVERY);
	if (cleanup_ret)
		dev_err_ratelimited(husb->dev,
				    "failed to clean up port: %d\n", cleanup_ret);
	if (recovery_ret)
		dev_err_ratelimited(husb->dev,
				    "failed to start error recovery: %d\n",
				    recovery_ret);

	if (!cleanup_ret && !recovery_ret)
		return;

	husb->shutting_down = true;
	disable_ret = husb320_hw_disable(husb);
	if (disable_ret)
		dev_err_ratelimited(husb->dev,
				    "failed to disable controller: %d\n",
				    disable_ret);
}

static enum typec_pwr_opmode husb320_sink_opmode(unsigned int status)
{
	switch (FIELD_GET(HUSB320_STATUS_CURRENT, status)) {
	case 2:
		return TYPEC_PWR_MODE_1_5A;
	case 3:
		return TYPEC_PWR_MODE_3_0A;
	case 0:
	case 1:
	default:
		return TYPEC_PWR_MODE_USB;
	}
}

static enum typec_role husb320_state_power_role(enum husb320_state state)
{
	switch (state) {
	case HUSB320_STATE_SOURCE:
	case HUSB320_STATE_DEBUG_SOURCE:
	case HUSB320_STATE_AUDIO:
		return TYPEC_SOURCE;
	case HUSB320_STATE_SINK:
	case HUSB320_STATE_DEBUG_SINK:
	case HUSB320_STATE_UNATTACHED:
	default:
		return TYPEC_SINK;
	}
}

static enum typec_accessory husb320_state_accessory(enum husb320_state state)
{
	switch (state) {
	case HUSB320_STATE_DEBUG_SOURCE:
	case HUSB320_STATE_DEBUG_SINK:
		return TYPEC_ACCESSORY_DEBUG;
	case HUSB320_STATE_AUDIO:
		return TYPEC_ACCESSORY_AUDIO;
	default:
		return TYPEC_ACCESSORY_NONE;
	}
}

static enum usb_role husb320_state_usb_role(struct husb320 *husb,
					    enum husb320_state state)
{
	if (!husb->has_data)
		return USB_ROLE_NONE;

	if ((state == HUSB320_STATE_SOURCE ||
	     state == HUSB320_STATE_DEBUG_SOURCE) &&
	    husb->cap.data != TYPEC_PORT_UFP)
		return USB_ROLE_HOST;

	if ((state == HUSB320_STATE_SINK ||
	     state == HUSB320_STATE_DEBUG_SINK) &&
	    husb->cap.data != TYPEC_PORT_DFP)
		return USB_ROLE_DEVICE;

	return USB_ROLE_NONE;
}

static int husb320_state_mode(enum husb320_state state)
{
	switch (state) {
	case HUSB320_STATE_DEBUG_SOURCE:
	case HUSB320_STATE_DEBUG_SINK:
		return TYPEC_MODE_DEBUG;
	case HUSB320_STATE_AUDIO:
		return TYPEC_MODE_AUDIO;
	case HUSB320_STATE_SOURCE:
	case HUSB320_STATE_SINK:
		return TYPEC_STATE_USB;
	case HUSB320_STATE_UNATTACHED:
	default:
		return TYPEC_STATE_SAFE;
	}
}

static int husb320_apply_state(struct husb320 *husb,
			       enum husb320_state state,
			       enum typec_orientation orientation,
			       unsigned int status)
{
	enum typec_accessory accessory = husb320_state_accessory(state);
	enum usb_role usb_role = husb320_state_usb_role(husb, state);
	enum typec_pwr_opmode opmode;
	enum typec_role power_role;
	int ret;

	if (state == HUSB320_STATE_UNATTACHED && husb->state_valid &&
	    husb->state == HUSB320_STATE_UNATTACHED && !husb->partner &&
	    !husb->vbus_on &&
	    husb->usb_role == USB_ROLE_NONE)
		return 0;

	if (state == HUSB320_STATE_UNATTACHED)
		return husb320_disconnect(husb);

	if (state != husb->state &&
	    (!husb->state_valid ||
	     husb->state != HUSB320_STATE_UNATTACHED)) {
		ret = husb320_disconnect(husb);
		if (ret)
			return ret;
	}

	if (typec_get_orientation(husb->port) != orientation) {
		ret = typec_set_orientation(husb->port, orientation);
		if (ret)
			return ret;
	}

	/* Accessory states do not request the platform VBUS supply. */
	ret = husb320_set_vbus(husb, state == HUSB320_STATE_SOURCE);
	if (ret)
		return ret;

	if (usb_role != husb->usb_role) {
		ret = usb_role_switch_set_role(husb->role_sw, usb_role);
		if (ret)
			return ret;
		husb->usb_role = usb_role;
	}

	ret = husb320_set_mode(husb, husb320_state_mode(state));
	if (ret)
		return ret;

	power_role = husb320_state_power_role(state);
	opmode = state == HUSB320_STATE_SINK ?
		husb320_sink_opmode(status) :
		(power_role == TYPEC_SOURCE ? husb->source_opmode :
		 TYPEC_PWR_MODE_USB);

	if (usb_role == USB_ROLE_HOST)
		typec_set_data_role(husb->port, TYPEC_HOST);
	else if (usb_role == USB_ROLE_DEVICE)
		typec_set_data_role(husb->port, TYPEC_DEVICE);
	typec_set_pwr_role(husb->port, power_role);
	typec_set_pwr_opmode(husb->port, opmode);

	ret = husb320_register_partner(husb, accessory);
	if (ret) {
		husb->state_valid = false;
		dev_err_ratelimited(husb->dev,
				    "failed to register partner: %d\n", ret);
		return ret;
	}

	husb->state = state;
	husb->state_valid = true;

	return 0;
}

static enum typec_orientation husb320_get_orientation(unsigned int status)
{
	switch (FIELD_GET(HUSB320_STATUS_ORIENTATION, status)) {
	case HUSB320_STATUS_ORIENTATION_CC1:
		return TYPEC_ORIENTATION_NORMAL;
	case HUSB320_STATUS_ORIENTATION_CC2:
		return TYPEC_ORIENTATION_REVERSE;
	default:
		return TYPEC_ORIENTATION_NONE;
	}
}

static enum husb320_state husb320_get_state(unsigned int status,
					    unsigned int type)
{
	if (!(status & HUSB320_STATUS_ATTACHED))
		return HUSB320_STATE_UNATTACHED;

	if (type & HUSB320_TYPE_DEBUG_SOURCE)
		return HUSB320_STATE_DEBUG_SOURCE;
	if (type & HUSB320_TYPE_DEBUG_SINK)
		return HUSB320_STATE_DEBUG_SINK;
	if (type & HUSB320_TYPE_SINK)
		return HUSB320_STATE_SINK;
	if (type & HUSB320_TYPE_SOURCE)
		return HUSB320_STATE_SOURCE;
	if (type & (HUSB320_TYPE_AUDIO_VBUS | HUSB320_TYPE_AUDIO))
		return HUSB320_STATE_AUDIO;

	return HUSB320_STATE_UNATTACHED;
}

static int husb320_update_state(struct husb320 *husb)
{
	enum typec_orientation orientation;
	enum husb320_state state;
	unsigned int status;
	unsigned int type;
	int ret;

	ret = regmap_read(husb->regmap, HUSB320_REG_STATUS, &status);
	if (ret)
		return ret;

	ret = regmap_read(husb->regmap, HUSB320_REG_TYPE, &type);
	if (ret)
		return ret;

	state = husb320_get_state(status, type);
	orientation = state == HUSB320_STATE_UNATTACHED ?
		TYPEC_ORIENTATION_NONE : husb320_get_orientation(status);

	ret = husb320_apply_state(husb, state, orientation, status);
	if (!ret)
		dev_dbg(husb->dev, "status=%#x type=%#x state=%u\n",
			status, type, state);

	return ret;
}

static irqreturn_t husb320_irq_thread(int irq, void *data)
{
	struct husb320 *husb = data;
	unsigned int interrupt;
	unsigned int interrupt1;
	int disable_ret;
	int ret;

	mutex_lock(&husb->lock);
	if (husb->shutting_down) {
		disable_irq_nosync(irq);
		mutex_unlock(&husb->lock);
		return IRQ_HANDLED;
	}

	ret = regmap_read(husb->regmap, HUSB320_REG_INTERRUPT, &interrupt);
	if (ret)
		goto err;

	ret = regmap_read(husb->regmap, HUSB320_REG_INTERRUPT1, &interrupt1);
	if (ret)
		goto err;

	interrupt &= HUSB320_INT_VALID;
	interrupt1 &= HUSB320_INT1_VALID;
	if (!interrupt && !interrupt1) {
		mutex_unlock(&husb->lock);
		return IRQ_NONE;
	}

	if (interrupt) {
		ret = regmap_write(husb->regmap, HUSB320_REG_INTERRUPT,
				   interrupt);
		if (ret)
			goto err;
	}

	if (interrupt1) {
		ret = regmap_write(husb->regmap, HUSB320_REG_INTERRUPT1,
				   interrupt1);
		if (ret)
			goto err;
	}

	if (interrupt & HUSB320_INT_DETACH) {
		ret = husb320_disconnect(husb);
		if (ret)
			dev_err_ratelimited(husb->dev,
					    "failed to disconnect port: %d\n",
					    ret);
	}

	ret = husb320_update_state(husb);
	if (ret) {
		dev_err_ratelimited(husb->dev,
				    "failed to update port state: %d\n", ret);
		husb320_error_recovery(husb);
	}

	mutex_unlock(&husb->lock);

	return IRQ_HANDLED;

err:
	dev_err_ratelimited(husb->dev, "failed to service interrupt: %d\n",
			    ret);
	husb->shutting_down = true;
	husb320_error_recovery(husb);
	disable_ret = husb320_hw_disable(husb);
	if (disable_ret)
		dev_err_ratelimited(husb->dev,
				    "failed to disable controller: %d\n",
				    disable_ret);
	disable_irq_nosync(irq);
	mutex_unlock(&husb->lock);

	return IRQ_HANDLED;
}

static unsigned int husb320_port_role(enum typec_port_type type)
{
	switch (type) {
	case TYPEC_PORT_SRC:
		return HUSB320_PORT_ROLE_SOURCE;
	case TYPEC_PORT_SNK:
		return HUSB320_PORT_ROLE_SINK;
	case TYPEC_PORT_DRP:
	default:
		return HUSB320_PORT_ROLE_DRP;
	}
}

static unsigned int husb320_try_role(int role)
{
	switch (role) {
	case TYPEC_SINK:
		return HUSB320_TRY_SINK;
	case TYPEC_SOURCE:
		return HUSB320_TRY_SOURCE;
	case TYPEC_NO_PREFERRED_ROLE:
	default:
		return HUSB320_TRY_NONE;
	}
}

static int husb320_port_type_set(struct typec_port *port,
				 enum typec_port_type type)
{
	struct husb320 *husb = typec_get_drvdata(port);
	unsigned int port_role;
	int ret;

	mutex_lock(&husb->lock);
	if (husb->shutting_down) {
		ret = -ESHUTDOWN;
		goto out_unlock;
	}

	port_role = husb320_port_role(type);
	if (type == TYPEC_PORT_DRP)
		port_role |= FIELD_PREP(HUSB320_PORT_ROLE_TRY,
					 husb320_try_role(husb->preferred_role));

	ret = husb320_disconnect(husb);
	if (ret) {
		husb320_error_recovery(husb);
		goto out_unlock;
	}

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_PORT_ROLE,
				 HUSB320_PORT_ROLE_TRY |
				 HUSB320_PORT_ROLE_MODE,
				 port_role);
	if (ret) {
		husb320_error_recovery(husb);
		goto out_unlock;
	}

	husb->port_type = type;
	husb320_set_unattached_roles(husb);
out_unlock:
	mutex_unlock(&husb->lock);

	return ret;
}

static int husb320_try_role_set(struct typec_port *port, int role)
{
	struct husb320 *husb = typec_get_drvdata(port);
	int ret;

	mutex_lock(&husb->lock);
	if (husb->shutting_down) {
		ret = -ESHUTDOWN;
		goto out_unlock;
	}

	if (husb->port_type == TYPEC_PORT_DRP)
		ret = regmap_update_bits(husb->regmap, HUSB320_REG_PORT_ROLE,
					 HUSB320_PORT_ROLE_TRY,
					 FIELD_PREP(HUSB320_PORT_ROLE_TRY,
						    husb320_try_role(role)));
	else
		ret = 0;
	if (!ret)
		husb->preferred_role = role;
out_unlock:
	mutex_unlock(&husb->lock);

	return ret;
}

static const struct typec_operations husb320_typec_ops = {
	.port_type_set = husb320_port_type_set,
	.try_role = husb320_try_role_set,
};

static unsigned int husb320_host_current(enum typec_pwr_opmode opmode)
{
	switch (opmode) {
	case TYPEC_PWR_MODE_1_5A:
		return HUSB320_HOST_CURRENT_1_5A;
	case TYPEC_PWR_MODE_3_0A:
		return HUSB320_HOST_CURRENT_3_0A;
	case TYPEC_PWR_MODE_USB:
	default:
		return HUSB320_HOST_CURRENT_DEFAULT;
	}
}

static int husb320_hw_init(struct husb320 *husb)
{
	unsigned int port_role;
	unsigned int control;
	int ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_RESET,
				 HUSB320_RESET_SW, HUSB320_RESET_SW);
	if (ret)
		return ret;

	/* Wait for stable status and I2C access after the soft reset. */
	msleep(100);

	control = HUSB320_CONTROL_INT_MASK |
		  FIELD_PREP(HUSB320_CONTROL_HOST_CURRENT,
			     husb320_host_current(husb->source_opmode));
	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK |
				 HUSB320_CONTROL_HOST_CURRENT,
				 control);
	if (ret)
		return ret;

	port_role = husb320_port_role(husb->port_type);
	if (husb->port_type == TYPEC_PORT_DRP)
		port_role |= FIELD_PREP(HUSB320_PORT_ROLE_TRY,
					 husb320_try_role(husb->preferred_role));
	ret = regmap_update_bits(husb->regmap, HUSB320_REG_PORT_ROLE,
				 HUSB320_PORT_ROLE_TRY |
				 HUSB320_PORT_ROLE_MODE,
				 port_role);
	if (ret)
		return ret;

	ret = regmap_write(husb->regmap, HUSB320_REG_MASK,
			   HUSB320_MASK_FAULT | HUSB320_MASK_AUTOSINK);
	if (ret)
		return ret;

	ret = regmap_write(husb->regmap, HUSB320_REG_MASK1,
			   HUSB320_MASK1_FORCE);
	if (ret)
		return ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL1,
				 HUSB320_CONTROL1_ENABLE,
				 HUSB320_CONTROL1_ENABLE);
	if (ret)
		return ret;

	ret = regmap_write(husb->regmap, HUSB320_REG_INTERRUPT,
			   HUSB320_INT_VALID);
	if (ret)
		return ret;

	return regmap_write(husb->regmap, HUSB320_REG_INTERRUPT1,
			    HUSB320_INT1_VALID);
}

static int husb320_hw_disable(struct husb320 *husb)
{
	int err = 0;
	int ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK,
				 HUSB320_CONTROL_INT_MASK);
	if (ret)
		err = ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL1,
				 HUSB320_CONTROL1_ENABLE, 0);
	if (ret && !err)
		err = ret;

	return err;
}

static int husb320_set_sink_mode(struct husb320 *husb)
{
	int ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK,
				 HUSB320_CONTROL_INT_MASK);
	if (ret)
		return ret;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_PORT_ROLE,
				 HUSB320_PORT_ROLE_TRY |
				 HUSB320_PORT_ROLE_MODE,
				 HUSB320_PORT_ROLE_SINK);
	if (ret)
		return ret;

	return regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL1,
				  HUSB320_CONTROL1_ENABLE,
				  HUSB320_CONTROL1_ENABLE);
}

static int husb320_parse_connector(struct husb320 *husb)
{
	const char *opmode;
	int ret;

	husb->connector = device_get_named_child_node(husb->dev, "connector");
	if (!husb->connector)
		return -ENODEV;

	/* The connector is parsed as a fwnode and is not populated as a device. */
	fw_devlink_purge_absent_suppliers(husb->connector);

	ret = typec_get_fw_cap(&husb->cap, husb->connector);
	if (ret)
		return ret;

	ret = fwnode_property_read_string(husb->connector,
					  "typec-power-opmode", &opmode);
	if (ret)
		return ret;

	ret = typec_find_pwr_opmode(opmode);
	if (ret < 0)
		return ret;
	if (ret == TYPEC_PWR_MODE_PD)
		return -EINVAL;

	husb->source_opmode = ret;
	husb->has_data = fwnode_property_present(husb->connector, "data-role");
	if (husb->has_data &&
	    ((husb->cap.type == TYPEC_PORT_SRC &&
	      husb->cap.data != TYPEC_PORT_DFP) ||
	     (husb->cap.type == TYPEC_PORT_SNK &&
	      husb->cap.data != TYPEC_PORT_UFP) ||
	     (husb->cap.type == TYPEC_PORT_DRP &&
	      husb->cap.data != TYPEC_PORT_DRD))) {
		return dev_err_probe(husb->dev, -EINVAL,
				     "power and data roles do not match\n");
	} else if (!husb->has_data) {
		if (husb->cap.type == TYPEC_PORT_SNK)
			husb->cap.data = TYPEC_PORT_UFP;
		else if (husb->cap.type == TYPEC_PORT_DRP)
			husb->cap.data = TYPEC_PORT_DRD;
	}

	husb->cap.revision = USB_TYPEC_REV_2_0;
	husb->cap.accessory[0] = TYPEC_ACCESSORY_AUDIO;
	husb->cap.accessory[1] = TYPEC_ACCESSORY_DEBUG;
	husb->cap.orientation_aware = true;
	husb->cap.driver_data = husb;
	husb->cap.ops = &husb320_typec_ops;
	husb->port_type = husb->cap.type;
	husb->preferred_role = husb->cap.prefer_role;

	return 0;
}

static int husb320_get_role_switch(struct husb320 *husb)
{
	int ret;

	if (!husb->has_data)
		return 0;

	husb->role_sw = fwnode_usb_role_switch_get(husb->connector);
	if (IS_ERR(husb->role_sw)) {
		ret = PTR_ERR(husb->role_sw);
		husb->role_sw = NULL;
		if (ret == -ENODEV && husb->cap.data != TYPEC_PORT_DRD)
			return 0;

		return dev_err_probe(husb->dev, ret,
				     "failed to get USB role switch\n");
	}

	if (!husb->role_sw && husb->cap.data == TYPEC_PORT_DRD)
		return dev_err_probe(husb->dev, -ENODEV,
				     "USB data role has no role switch\n");

	return 0;
}

static int husb320_get_vbus(struct husb320 *husb)
{
	struct device_node *node = to_of_node(husb->connector);

	if (node)
		husb->vbus = devm_regulator_get_optional(husb->dev, "vbus");
	else
		husb->vbus = devm_regulator_get_optional(husb->dev, "vbus");

	if (IS_ERR(husb->vbus)) {
		int ret = PTR_ERR(husb->vbus);

		husb->vbus = NULL;
		if (ret != -ENODEV)
			return dev_err_probe(husb->dev, ret,
					     "failed to get VBUS supply\n");
	}

	if (husb->cap.type != TYPEC_PORT_SNK && !husb->vbus)
		return dev_err_probe(husb->dev, -ENODEV,
				     "source-capable port requires VBUS supply\n");

	return 0;
}

static void husb320_disable(void *data)
{
	struct husb320 *husb = data;

	gpiod_set_value_cansleep(husb->enable_gpio, 0);
}

static int husb320_power_on(struct husb320 *husb)
{
	bool needs_delay = false;
	int ret;

	ret = devm_regulator_get_enable_optional(husb->dev, "vdd");
	if (ret == -ENODEV) {
		ret = 0;
	} else if (ret) {
		return dev_err_probe(husb->dev, ret,
				     "failed to enable VDD supply\n");
	} else {
		needs_delay = true;
	}

	husb->enable_gpio = devm_gpiod_get_optional(husb->dev, "enable",
						    GPIOD_OUT_HIGH);
	if (IS_ERR(husb->enable_gpio))
		return dev_err_probe(husb->dev, PTR_ERR(husb->enable_gpio),
				     "failed to enable controller\n");

	if (husb->enable_gpio) {
		ret = devm_add_action_or_reset(husb->dev, husb320_disable, husb);
		if (ret)
			return ret;
		needs_delay = true;
	}

	/* Wait for the controller to become I2C-accessible after power-on. */
	if (needs_delay)
		msleep(100);

	return 0;
}

static int husb320_check_device(struct husb320 *husb)
{
	unsigned int device_id;
	unsigned int device_type;
	int ret;

	ret = regmap_read(husb->regmap, HUSB320_REG_DEVICE_ID, &device_id);
	if (ret)
		return dev_err_probe(husb->dev, ret,
				     "failed to read device ID\n");

	ret = regmap_read(husb->regmap, HUSB320_REG_DEVICE_TYPE, &device_type);
	if (ret)
		return dev_err_probe(husb->dev, ret,
				     "failed to read device type\n");

	if (FIELD_GET(HUSB320_DEVICE_ID_VERSION, device_id) !=
			HUSB320_DEVICE_ID_VERSION_1 ||
	    device_type != HUSB320_DEVICE_TYPE)
		return dev_err_probe(husb->dev, -ENODEV,
				     "unsupported device ID %#x type %#x\n",
				     device_id, device_type);

	dev_dbg(husb->dev, "version %lu revision %lu\n",
		FIELD_GET(HUSB320_DEVICE_ID_VERSION, device_id),
		FIELD_GET(HUSB320_DEVICE_ID_REVISION, device_id));

	return 0;
}

static int husb320_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct husb320 *husb;
	int ret;

	husb = devm_kzalloc(dev, sizeof(*husb), GFP_KERNEL);
	if (!husb)
		return -ENOMEM;

	husb->dev = dev;
	husb->state = HUSB320_STATE_UNATTACHED;
	husb->usb_role = USB_ROLE_NONE;
	mutex_init(&husb->lock);
	i2c_set_clientdata(client, husb);

	ret = husb320_power_on(husb);
	if (ret)
		return ret;

	husb->regmap = devm_regmap_init_i2c(client, &husb320_regmap_config);
	if (IS_ERR(husb->regmap))
		return dev_err_probe(dev, PTR_ERR(husb->regmap),
				     "failed to initialize regmap\n");

	ret = husb320_check_device(husb);
	if (ret)
		return ret;

	if (client->irq <= 0)
		return dev_err_probe(dev, client->irq ?: -EINVAL,
				     "missing interrupt\n");

	ret = husb320_parse_connector(husb);
	if (ret)
		goto err_put_connector;

	ret = husb320_get_role_switch(husb);
	if (ret)
		goto err_put_connector;

	ret = husb320_get_vbus(husb);
	if (ret)
		goto err_put_role;

	ret = husb320_hw_init(husb);
	if (ret)
		goto err_hw_disable;

	husb->port = typec_register_port(dev, &husb->cap);
	if (IS_ERR(husb->port)) {
		ret = PTR_ERR(husb->port);
		goto err_hw_disable;
	}

	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					husb320_irq_thread, IRQF_ONESHOT,
					dev_name(dev), husb);
	if (ret)
		goto err_unregister_port;

	mutex_lock(&husb->lock);
	ret = husb320_update_state(husb);
	mutex_unlock(&husb->lock);
	if (ret)
		goto err_free_irq;

	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK, 0);
	if (ret)
		goto err_free_irq;

	return 0;

err_free_irq:
	mutex_lock(&husb->lock);
	husb->shutting_down = true;
	mutex_unlock(&husb->lock);
	devm_free_irq(dev, client->irq, husb);
err_unregister_port:
	mutex_lock(&husb->lock);
	husb->shutting_down = true;
	husb320_disconnect(husb);
	mutex_unlock(&husb->lock);
	typec_unregister_port(husb->port);
err_hw_disable:
	husb320_hw_disable(husb);
err_put_role:
	usb_role_switch_put(husb->role_sw);
err_put_connector:
	fwnode_handle_put(husb->connector);

	return ret;
}

static void husb320_remove(struct i2c_client *client)
{
	struct husb320 *husb = i2c_get_clientdata(client);
	int ret;

	mutex_lock(&husb->lock);
	husb->shutting_down = true;
	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK,
				 HUSB320_CONTROL_INT_MASK);
	mutex_unlock(&husb->lock);
	if (ret)
		dev_err(husb->dev, "failed to mask interrupts: %d\n", ret);

	devm_free_irq(husb->dev, client->irq, husb);

	mutex_lock(&husb->lock);
	ret = husb320_disconnect(husb);
	if (ret)
		dev_err(husb->dev, "failed to disconnect port: %d\n", ret);
	ret = husb320_hw_disable(husb);
	if (ret)
		dev_err(husb->dev, "failed to disable controller: %d\n", ret);
	mutex_unlock(&husb->lock);

	typec_unregister_port(husb->port);
	usb_role_switch_put(husb->role_sw);
	fwnode_handle_put(husb->connector);
}

static void husb320_shutdown(struct i2c_client *client)
{
	struct husb320 *husb = i2c_get_clientdata(client);
	int ret;

	mutex_lock(&husb->lock);
	husb->shutting_down = true;
	ret = regmap_update_bits(husb->regmap, HUSB320_REG_CONTROL,
				 HUSB320_CONTROL_INT_MASK,
				 HUSB320_CONTROL_INT_MASK);
	mutex_unlock(&husb->lock);
	if (ret)
		dev_err(husb->dev, "failed to mask interrupts: %d\n", ret);

	disable_irq(client->irq);

	mutex_lock(&husb->lock);
	ret = husb320_disconnect(husb);
	if (ret) {
		dev_err(husb->dev, "failed to disconnect port: %d\n", ret);
	} else if (husb->cap.type != TYPEC_PORT_SRC) {
		ret = husb320_set_sink_mode(husb);
		if (!ret)
			goto out_unlock;

		dev_err(husb->dev, "failed to configure shutdown mode: %d\n", ret);
	}

	ret = husb320_hw_disable(husb);
	if (ret)
		dev_err(husb->dev, "failed to disable controller: %d\n", ret);

out_unlock:
	mutex_unlock(&husb->lock);
}

static const struct of_device_id husb320_of_match[] = {
	{ .compatible = "hynetek,husb320" },
	{ }
};
MODULE_DEVICE_TABLE(of, husb320_of_match);

static struct i2c_driver husb320_driver = {
	.driver = {
		.name = "husb320",
		.of_match_table = husb320_of_match,
	},
	.probe_new = husb320_probe,
	.remove = husb320_remove,
	.shutdown = husb320_shutdown,
};
module_i2c_driver(husb320_driver);

MODULE_AUTHOR("Hongyang Zhao <hongyang.zhao@....com>");
MODULE_DESCRIPTION("Hynetek HUSB320 USB Type-C controller driver");
MODULE_LICENSE("GPL");
