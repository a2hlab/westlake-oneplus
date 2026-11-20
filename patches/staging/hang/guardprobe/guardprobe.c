// SPDX-License-Identifier: GPL-2.0
/*
 * guardprobe.ko addr=PHYS: read one 32-bit word of a physical RAM page through the kernel's linear map, the way the
 * page allocator's users touch memory, and log it. For memory that the kernel was given as RAM but the firmware
 * protects: such a read never completes, the SoC stops and the phone ends in crash-dump mode. The kernel's log, read
 * from RAM afterwards (crashdump.py kmsg on the main branch), then has "reading ..." and no "read completed". That is
 * how 0x89100000 was shown to be protected (kernel 0011, docs/hang-2026-11-19.md).
 *
 * An address the kernel does not map as RAM (not "System RAM" in /proc/iomem, or a no-map reserved region) is
 * refused without a read: on a kernel with the right memory map, a probe of a reserved region says so.
 * The module never stays loaded: after the read its init returns -EAGAIN (insmod reports an error; the result is
 * in the kernel's log).
 */
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/io.h>

static unsigned long addr;
module_param(addr, ulong, 0444);
MODULE_PARM_DESC(addr, "physical address to read, 4-byte aligned");

static int __init guardprobe_init(void)
{
	u32 v;

	if (!addr || (addr & 3)) {
		pr_info("guardprobe: give addr=<physical address>, 4-byte aligned\n");
		return -EINVAL;
	}
	if (!pfn_valid(PHYS_PFN(addr))) {
		pr_info("guardprobe: 0x%lx is not in the kernel's memory map\n", addr);
		return -EINVAL;
	}
	pr_info("guardprobe: reading 0x%lx through the linear map\n", addr);
	v = READ_ONCE(*(u32 *)phys_to_virt(addr));
	pr_info("guardprobe: 0x%lx = 0x%08x (read completed)\n", addr, v);
	return -EAGAIN;
}
module_init(guardprobe_init);
MODULE_DESCRIPTION("Read one word of physical RAM through the linear map: is that memory really usable?");
MODULE_LICENSE("GPL");
