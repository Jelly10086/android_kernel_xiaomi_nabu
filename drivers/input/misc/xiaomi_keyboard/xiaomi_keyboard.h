#ifndef __XIAOMI_KEYBOARD_H
#define __XIAOMI_KEYBOARD_H

#include <linux/regulator/consumer.h>
#include <linux/delay.h>
#include <linux/of.h>
#include <linux/uaccess.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>

#define XIAOMI_KB_TAG "xiaomi-keyboard"
#define MI_KB_INFO(fmt, args...)    pr_info("[%s] %s %d: " fmt, XIAOMI_KB_TAG, __func__, __LINE__, ##args)
#define MI_KB_ERR(fmt, args...)    pr_err("[%s] %s %d: " fmt, XIAOMI_KB_TAG, __func__, __LINE__, ##args)

struct xiaomi_keyboard_platdata {
	int rst_gpio;
	enum of_gpio_flags rst_flags;
	int in_irq_gpio;
	enum of_gpio_flags in_irq_flags;
	int vdd_gpio;
	bool default_enabled;
};

struct xiaomi_keyboard_data {
	struct notifier_block drm_notif;
	struct xiaomi_keyboard_platdata *pdata;
	bool dev_pm_suspend;
	int irq;
	struct platform_device *pdev;
	struct pinctrl *pinctrl;
	struct pinctrl_state *pins_active;
	struct pinctrl_state *pins_suspend;
	struct workqueue_struct *event_wq;
	struct work_struct resume_work;
	struct work_struct suspend_work;
	struct delayed_work connection_work;
	unsigned int connection_events;
	int keyboard_conn_status;
	struct mutex rw_mutex;
	struct mutex state_lock;

	struct mutex power_supply_lock;
	struct work_struct power_supply_work;
	struct notifier_block power_supply_notifier;
	int is_usb_exist;
	bool keyboard_is_enable;
	bool keyboard_is_connected;
	bool irq_requested;
	bool irq_wake_enabled;
	bool power_supply_notifier_registered;
	bool drm_notifier_registered;
	bool is_in_suspend;
};
#endif
