// SPDX-License-Identifier: GPL-2.0
/*
 * bk-oops-flash: persist the tail of the kernel printk buffer to the
 * dedicated "oops" flash partition on panic, oops, emergency restart
 * and clean restart.
 *
 * RAM-backed pstore/ramoops loses its content on a full power loss; this
 * dumper mirrors the last 512 KiB of the printk buffer into the 16 MiB
 * "oops" partition (nabu: /dev/block/by-name/oops = sda16) so the last
 * kernel log also survives a cold boot.
 *
 * Two hooks, chosen by when the storage stack is still alive:
 *  - kmsg dumper for PANIC/OOPS/EMERG: devices are up in those paths.
 *    (kernel_restart() fires KMSG_DUMP_RESTART only AFTER
 *    device_shutdown(), i.e. after the UFS controller is gone, so the
 *    RESTART reason is deliberately NOT handled here.)
 *  - reboot notifier (SYS_RESTART): runs at the very start of
 *    sys_reboot/kernel_restart_prepare, before device_shutdown().
 *
 * Everything (payload pages, header page, bio) is allocated once at init.
 * The write path only memcpys into those pages and submits one prebuilt
 * WRITE bio with a bounded, IRQ-state-independent busy-wait, so it is
 * safe to run from panic context: if the completion IRQ cannot be
 * delivered, the bounded poll times out and the autonomous UFS
 * controller still finishes the transfer on its own.
 *
 * The partition is read back from userspace with:
 *   dd if=/dev/block/by-name/oops of=/data/local/tmp/bkop.bin
 * header is the first 512 bytes: magic "BKOP", payload size, crc32.
 */
#define pr_fmt(fmt) "oops-flash: " fmt

#include <linux/module.h>
#include <linux/init.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/kmsg_dump.h>
#include <linux/reboot.h>
#include <linux/crc32.h>
#include <linux/sched/clock.h>
#include <linux/completion.h>
#include <linux/atomic.h>
#include <linux/delay.h>

#define BKOP_MAGIC		0x504f4b42	/* "BKOP" little endian */
#define BKOP_VERSION		1
#define BKOP_PAYLOAD_ORDER	7		/* 128 pages = 512 KiB */
#define BKOP_PAYLOAD_PAGES	(1 << (BKOP_PAYLOAD_ORDER))
#define BKOP_TIMEOUT_NS		3000000000ull	/* 3 s */

struct bkop_header {
	__le32	magic;
	__le32	version;
	__le32	size;
	__le32	crc;
	__le64	seq;
	__le64	tstamp_ns;
	__le32	reason;
	__le32	reserved;
} __packed;

static int part_major = 8;	/* nabu: sda */
static int part_minor = 16;	/* nabu: sda16 = by-name "oops" */

module_param(part_major, int, 0444);
module_param(part_minor, int, 0444);
MODULE_PARM_DESC(part_major, "oops partition block device major (default 8)");
MODULE_PARM_DESC(part_minor, "oops partition block device minor (default 16)");

static int bkops_holder;	/* exclusive-claim cookie */

static struct block_device	*oops_bdev;
static struct page		*payload_page;
static char			*payload;
static struct page		*hdr_page;
static struct bio		*dump_bio;
static struct bvec_iter		saved_iter;
static unsigned int		mapped_pages;
static struct kmsg_dumper	bk_dumper;
static struct notifier_block	bk_reboot_nb;
static atomic_t			dump_running = ATOMIC_INIT(0);
static bool			wrote_this_boot;
static u64			dump_seq;

static void bk_endio(struct bio *bio)
{
	complete(bio->bi_private);
}

static void bk_write_flash(size_t len, int reason)
{
	struct completion comp;
	struct bkop_header *hdr;
	unsigned long long deadline;

	if (!oops_bdev || !dump_bio || len > mapped_pages * PAGE_SIZE)
		return;

	hdr = page_address(hdr_page);
	memset(hdr, 0, sizeof(*hdr));
	hdr->magic = cpu_to_le32(BKOP_MAGIC);
	hdr->version = cpu_to_le32(BKOP_VERSION);
	hdr->size = cpu_to_le32(len);
	hdr->crc = cpu_to_le32(crc32(0, payload, len));
	hdr->seq = cpu_to_le64(++dump_seq);
	hdr->tstamp_ns = cpu_to_le64(local_clock());
	hdr->reason = cpu_to_le32(reason);

	init_completion(&comp);
	dump_bio->bi_iter = saved_iter;
	dump_bio->bi_opf = REQ_OP_WRITE | REQ_SYNC | REQ_PREFLUSH;
	dump_bio->bi_end_io = bk_endio;
	dump_bio->bi_private = &comp;

	submit_bio(dump_bio);

	/*
	 * IRQ-state independent bounded wait: if the completion IRQ can be
	 * delivered it completes early; from panic context with IRQs off it
	 * simply expires after the deadline while the UFS controller keeps
	 * executing the (already queued) transfer autonomously.
	 */
	deadline = local_clock() + BKOP_TIMEOUT_NS;
	while (!completion_done(&comp) && local_clock() < deadline)
		cpu_relax();

	if (completion_done(&comp))
		pr_info("wrote %zu bytes to oops partition (reason %d, seq %llu)\n",
			len, reason, dump_seq);
	else
		pr_info("write still in flight on return (reason %d); UFS completes autonomously\n",
			reason);
}

/* Snapshot the printk tail into the payload buffer; return its length. */
static size_t bk_capture_tail(void)
{
	size_t len = 0;

	kmsg_dump_rewind(&bk_dumper);
	kmsg_dump_get_buffer(&bk_dumper, true, payload,
			     mapped_pages * PAGE_SIZE, &len);
	return len;
}

static void bk_dump(struct kmsg_dumper *dumper, enum kmsg_dump_reason reason)
{
	size_t len;

	if (reason < KMSG_DUMP_PANIC || reason > KMSG_DUMP_EMERG)
		return;
	if (wrote_this_boot)
		return;
	if (atomic_xchg(&dump_running, 1))
		return;

	len = bk_capture_tail();
	if (len) {
		bk_write_flash(len, reason);
		wrote_this_boot = true;
	}

	atomic_set(&dump_running, 0);
}

/*
 * Clean restarts: runs from sys_reboot before device_shutdown(), while
 * the UFS controller is still operational.
 */
static int bk_reboot_notify(struct notifier_block *nb, unsigned long mode,
			    void *cmd)
{
	size_t len;

	if (mode != SYS_RESTART)
		return NOTIFY_DONE;
	if (wrote_this_boot)
		return NOTIFY_DONE;
	if (atomic_xchg(&dump_running, 1))
		return NOTIFY_DONE;

	len = bk_capture_tail();
	if (len) {
		bk_write_flash(len, KMSG_DUMP_RESTART);
		wrote_this_boot = true;
	}

	atomic_set(&dump_running, 0);
	return NOTIFY_DONE;
}

static int __init bk_oops_init(void)
{
	struct page *pp = NULL;
	int i, ret;

	if (part_major <= 0 || part_minor <= 0)
		return 0;

	oops_bdev = blkdev_get_by_dev(MKDEV(part_major, part_minor),
				      FMODE_READ | FMODE_WRITE | FMODE_EXCL,
				      &bkops_holder);
	if (IS_ERR(oops_bdev)) {
		ret = PTR_ERR(oops_bdev);
		oops_bdev = NULL;
		pr_info("partition %d:%d unavailable (%d), disabled\n",
			part_major, part_minor, ret);
		return 0;
	}

	pp = alloc_pages(GFP_KERNEL, BKOP_PAYLOAD_ORDER);
	if (!pp) {
		ret = -ENOMEM;
		goto err_bdev;
	}
	payload = page_address(pp);

	hdr_page = alloc_page(GFP_KERNEL | __GFP_ZERO);
	if (!hdr_page) {
		ret = -ENOMEM;
		goto err_pages;
	}

	dump_bio = bio_alloc(GFP_KERNEL, BKOP_PAYLOAD_PAGES + 1);
	if (!dump_bio) {
		ret = -ENOMEM;
		goto err_hdr;
	}
	bio_set_dev(dump_bio, oops_bdev);

	if (bio_add_page(dump_bio, hdr_page, PAGE_SIZE, 0) != PAGE_SIZE) {
		ret = -EINVAL;
		goto err_bio;
	}
	for (i = 0; i < BKOP_PAYLOAD_PAGES; i++) {
		if (bio_add_page(dump_bio, nth_page(pp, i), PAGE_SIZE, 0) !=
		    PAGE_SIZE)
			break;
		mapped_pages++;
	}
	if (!mapped_pages) {
		ret = -EINVAL;
		goto err_bio;
	}
	saved_iter = dump_bio->bi_iter;

	bk_dumper.dump = bk_dump;
	/* PANIC/OOPS/EMERG only: RESTART arrives after device_shutdown(). */
	bk_dumper.max_reason = KMSG_DUMP_EMERG;
	ret = kmsg_dump_register(&bk_dumper);
	if (ret)
		goto err_bio;

	bk_reboot_nb.notifier_call = bk_reboot_notify;
	register_reboot_notifier(&bk_reboot_nb);

	pr_info("ready: dumping last %u KiB of kmsg to %d:%d on panic/oops/restart\n",
		(mapped_pages * PAGE_SIZE) >> 10, part_major, part_minor);
	return 0;

err_bio:
	bio_put(dump_bio);
	dump_bio = NULL;
err_hdr:
	__free_page(hdr_page);
	hdr_page = NULL;
err_pages:
	__free_pages(pp, BKOP_PAYLOAD_ORDER);
	payload = NULL;
err_bdev:
	blkdev_put(oops_bdev, FMODE_READ | FMODE_WRITE | FMODE_EXCL);
	oops_bdev = NULL;
	pr_err("init failed (%d), disabled\n", ret);
	return 0;
}
late_initcall(bk_oops_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("bk: persist printk tail to the oops flash partition");
