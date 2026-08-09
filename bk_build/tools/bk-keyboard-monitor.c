/* SPDX-License-Identifier: GPL-2.0-only */
/* Keep the nabu keyboard HID interface aligned with the pogo connection. */

typedef unsigned long u64;

#define AT_FDCWD	(-100)
#define O_RDONLY	0
#define O_WRONLY	1
#define O_CLOEXEC	02000000
#define SEEK_SET	0

#define SYS_OPENAT	56
#define SYS_CLOSE	57
#define SYS_GETDENTS64	61
#define SYS_LSEEK	62
#define SYS_READ	63
#define SYS_WRITE	64
#define SYS_PPOLL	73
#define SYS_NANOSLEEP	101

#define POLLPRI	0x0002
#define POLLERR	0x0008

#ifndef CONNECTION_NODE
#define CONNECTION_NODE \
	"/sys/devices/platform/soc/soc:xiaomi_keyboard/xiaomi_keyboard_connected"
#endif
#define HID_DEVICES	"/sys/bus/hid/devices"
#define HID_GENERIC	"/sys/bus/hid/drivers/hid-generic/"
#define HID_BIND	HID_GENERIC "bind"
#define HID_UNBIND	HID_GENERIC "unbind"

struct linux_dirent64 {
	u64 ino;
	long off;
	unsigned short reclen;
	unsigned char type;
	char name[];
};

struct pollfd {
	int fd;
	short events;
	short revents;
};

struct kernel_timespec {
	long sec;
	long nsec;
};

static long syscall6(long nr, long a0, long a1, long a2, long a3,
		     long a4, long a5)
{
	register long x0 __asm__("x0") = a0;
	register long x1 __asm__("x1") = a1;
	register long x2 __asm__("x2") = a2;
	register long x3 __asm__("x3") = a3;
	register long x4 __asm__("x4") = a4;
	register long x5 __asm__("x5") = a5;
	register long x8 __asm__("x8") = nr;

	__asm__ volatile("svc 0"
			 : "+r"(x0)
			 : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5),
			   "r"(x8)
			 : "memory");
	return x0;
}

static long sys_open(const char *path, long flags)
{
	return syscall6(SYS_OPENAT, AT_FDCWD, (long)path, flags, 0, 0, 0);
}

static void sys_close(long fd)
{
	if (fd >= 0)
		syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0);
}

static unsigned long string_length(const char *s)
{
	unsigned long len = 0;

	while (s[len])
		len++;
	return len;
}

static int append_string(char *dst, int pos, int size, const char *src)
{
	while (*src && pos < size - 1)
		dst[pos++] = *src++;
	dst[pos] = '\0';
	return pos;
}

static int contains(const char *buf, long len, const char *needle)
{
	unsigned long needle_len = string_length(needle);
	long i;
	unsigned long j;

	if (needle_len == 0 || len < (long)needle_len)
		return 0;
	for (i = 0; i <= len - (long)needle_len; i++) {
		for (j = 0; j < needle_len && buf[i + j] == needle[j]; j++)
			;
		if (j == needle_len)
			return 1;
	}
	return 0;
}

static long read_file(const char *path, char *buf, unsigned long size)
{
	long fd;
	long count;

	fd = sys_open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return fd;
	count = syscall6(SYS_READ, fd, (long)buf, size, 0, 0, 0);
	sys_close(fd);
	return count;
}

static int write_driver(const char *path, const char *device)
{
	char value[64];
	long fd;
	long written;
	int len = 0;

	len = append_string(value, len, sizeof(value), device);
	if (len >= (int)sizeof(value) - 1)
		return -1;
	value[len++] = '\n';
	value[len] = '\0';

	fd = sys_open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	written = syscall6(SYS_WRITE, fd, (long)value, len, 0, 0, 0);
	sys_close(fd);
	return written == len ? 0 : -1;
}

static int keyboard_interface(const char *device)
{
	static const char id[] = "HID_ID=0003:00003206:00003FFC\n";
	char path[160];
	char uevent[640];
	long count;
	int pos = 0;

	pos = append_string(path, pos, sizeof(path), HID_DEVICES "/");
	pos = append_string(path, pos, sizeof(path), device);
	append_string(path, pos, sizeof(path), "/uevent");
	count = read_file(path, uevent, sizeof(uevent));
	if (count <= 0)
		return 0;
	return contains(uevent, count, id) &&
	       contains(uevent, count, "HID_PHYS=") &&
	       contains(uevent, count, "/input0\n");
}

static void set_keyboard_bound(const char *device, int connected)
{
	char bound_path[160];
	long fd;
	int pos = 0;
	int bound;

	pos = append_string(bound_path, pos, sizeof(bound_path), HID_GENERIC);
	append_string(bound_path, pos, sizeof(bound_path), device);
	fd = sys_open(bound_path, O_RDONLY | O_CLOEXEC);
	bound = fd >= 0;
	sys_close(fd);

	if (connected && !bound)
		write_driver(HID_BIND, device);
	else if (!connected && bound)
		write_driver(HID_UNBIND, device);
}

static void apply_connection(int connected)
{
	char entries[2048];
	long dirfd;
	long count;
	long pos;

	dirfd = sys_open(HID_DEVICES, O_RDONLY | O_CLOEXEC);
	if (dirfd < 0)
		return;

	for (;;) {
		count = syscall6(SYS_GETDENTS64, dirfd, (long)entries,
				 sizeof(entries), 0, 0, 0);
		if (count <= 0)
			break;
		for (pos = 0; pos < count;) {
			struct linux_dirent64 *entry =
				(struct linux_dirent64 *)(entries + pos);

			if (entry->reclen == 0)
				break;
			if (entry->name[0] != '.' && keyboard_interface(entry->name))
				set_keyboard_bound(entry->name, connected);
			pos += entry->reclen;
		}
	}
	sys_close(dirfd);
}

static int read_connection(long fd)
{
	char value[4];
	long count;

	syscall6(SYS_LSEEK, fd, 0, SEEK_SET, 0, 0, 0);
	count = syscall6(SYS_READ, fd, (long)value, sizeof(value), 0, 0, 0);
	return count > 0 && value[0] == '1';
}

static void wait_one_second(void)
{
	struct kernel_timespec delay = { 1, 0 };

	syscall6(SYS_NANOSLEEP, (long)&delay, 0, 0, 0, 0, 0);
}

__attribute__((noreturn)) void _start(void)
{
	struct kernel_timespec timeout;
	struct pollfd pollfd;
	long fd;
	long result;
	int connected;

	for (;;) {
		fd = sys_open(CONNECTION_NODE, O_RDONLY | O_CLOEXEC);
		if (fd < 0) {
			wait_one_second();
			continue;
		}

		connected = read_connection(fd);
		apply_connection(connected);
		for (;;) {
			pollfd.fd = fd;
			pollfd.events = POLLPRI | POLLERR;
			pollfd.revents = 0;
			timeout.sec = 5;
			timeout.nsec = 0;
			result = syscall6(SYS_PPOLL, (long)&pollfd, 1,
					  (long)&timeout, 0, 0, 0);
			if (result < 0)
				break;
			connected = read_connection(fd);
			apply_connection(connected);
		}
		sys_close(fd);
	}
}
