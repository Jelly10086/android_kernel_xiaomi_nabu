/* Copyright (c) 2011-2014 PLUMgrid, http://plumgrid.com
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of version 2 of the GNU General Public
 * License as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details.
 */
#include <linux/bpf.h>
#include <linux/rcupdate.h>
#include <linux/random.h>
#include <linux/smp.h>
#include <linux/topology.h>
#include <linux/ktime.h>
#include <linux/sched.h>
#include <linux/uidgid.h>
#include <linux/filter.h>
#include <linux/ctype.h>
#include <linux/uaccess.h>

#include "../../lib/kstrtox.h"

/* If kernel subsystem is allowing eBPF programs to call this function,
 * inside its own verifier_ops->get_func_proto() callback it should return
 * bpf_map_lookup_elem_proto, so that verifier can properly check the arguments
 *
 * Different map implementations will rely on rcu in map methods
 * lookup/update/delete, therefore eBPF programs must run under rcu lock
 * if program is allowed to access maps, so check rcu_read_lock_held in
 * all three functions.
 */
BPF_CALL_2(bpf_map_lookup_elem, struct bpf_map *, map, void *, key)
{
	WARN_ON_ONCE(!rcu_read_lock_held());
	return (unsigned long) map->ops->map_lookup_elem(map, key);
}

const struct bpf_func_proto bpf_map_lookup_elem_proto = {
	.func		= bpf_map_lookup_elem,
	.gpl_only	= false,
	.pkt_access	= true,
	.ret_type	= RET_PTR_TO_MAP_VALUE_OR_NULL,
	.arg1_type	= ARG_CONST_MAP_PTR,
	.arg2_type	= ARG_PTR_TO_MAP_KEY,
};

BPF_CALL_4(bpf_map_update_elem, struct bpf_map *, map, void *, key,
	   void *, value, u64, flags)
{
	WARN_ON_ONCE(!rcu_read_lock_held());
	return map->ops->map_update_elem(map, key, value, flags);
}

const struct bpf_func_proto bpf_map_update_elem_proto = {
	.func		= bpf_map_update_elem,
	.gpl_only	= false,
	.pkt_access	= true,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_CONST_MAP_PTR,
	.arg2_type	= ARG_PTR_TO_MAP_KEY,
	.arg3_type	= ARG_PTR_TO_MAP_VALUE,
	.arg4_type	= ARG_ANYTHING,
};

BPF_CALL_2(bpf_map_delete_elem, struct bpf_map *, map, void *, key)
{
	WARN_ON_ONCE(!rcu_read_lock_held());
	return map->ops->map_delete_elem(map, key);
}

const struct bpf_func_proto bpf_map_delete_elem_proto = {
	.func		= bpf_map_delete_elem,
	.gpl_only	= false,
	.pkt_access	= true,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_CONST_MAP_PTR,
	.arg2_type	= ARG_PTR_TO_MAP_KEY,
};

const struct bpf_func_proto bpf_get_prandom_u32_proto = {
	.func		= bpf_user_rnd_u32,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_get_smp_processor_id)
{
	return smp_processor_id();
}

const struct bpf_func_proto bpf_get_smp_processor_id_proto = {
	.func		= bpf_get_smp_processor_id,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_get_numa_node_id)
{
	return numa_node_id();
}

const struct bpf_func_proto bpf_get_numa_node_id_proto = {
	.func		= bpf_get_numa_node_id,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_ktime_get_ns)
{
	/* NMI safe access to clock monotonic */
	return ktime_get_mono_fast_ns();
}

const struct bpf_func_proto bpf_ktime_get_ns_proto = {
	.func		= bpf_ktime_get_ns,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_ktime_get_boot_ns)
{
	/* NMI safe access to clock boottime */
	return ktime_get_boot_fast_ns();
}

const struct bpf_func_proto bpf_ktime_get_boot_ns_proto = {
	.func		= bpf_ktime_get_boot_ns,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_get_current_pid_tgid)
{
	struct task_struct *task = current;

	if (unlikely(!task))
		return -EINVAL;

	return (u64) task->tgid << 32 | task->pid;
}

const struct bpf_func_proto bpf_get_current_pid_tgid_proto = {
	.func		= bpf_get_current_pid_tgid,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_0(bpf_get_current_uid_gid)
{
	struct task_struct *task = current;
	kuid_t uid;
	kgid_t gid;

	if (unlikely(!task))
		return -EINVAL;

	current_uid_gid(&uid, &gid);
	return (u64) from_kgid(&init_user_ns, gid) << 32 |
		     from_kuid(&init_user_ns, uid);
}

const struct bpf_func_proto bpf_get_current_uid_gid_proto = {
	.func		= bpf_get_current_uid_gid,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
};

BPF_CALL_2(bpf_get_current_comm, char *, buf, u32, size)
{
	struct task_struct *task = current;

	if (unlikely(!task))
		goto err_clear;

	strncpy(buf, task->comm, size);

	/* Verifier guarantees that size > 0. For task->comm exceeding
	 * size, guarantee that buf is %NUL-terminated. Unconditionally
	 * done here to save the size test.
	 */
	buf[size - 1] = 0;
	return 0;
err_clear:
	memset(buf, 0, size);
	return -EINVAL;
}

const struct bpf_func_proto bpf_get_current_comm_proto = {
	.func		= bpf_get_current_comm,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_PTR_TO_UNINIT_MEM,
	.arg2_type	= ARG_CONST_SIZE,
};

#define BPF_STRTOX_BASE_MASK 0x1F

static int __bpf_strtoull(const char *buf, size_t buf_len, u64 flags,
			  unsigned long long *res, bool *is_negative)
{
	unsigned int base = flags & BPF_STRTOX_BASE_MASK;
	const char *cur_buf = buf;
	size_t cur_len = buf_len;
	unsigned int consumed;
	size_t val_len;
	char str[64];

	if (!buf || !buf_len || !res || !is_negative)
		return -EINVAL;
	if (base != 0 && base != 8 && base != 10 && base != 16)
		return -EINVAL;
	if (flags & ~BPF_STRTOX_BASE_MASK)
		return -EINVAL;

	while (cur_buf < buf + buf_len && isspace(*cur_buf))
		cur_buf++;

	*is_negative = cur_buf < buf + buf_len && *cur_buf == '-';
	if (*is_negative)
		cur_buf++;

	consumed = cur_buf - buf;
	cur_len -= consumed;
	if (!cur_len)
		return -EINVAL;

	cur_len = min(cur_len, sizeof(str) - 1);
	memcpy(str, cur_buf, cur_len);
	str[cur_len] = '\0';
	cur_buf = str;

	cur_buf = _parse_integer_fixup_radix(cur_buf, &base);
	val_len = _parse_integer(cur_buf, base, res);
	if (val_len & KSTRTOX_OVERFLOW)
		return -ERANGE;
	if (!val_len)
		return -EINVAL;

	cur_buf += val_len;
	consumed += cur_buf - str;
	return consumed;
}

static int __bpf_strtoll(const char *buf, size_t buf_len, u64 flags,
			 long long *res)
{
	unsigned long long value;
	bool is_negative;
	int err;

	err = __bpf_strtoull(buf, buf_len, flags, &value, &is_negative);
	if (err < 0)
		return err;
	if (is_negative) {
		if ((long long)-value > 0)
			return -ERANGE;
		*res = -value;
	} else {
		if ((long long)value < 0)
			return -ERANGE;
		*res = value;
	}
	return err;
}

BPF_CALL_4(bpf_strtol, const char *, buf, size_t, buf_len, u64, flags,
	   long *, res)
{
	long long value;
	int err;

	err = __bpf_strtoll(buf, buf_len, flags, &value);
	if (err < 0)
		return err;
	if (value != (long)value)
		return -ERANGE;
	*res = value;
	return err;
}

const struct bpf_func_proto bpf_strtol_proto = {
	.func		= bpf_strtol,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_PTR_TO_MEM,
	.arg2_type	= ARG_CONST_SIZE,
	.arg3_type	= ARG_ANYTHING,
	.arg4_type	= ARG_PTR_TO_LONG,
};

BPF_CALL_4(bpf_strtoul, const char *, buf, size_t, buf_len, u64, flags,
	   unsigned long *, res)
{
	unsigned long long value;
	bool is_negative;
	int err;

	err = __bpf_strtoull(buf, buf_len, flags, &value, &is_negative);
	if (err < 0)
		return err;
	if (is_negative)
		return -EINVAL;
	if (value != (unsigned long)value)
		return -ERANGE;
	*res = value;
	return err;
}

const struct bpf_func_proto bpf_strtoul_proto = {
	.func		= bpf_strtoul,
	.gpl_only	= false,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_PTR_TO_MEM,
	.arg2_type	= ARG_CONST_SIZE,
	.arg3_type	= ARG_ANYTHING,
	.arg4_type	= ARG_PTR_TO_LONG,
};

#define BPF_CAST_FMT_ARG(arg, args, mod)                         \
	(mod[arg] == BPF_PRINTF_LONG_LONG ||                       \
	 (mod[arg] == BPF_PRINTF_LONG && __BITS_PER_LONG == 64) ? \
	 (u64)args[arg] : (u32)args[arg])

#define MAX_BPF_SNPRINTF_VARARGS	12
#define BPF_SNPRINTF_BUF_LEN	512

struct bpf_snprintf_buf {
	char data[BPF_SNPRINTF_BUF_LEN];
};

static DEFINE_PER_CPU(struct bpf_snprintf_buf, bpf_snprintf_buf);
static DEFINE_PER_CPU(int, bpf_snprintf_buf_used);

static int bpf_snprintf_get_buf(char **buf)
{
	int used;

	if (*buf)
		return 0;

	preempt_disable();
	used = this_cpu_inc_return(bpf_snprintf_buf_used);
	if (WARN_ON_ONCE(used > 1)) {
		this_cpu_dec(bpf_snprintf_buf_used);
		preempt_enable();
		return -EBUSY;
	}
	*buf = this_cpu_ptr(&bpf_snprintf_buf)->data;
	return 0;
}

static void bpf_snprintf_cleanup(void)
{
	if (this_cpu_read(bpf_snprintf_buf_used)) {
		this_cpu_dec(bpf_snprintf_buf_used);
		preempt_enable();
	}
}

static int bpf_snprintf_copy_string(char *dst, const void *unsafe_ptr,
				    char ptr_type, size_t size)
{
	if (ptr_type == 'u')
		return strncpy_from_unsafe_user(dst,
				(__force const void __user *)unsafe_ptr, size);
	return strncpy_from_unsafe_strict(dst, unsafe_ptr, size);
}

int bpf_snprintf_prepare(char *fmt, u32 fmt_size, const u64 *raw_args,
			 u64 *args, enum bpf_printf_mod_type *mod,
			 u32 num_args)
{
	char *unsafe_ptr, *tmp_buf = NULL, *tmp_end = NULL, *fmt_end;
	size_t copy_size, tmp_len = BPF_SNPRINTF_BUF_LEN;
	int err, i, num_spec = 0;
	enum bpf_printf_mod_type cur_mod;
	bool have_buf = false;
	u64 cur_arg;
	char ptr_type;

	if (!!args != !!mod)
		return -EINVAL;

	fmt_end = strnchr(fmt, fmt_size, '\0');
	if (!fmt_end)
		return -EINVAL;
	fmt_size = fmt_end - fmt;
	if (args) {
		err = bpf_snprintf_get_buf(&tmp_buf);
		if (err)
			return err;
		have_buf = true;
		tmp_end = tmp_buf + tmp_len;
	}

	for (i = 0; i < fmt_size; i++) {
		if ((!isprint(fmt[i]) && !isspace(fmt[i])) || !isascii(fmt[i]))
			goto invalid;
		if (fmt[i] != '%')
			continue;
		if (fmt[i + 1] == '%') {
			i++;
			continue;
		}
		if (num_spec >= num_args)
			goto invalid;

		i++;
		while (fmt[i] == '0' || fmt[i] == '+' || fmt[i] == '-' ||
		       fmt[i] == ' ')
			i++;
		if (fmt[i] >= '1' && fmt[i] <= '9') {
			i++;
			while (fmt[i] >= '0' && fmt[i] <= '9')
				i++;
		}

		if (fmt[i] == 'p') {
			cur_mod = BPF_PRINTF_LONG;
			if ((fmt[i + 1] == 'k' || fmt[i + 1] == 'u') &&
			    fmt[i + 2] == 's') {
				ptr_type = fmt[i + 1];
				i += 2;
				goto format_string;
			}
			if (fmt[i + 1] == '\0' || isspace(fmt[i + 1]) ||
			    ispunct(fmt[i + 1]) || fmt[i + 1] == 'K' ||
			    fmt[i + 1] == 'x' || fmt[i + 1] == 'B' ||
			    fmt[i + 1] == 's' || fmt[i + 1] == 'S') {
				if (args)
					cur_arg = raw_args[num_spec];
				goto format_done;
			}
			if ((fmt[i + 1] != 'i' && fmt[i + 1] != 'I') ||
			    (fmt[i + 2] != '4' && fmt[i + 2] != '6'))
				goto invalid;
			i += 2;
			if (!args)
				goto format_done;
			copy_size = fmt[i] == '4' ? 4 : 16;
			if (tmp_end - tmp_buf < copy_size) {
				err = -ENOSPC;
				goto cleanup;
			}
			unsafe_ptr = (char *)(long)raw_args[num_spec];
			err = probe_kernel_read_strict(tmp_buf, unsafe_ptr, copy_size);
			if (err)
				memset(tmp_buf, 0, copy_size);
			cur_arg = (u64)(long)tmp_buf;
			tmp_buf += copy_size;
			goto format_done;
		} else if (fmt[i] == 's') {
			cur_mod = BPF_PRINTF_LONG;
			ptr_type = 'k';
format_string:
			if (fmt[i + 1] != '\0' && !isspace(fmt[i + 1]) &&
			    !ispunct(fmt[i + 1]))
				goto invalid;
			if (!args)
				goto format_done;
			if (tmp_end == tmp_buf) {
				err = -ENOSPC;
				goto cleanup;
			}
			unsafe_ptr = (char *)(long)raw_args[num_spec];
			err = bpf_snprintf_copy_string(tmp_buf, unsafe_ptr,
						       ptr_type, tmp_end - tmp_buf);
			if (err < 0) {
				tmp_buf[0] = '\0';
				err = 1;
			}
			cur_arg = (u64)(long)tmp_buf;
			tmp_buf += err;
			goto format_done;
		}

		cur_mod = BPF_PRINTF_INT;
		if (fmt[i] == 'l') {
			cur_mod = BPF_PRINTF_LONG;
			i++;
		}
		if (fmt[i] == 'l') {
			cur_mod = BPF_PRINTF_LONG_LONG;
			i++;
		}
		if (fmt[i] != 'i' && fmt[i] != 'd' && fmt[i] != 'u' &&
		    fmt[i] != 'x' && fmt[i] != 'X')
			goto invalid;
		if (args)
			cur_arg = raw_args[num_spec];
format_done:
		if (args) {
			args[num_spec] = cur_arg;
			mod[num_spec] = cur_mod;
		}
		num_spec++;
	}

	return 0;

invalid:
	err = -EINVAL;
cleanup:
	if (have_buf)
		bpf_snprintf_cleanup();
	return err;
}

BPF_CALL_5(bpf_snprintf, char *, str, u32, str_size, char *, fmt,
	   const void *, data, u32, data_len)
{
	enum bpf_printf_mod_type mod[MAX_BPF_SNPRINTF_VARARGS] = {};
	u64 args[MAX_BPF_SNPRINTF_VARARGS] = {};
	int err, num_args;

	if (data_len % sizeof(u64) ||
	    data_len > MAX_BPF_SNPRINTF_VARARGS * sizeof(u64) ||
	    (data_len && !data))
		return -EINVAL;
	num_args = data_len / sizeof(u64);

	err = bpf_snprintf_prepare(fmt, UINT_MAX, data, args, mod, num_args);
	if (err)
		return err;

	err = snprintf(str, str_size, fmt,
		BPF_CAST_FMT_ARG(0, args, mod),
		BPF_CAST_FMT_ARG(1, args, mod),
		BPF_CAST_FMT_ARG(2, args, mod),
		BPF_CAST_FMT_ARG(3, args, mod),
		BPF_CAST_FMT_ARG(4, args, mod),
		BPF_CAST_FMT_ARG(5, args, mod),
		BPF_CAST_FMT_ARG(6, args, mod),
		BPF_CAST_FMT_ARG(7, args, mod),
		BPF_CAST_FMT_ARG(8, args, mod),
		BPF_CAST_FMT_ARG(9, args, mod),
		BPF_CAST_FMT_ARG(10, args, mod),
		BPF_CAST_FMT_ARG(11, args, mod));
	bpf_snprintf_cleanup();

	return err + 1;
}

const struct bpf_func_proto bpf_snprintf_proto = {
	.func		= bpf_snprintf,
	.gpl_only	= true,
	.ret_type	= RET_INTEGER,
	.arg1_type	= ARG_PTR_TO_UNINIT_MEM,
	.arg2_type	= ARG_CONST_SIZE_OR_ZERO,
	.arg3_type	= ARG_PTR_TO_CONST_STR,
	.arg4_type	= ARG_PTR_TO_MEM,
	.arg5_type	= ARG_CONST_SIZE_OR_ZERO,
};

#if defined(CONFIG_QUEUED_SPINLOCKS) || defined(CONFIG_BPF_ARCH_SPINLOCK)

static inline void __bpf_spin_lock(struct bpf_spin_lock *lock)
{
	arch_spinlock_t *l = (void *)lock;
	union {
		__u32 val;
		arch_spinlock_t lock;
	} u = { .lock = __ARCH_SPIN_LOCK_UNLOCKED };

	compiletime_assert(u.val == 0, "__ARCH_SPIN_LOCK_UNLOCKED not 0");
	BUILD_BUG_ON(sizeof(*l) != sizeof(__u32));
	BUILD_BUG_ON(sizeof(*lock) != sizeof(__u32));
	arch_spin_lock(l);
}

static inline void __bpf_spin_unlock(struct bpf_spin_lock *lock)
{
	arch_spinlock_t *l = (void *)lock;

	arch_spin_unlock(l);
}

#else

static inline void __bpf_spin_lock(struct bpf_spin_lock *lock)
{
	atomic_t *l = (void *)lock;

	BUILD_BUG_ON(sizeof(*l) != sizeof(*lock));
	do {
		atomic_cond_read_relaxed(l, !VAL);
	} while (atomic_xchg(l, 1));
}

static inline void __bpf_spin_unlock(struct bpf_spin_lock *lock)
{
	atomic_t *l = (void *)lock;

	atomic_set_release(l, 0);
}

#endif

static DEFINE_PER_CPU(unsigned long, bpf_irqsave_flags);

static inline void __bpf_spin_lock_irqsave(struct bpf_spin_lock *lock)
{
	unsigned long flags;

	local_irq_save(flags);
	__bpf_spin_lock(lock);
	__this_cpu_write(bpf_irqsave_flags, flags);
}

static inline void __bpf_spin_unlock_irqrestore(struct bpf_spin_lock *lock)
{
	unsigned long flags;

	flags = __this_cpu_read(bpf_irqsave_flags);
	__bpf_spin_unlock(lock);
	local_irq_restore(flags);
}

void copy_map_value_locked(struct bpf_map *map, void *dst, void *src,
			   bool lock_src)
{
	struct bpf_spin_lock *lock;

	if (lock_src)
		lock = src + map->spin_lock_off;
	else
		lock = dst + map->spin_lock_off;
	preempt_disable();
	__bpf_spin_lock_irqsave(lock);
	copy_map_value(map, dst, src);
	__bpf_spin_unlock_irqrestore(lock);
	preempt_enable();
}
