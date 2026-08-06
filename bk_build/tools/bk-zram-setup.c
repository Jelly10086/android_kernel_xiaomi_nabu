/* SPDX-License-Identifier: GPL-2.0-only */
/* Minimal arm64 helper for Android's /data/per_boot zram backing device. */

typedef unsigned int u32;
typedef unsigned long long u64;

#define AT_FDCWD              (-100)
#define O_WRONLY              1
#define O_RDWR                2
#define O_CREAT               0100
#define O_CLOEXEC             02000000

#define SYS_IOCTL             29
#define SYS_UNLINKAT          35
#define SYS_STATFS            43
#define SYS_FALLOCATE         47
#define SYS_OPENAT            56
#define SYS_CLOSE             57
#define SYS_WRITE             64
#define SYS_EXIT              93

#define LOOP_SET_FD           0x4c00
#define LOOP_CLR_FD           0x4c01
#define LOOP_SET_STATUS64     0x4c04
#define LOOP_SET_DIRECT_IO    0x4c08
#define LOOP_SET_BLOCK_SIZE   0x4c09
#define LOOP_CTL_GET_FREE     0x4c82
#define LO_FLAGS_AUTOCLEAR    4

#ifndef BK_BACKING_PATH
#define BK_BACKING_PATH       "/data/per_boot/zram_swap"
#endif
#ifndef BK_ZRAM_BACKING_PATH
#define BK_ZRAM_BACKING_PATH  "/sys/block/zram0/backing_dev"
#endif
#ifndef BK_ZRAM_LIMIT_PATH
#define BK_ZRAM_LIMIT_PATH    "/sys/block/zram0/writeback_limit"
#endif
#ifndef BK_ZRAM_ENABLE_PATH
#define BK_ZRAM_ENABLE_PATH   "/sys/block/zram0/writeback_limit_enable"
#endif
#ifndef BK_BACKING_SIZE
#define BK_BACKING_SIZE       (1ULL << 30)
#endif

struct loop_info64 {
	u64 lo_device;
	u64 lo_inode;
	u64 lo_rdevice;
	u64 lo_offset;
	u64 lo_sizelimit;
	u32 lo_number;
	u32 lo_encrypt_type;
	u32 lo_encrypt_key_size;
	u32 lo_flags;
	unsigned char lo_file_name[64];
	unsigned char lo_crypt_name[64];
	unsigned char lo_encrypt_key[32];
	u64 lo_init[2];
};

struct kernel_statfs {
	long f_type;
	long f_bsize;
	u64 f_blocks;
	u64 f_bfree;
	u64 f_bavail;
	u64 f_files;
	u64 f_ffree;
	int f_fsid[2];
	long f_namelen;
	long f_frsize;
	long f_flags;
	long f_spare[4];
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

static long sys_open(const char *path, long flags, long mode)
{
	return syscall6(SYS_OPENAT, AT_FDCWD, (long)path, flags, mode, 0, 0);
}

static long sys_ioctl(long fd, long request, long arg)
{
	return syscall6(SYS_IOCTL, fd, request, arg, 0, 0, 0);
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

static int write_value(const char *path, const char *value)
{
	long fd = sys_open(path, O_WRONLY | O_CLOEXEC, 0);
	unsigned long len;
	long written;

	if (fd < 0)
		return -1;
	len = string_length(value);
	written = syscall6(SYS_WRITE, fd, (long)value, len, 0, 0, 0);
	sys_close(fd);
	return written == (long)len ? 0 : -1;
}

static int append_number(char *path, int pos, unsigned int number)
{
	char digits[10];
	int count = 0;

	do {
		digits[count++] = '0' + number % 10;
		number /= 10;
	} while (number && count < (int)sizeof(digits));
	while (count)
		path[pos++] = digits[--count];
	path[pos] = '\0';
	return pos;
}

static void zero_loop_info(struct loop_info64 *info)
{
	unsigned char *p = (unsigned char *)info;
	unsigned long i;

	for (i = 0; i < sizeof(*info); i++)
		p[i] = 0;
}

__attribute__((noreturn)) void _start(void)
{
	static const char backing_path[] = BK_BACKING_PATH;
	static const char loop_control[] = "/dev/loop-control";
	static const char loop_prefix[] = "/dev/block/loop";
	static const char zram_backing[] = BK_ZRAM_BACKING_PATH;
	static const char zram_limit[] = BK_ZRAM_LIMIT_PATH;
	static const char zram_limit_enable[] = BK_ZRAM_ENABLE_PATH;
	char loop_path[32];
	struct loop_info64 info;
	struct kernel_statfs statfs;
	long backing_fd = -1;
	long control_fd = -1;
	long loop_fd = -1;
	long loop_id;
	int pos;
	int attached = 0;
	int zram_installed = 0;
	int result = 10;
	u64 free_bytes;

	if (syscall6(SYS_STATFS, (long)"/data", (long)&statfs,
		     0, 0, 0, 0) < 0) {
		result = 11;
		goto out;
	}
	free_bytes = statfs.f_bavail * (u64)statfs.f_bsize;
	if (free_bytes < BK_BACKING_SIZE + (2ULL << 30)) {
		result = 12;
		goto out;
	}

	backing_fd = sys_open(backing_path,
			      O_RDWR | O_CREAT | O_CLOEXEC, 0600);
	if (backing_fd < 0) {
		result = 13;
		goto out;
	}
	if (syscall6(SYS_FALLOCATE, backing_fd, 0, 0, BK_BACKING_SIZE, 0, 0) < 0) {
		result = 14;
		goto out;
	}

	control_fd = sys_open(loop_control, O_RDWR | O_CLOEXEC, 0);
	if (control_fd < 0) {
		result = 15;
		goto out;
	}
	/* Ask the driver to provision a free loop, then claim an existing node.
	 * Android's ueventd may create the returned /dev node asynchronously, and
	 * apexd can claim it in between.  LOOP_SET_FD is the atomic ownership test.
	 */
	sys_ioctl(control_fd, LOOP_CTL_GET_FREE, 0);
	for (loop_id = 0; loop_id < 256; loop_id++) {
		for (pos = 0; loop_prefix[pos] &&
		     pos < (int)sizeof(loop_path) - 1; pos++)
			loop_path[pos] = loop_prefix[pos];
		append_number(loop_path, pos, (unsigned int)loop_id);

		loop_fd = sys_open(loop_path, O_RDWR | O_CLOEXEC, 0);
		if (loop_fd < 0)
			continue;
		if (sys_ioctl(loop_fd, LOOP_SET_FD, backing_fd) >= 0) {
			attached = 1;
			break;
		}
		sys_close(loop_fd);
		loop_fd = -1;
	}
	if (!attached) {
		result = 17;
		goto out;
	}
	zero_loop_info(&info);
	info.lo_flags = LO_FLAGS_AUTOCLEAR;
	if (sys_ioctl(loop_fd, LOOP_SET_STATUS64, (long)&info) < 0) {
		result = 19;
		goto out;
	}
	if (sys_ioctl(loop_fd, LOOP_SET_BLOCK_SIZE, 4096) < 0) {
		result = 20;
		goto out;
	}
	if (sys_ioctl(loop_fd, LOOP_SET_DIRECT_IO, 1) < 0) {
		result = 21;
		goto out;
	}

	pos = string_length(loop_path);
	loop_path[pos++] = '\n';
	loop_path[pos] = '\0';
	if (write_value(zram_backing, loop_path) < 0) {
		result = 22;
		goto out;
	}
	zram_installed = 1;
	if (write_value(zram_limit, "131072\n") < 0) {
		result = 23;
		goto out;
	}
	if (write_value(zram_limit_enable, "1\n") < 0) {
		result = 24;
		goto out;
	}

	result = 0;
out:
	/* Match fs_mgr and avoid leaving a large file behind on every failure. */
	syscall6(SYS_UNLINKAT, AT_FDCWD, (long)backing_path, 0, 0, 0, 0);
	if (result && attached && !zram_installed)
		sys_ioctl(loop_fd, LOOP_CLR_FD, 0);
	sys_close(loop_fd);
	sys_close(control_fd);
	sys_close(backing_fd);
	syscall6(SYS_EXIT, result, 0, 0, 0, 0, 0);
	for (;;)
		;
}
