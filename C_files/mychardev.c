// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/jiffies.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>

#define DEVICE_NAME "mychardev"

static int major;
static struct class *my_class;
static struct device *my_device;

/* Uninterruptible sleep duration for each read, in microseconds. */
static unsigned int sleep_us = 2000;
module_param(sleep_us, uint, 0644);
MODULE_PARM_DESC(sleep_us, "Sleep duration in microseconds (uninterruptible) per read()");

static ssize_t my_read(struct file *filp, char __user *buf,
		       size_t count, loff_t *ppos)
{
	unsigned long timeout = usecs_to_jiffies(sleep_us);
	char value = 'X';

	/* Put the calling task to sleep in TASK_UNINTERRUPTIBLE. */
	set_current_state(TASK_UNINTERRUPTIBLE);
	schedule_timeout(timeout);
	__set_current_state(TASK_RUNNING);

	if (count == 0)
		return 0;

	if (copy_to_user(buf, &value, 1))
		return -EFAULT;

	return 1;
}

static const struct file_operations fops = {
	.owner = THIS_MODULE,
	.read = my_read,
};

static int __init my_init(void)
{
	int err;

	major = register_chrdev(0, DEVICE_NAME, &fops);
	if (major < 0)
		return major;

	my_class = class_create(DEVICE_NAME);
	if (IS_ERR(my_class)) {
		err = PTR_ERR(my_class);
		unregister_chrdev(major, DEVICE_NAME);
		return err;
	}

	my_device = device_create(my_class, NULL, MKDEV(major, 0), NULL, DEVICE_NAME);
	if (IS_ERR(my_device)) {
		err = PTR_ERR(my_device);
		class_destroy(my_class);
		unregister_chrdev(major, DEVICE_NAME);
		return err;
	}

	return 0;
}

static void __exit my_exit(void)
{
	device_destroy(my_class, MKDEV(major, 0));
	class_destroy(my_class);
	unregister_chrdev(major, DEVICE_NAME);
}

module_init(my_init);
module_exit(my_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Synthetic character device with an uninterruptible delay per read");
