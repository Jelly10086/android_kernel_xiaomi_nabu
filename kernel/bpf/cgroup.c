/*
 * Functions to manage eBPF programs attached to cgroups
 *
 * Copyright (c) 2016 Daniel Mack
 *
 * This file is subject to the terms and conditions of version 2 of the GNU
 * General Public License.  See the file COPYING in the main directory of the
 * Linux distribution for more details.
 */

#include <linux/kernel.h>
#include <linux/atomic.h>
#include <linux/cgroup.h>
#include <linux/filter.h>
#include <linux/slab.h>
#include <linux/sysctl.h>
#include <linux/bpf.h>
#include <linux/bpf-cgroup.h>
#include <net/sock.h>
#include <net/bpf_sk_storage.h>

DEFINE_STATIC_KEY_FALSE(cgroup_bpf_enabled_key);
EXPORT_SYMBOL(cgroup_bpf_enabled_key);

/**
 * cgroup_bpf_put() - put references of all bpf programs
 * @cgrp: the cgroup to modify
 */
void cgroup_bpf_put(struct cgroup *cgrp)
{
	unsigned int type;

	for (type = 0; type < ARRAY_SIZE(cgrp->bpf.progs); type++) {
		struct list_head *progs = &cgrp->bpf.progs[type];
		struct bpf_prog_list *pl, *tmp;

		list_for_each_entry_safe(pl, tmp, progs, node) {
			list_del(&pl->node);
			bpf_prog_put(pl->prog);
			kfree(pl);
			static_branch_dec(&cgroup_bpf_enabled_key);
		}
		bpf_prog_array_free(cgrp->bpf.effective[type]);
	}
}

/* count number of elements in the list.
 * it's slow but the list cannot be long
 */
static u32 prog_list_length(struct list_head *head)
{
	struct bpf_prog_list *pl;
	u32 cnt = 0;

	list_for_each_entry(pl, head, node) {
		if (!pl->prog)
			continue;
		cnt++;
	}
	return cnt;
}

/* if parent has non-overridable prog attached,
 * disallow attaching new programs to the descendent cgroup.
 * if parent has overridable or multi-prog, allow attaching
 */
static bool hierarchy_allows_attach(struct cgroup *cgrp,
				    enum bpf_attach_type type,
				    u32 new_flags)
{
	struct cgroup *p;

	p = cgroup_parent(cgrp);
	if (!p)
		return true;
	do {
		u32 flags = p->bpf.flags[type];
		u32 cnt;

		if (flags & BPF_F_ALLOW_MULTI)
			return true;
		cnt = prog_list_length(&p->bpf.progs[type]);
		WARN_ON_ONCE(cnt > 1);
		if (cnt == 1)
			return !!(flags & BPF_F_ALLOW_OVERRIDE);
		p = cgroup_parent(p);
	} while (p);
	return true;
}

/* compute a chain of effective programs for a given cgroup:
 * start from the list of programs in this cgroup and add
 * all parent programs.
 * Note that parent's F_ALLOW_OVERRIDE-type program is yielding
 * to programs in this cgroup
 */
static int compute_effective_progs(struct cgroup *cgrp,
				   enum bpf_attach_type type,
				   struct bpf_prog_array __rcu **array)
{
	struct bpf_prog_array *progs;
	struct bpf_prog_list *pl;
	struct cgroup *p = cgrp;
	int cnt = 0;

	/* count number of effective programs by walking parents */
	do {
		if (cnt == 0 || (p->bpf.flags[type] & BPF_F_ALLOW_MULTI))
			cnt += prog_list_length(&p->bpf.progs[type]);
		p = cgroup_parent(p);
	} while (p);

	progs = bpf_prog_array_alloc(cnt, GFP_KERNEL);
	if (!progs)
		return -ENOMEM;

	/* populate the array with effective progs */
	cnt = 0;
	p = cgrp;
	do {
		if (cnt == 0 || (p->bpf.flags[type] & BPF_F_ALLOW_MULTI))
			list_for_each_entry(pl,
					    &p->bpf.progs[type], node) {
				if (!pl->prog)
					continue;
				progs->progs[cnt++] = pl->prog;
			}
		p = cgroup_parent(p);
	} while (p);

	rcu_assign_pointer(*array, progs);
	return 0;
}

static void activate_effective_progs(struct cgroup *cgrp,
				     enum bpf_attach_type type,
				     struct bpf_prog_array __rcu *array)
{
	struct bpf_prog_array __rcu *old_array;

	old_array = xchg(&cgrp->bpf.effective[type], array);
	/* free prog array after grace period, since __cgroup_bpf_run_*()
	 * might be still walking the array
	 */
	bpf_prog_array_free(old_array);
}

/**
 * cgroup_bpf_inherit() - inherit effective programs from parent
 * @cgrp: the cgroup to modify
 */
int cgroup_bpf_inherit(struct cgroup *cgrp)
{
/* has to use marco instead of const int, since compiler thinks
 * that array below is variable length
 */
#define	NR ARRAY_SIZE(cgrp->bpf.effective)
	struct bpf_prog_array __rcu *arrays[NR] = {};
	int i;

	for (i = 0; i < NR; i++)
		INIT_LIST_HEAD(&cgrp->bpf.progs[i]);

	for (i = 0; i < NR; i++)
		if (compute_effective_progs(cgrp, i, &arrays[i]))
			goto cleanup;

	for (i = 0; i < NR; i++)
		activate_effective_progs(cgrp, i, arrays[i]);

	return 0;
cleanup:
	for (i = 0; i < NR; i++)
		bpf_prog_array_free(arrays[i]);
	return -ENOMEM;
}

#define BPF_CGROUP_MAX_PROGS 64

/**
 * __cgroup_bpf_attach() - Attach the program to a cgroup, and
 *                         propagate the change to descendants
 * @cgrp: The cgroup which descendants to traverse
 * @prog: A program to attach
 * @type: Type of attach operation
 *
 * Must be called with cgroup_mutex held.
 */
int __cgroup_bpf_attach(struct cgroup *cgrp, struct bpf_prog *prog,
			enum bpf_attach_type type, u32 flags)
{
	struct list_head *progs = &cgrp->bpf.progs[type];
	struct bpf_prog *old_prog = NULL;
	struct cgroup_subsys_state *css;
	struct bpf_prog_list *pl;
	bool pl_was_allocated;
	u32 old_flags;
	int err;

	if ((flags & BPF_F_ALLOW_OVERRIDE) && (flags & BPF_F_ALLOW_MULTI))
		/* invalid combination */
		return -EINVAL;

	if (!hierarchy_allows_attach(cgrp, type, flags))
		return -EPERM;

	if (!list_empty(progs) && cgrp->bpf.flags[type] != flags)
		/* Disallow attaching non-overridable on top
		 * of existing overridable in this cgroup.
		 * Disallow attaching multi-prog if overridable or none
		 */
		return -EPERM;

	if (prog_list_length(progs) >= BPF_CGROUP_MAX_PROGS)
		return -E2BIG;

	if (flags & BPF_F_ALLOW_MULTI) {
		list_for_each_entry(pl, progs, node)
			if (pl->prog == prog)
				/* disallow attaching the same prog twice */
				return -EINVAL;

		pl = kmalloc(sizeof(*pl), GFP_KERNEL);
		if (!pl)
			return -ENOMEM;
		pl_was_allocated = true;
		pl->prog = prog;
		list_add_tail(&pl->node, progs);
	} else {
		if (list_empty(progs)) {
			pl = kmalloc(sizeof(*pl), GFP_KERNEL);
			if (!pl)
				return -ENOMEM;
			pl_was_allocated = true;
			list_add_tail(&pl->node, progs);
		} else {
			pl = list_first_entry(progs, typeof(*pl), node);
			old_prog = pl->prog;
			pl_was_allocated = false;
		}
		pl->prog = prog;
	}

	old_flags = cgrp->bpf.flags[type];
	cgrp->bpf.flags[type] = flags;

	/* allocate and recompute effective prog arrays */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		err = compute_effective_progs(desc, type, &desc->bpf.inactive);
		if (err)
			goto cleanup;
	}

	/* all allocations were successful. Activate all prog arrays */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		activate_effective_progs(desc, type, desc->bpf.inactive);
		desc->bpf.inactive = NULL;
	}

	static_branch_inc(&cgroup_bpf_enabled_key);
	if (old_prog) {
		bpf_prog_put(old_prog);
		static_branch_dec(&cgroup_bpf_enabled_key);
	}
	return 0;

cleanup:
	/* oom while computing effective. Free all computed effective arrays
	 * since they were not activated
	 */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		bpf_prog_array_free(desc->bpf.inactive);
		desc->bpf.inactive = NULL;
	}

	/* and cleanup the prog list */
	pl->prog = old_prog;
	if (pl_was_allocated) {
		list_del(&pl->node);
		kfree(pl);
	}
	return err;
}

/**
 * __cgroup_bpf_detach() - Detach the program from a cgroup, and
 *                         propagate the change to descendants
 * @cgrp: The cgroup which descendants to traverse
 * @prog: A program to detach or NULL
 * @type: Type of detach operation
 *
 * Must be called with cgroup_mutex held.
 */
int __cgroup_bpf_detach(struct cgroup *cgrp, struct bpf_prog *prog,
			enum bpf_attach_type type, u32 unused_flags)
{
	struct list_head *progs = &cgrp->bpf.progs[type];
	u32 flags = cgrp->bpf.flags[type];
	struct bpf_prog *old_prog = NULL;
	struct cgroup_subsys_state *css;
	struct bpf_prog_list *pl;
	int err;

	if (flags & BPF_F_ALLOW_MULTI) {
		if (!prog)
			/* to detach MULTI prog the user has to specify valid FD
			 * of the program to be detached
			 */
			return -EINVAL;
	} else {
		if (list_empty(progs))
			/* report error when trying to detach and nothing is attached */
			return -ENOENT;
	}

	if (flags & BPF_F_ALLOW_MULTI) {
		/* find the prog and detach it */
		list_for_each_entry(pl, progs, node) {
			if (pl->prog != prog)
				continue;
			old_prog = prog;
			/* mark it deleted, so it's ignored while
			 * recomputing effective
			 */
			pl->prog = NULL;
			break;
		}
		if (!old_prog)
			return -ENOENT;
	} else {
		/* to maintain backward compatibility NONE and OVERRIDE cgroups
		 * allow detaching with invalid FD (prog==NULL)
		 */
		pl = list_first_entry(progs, typeof(*pl), node);
		old_prog = pl->prog;
		pl->prog = NULL;
	}

	/* allocate and recompute effective prog arrays */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		err = compute_effective_progs(desc, type, &desc->bpf.inactive);
		if (err)
			goto cleanup;
	}

	/* all allocations were successful. Activate all prog arrays */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		activate_effective_progs(desc, type, desc->bpf.inactive);
		desc->bpf.inactive = NULL;
	}

	/* now can actually delete it from this cgroup list */
	list_del(&pl->node);
	kfree(pl);
	if (list_empty(progs))
		/* last program was detached, reset flags to zero */
		cgrp->bpf.flags[type] = 0;

	bpf_prog_put(old_prog);
	static_branch_dec(&cgroup_bpf_enabled_key);
	return 0;

cleanup:
	/* oom while computing effective. Free all computed effective arrays
	 * since they were not activated
	 */
	css_for_each_descendant_pre(css, &cgrp->self) {
		struct cgroup *desc = container_of(css, struct cgroup, self);

		bpf_prog_array_free(desc->bpf.inactive);
		desc->bpf.inactive = NULL;
	}

	/* and restore back old_prog */
	pl->prog = old_prog;
	return err;
}

/* Must be called with cgroup_mutex held to avoid races. */
int __cgroup_bpf_query(struct cgroup *cgrp, const union bpf_attr *attr,
		       union bpf_attr __user *uattr)
{
	__u32 __user *prog_attach_flags =
		u64_to_user_ptr(attr->query.prog_attach_flags);
	bool effective_query =
		attr->query.query_flags & BPF_F_QUERY_EFFECTIVE;
	__u32 __user *prog_ids = u64_to_user_ptr(attr->query.prog_ids);
	enum bpf_attach_type type = attr->query.attach_type;
	struct list_head *progs = &cgrp->bpf.progs[type];
	u32 flags = effective_query ? 0 : cgrp->bpf.flags[type];
	int cnt, ret = 0, i;

	if (effective_query && prog_attach_flags)
		return -EINVAL;

	if (effective_query)
		cnt = bpf_prog_array_length(cgrp->bpf.effective[type]);
	else
		cnt = prog_list_length(progs);

	if (copy_to_user(&uattr->query.attach_flags, &flags, sizeof(flags)))
		return -EFAULT;
	if (copy_to_user(&uattr->query.prog_cnt, &cnt, sizeof(cnt)))
		return -EFAULT;
	if (attr->query.prog_cnt == 0 || !prog_ids || !cnt)
		/* return early if user requested only program count + flags */
		return 0;
	if (attr->query.prog_cnt < cnt) {
		cnt = attr->query.prog_cnt;
		ret = -ENOSPC;
	}

	if (attr->query.query_flags & BPF_F_QUERY_EFFECTIVE) {
		return bpf_prog_array_copy_to_user(cgrp->bpf.effective[type],
						   prog_ids, cnt);
	} else {
		struct bpf_prog_list *pl;
		u32 id;

		i = 0;
		list_for_each_entry(pl, progs, node) {
			id = pl->prog->aux->id;
			if (copy_to_user(prog_ids + i, &id, sizeof(id)))
				return -EFAULT;
			if (++i == cnt)
				break;
		}
		if (prog_attach_flags) {
			for (i = 0; i < cnt; i++)
				if (copy_to_user(prog_attach_flags + i, &flags,
						 sizeof(flags)))
					return -EFAULT;
		}
	}
	return ret;
}

/**
 * __cgroup_bpf_run_filter_skb() - Run a program for packet filtering
 * @sk: The socket sending or receiving traffic
 * @skb: The skb that is being sent or received
 * @type: The type of program to be exectuted
 *
 * If no socket is passed, or the socket is not of type INET or INET6,
 * this function does nothing and returns 0.
 *
 * The program type passed in via @type must be suitable for network
 * filtering. No further check is performed to assert that.
 *
 * This function will return %-EPERM if any if an attached program was found
 * and if it returned != 1 during execution. In all other cases, 0 is returned.
 */
int __cgroup_bpf_run_filter_skb(struct sock *sk,
				struct sk_buff *skb,
				enum bpf_attach_type type)
{
	unsigned int offset = skb->data - skb_network_header(skb);
	struct sock *save_sk;
	struct cgroup *cgrp;
	int ret;

	if (!sk || !sk_fullsock(sk))
		return 0;

	if (sk->sk_family != AF_INET && sk->sk_family != AF_INET6)
		return 0;

	cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	save_sk = skb->sk;
	skb->sk = sk;
	__skb_push(skb, offset);
	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], skb,
				 bpf_prog_run_save_cb);
	__skb_pull(skb, offset);
	skb->sk = save_sk;
	return ret == 1 ? 0 : -EPERM;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_skb);

/**
 * __cgroup_bpf_run_filter_sk() - Run a program on a sock
 * @sk: sock structure to manipulate
 * @type: The type of program to be exectuted
 *
 * socket is passed is expected to be of type INET or INET6.
 *
 * The program type passed in via @type must be suitable for sock
 * filtering. No further check is performed to assert that.
 *
 * This function will return %-EPERM if any if an attached program was found
 * and if it returned != 1 during execution. In all other cases, 0 is returned.
 */
int __cgroup_bpf_run_filter_sk(struct sock *sk,
			       enum bpf_attach_type type)
{
	struct cgroup *cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	int ret;

	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], sk, BPF_PROG_RUN);
	return ret == 1 ? 0 : -EPERM;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_sk);

/**
 * __cgroup_bpf_run_filter_sock_addr() - Run a program on a sock and
 *                                       provided by user sockaddr
 * @sk: sock struct that will use sockaddr
 * @uaddr: sockaddr struct provided by user
 * @type: The type of program to be exectuted
 * @t_ctx: Pointer to attach type specific context
 *
 * socket is expected to be of type INET or INET6.
 *
 * This function will return %-EPERM if an attached program is found and
 * returned value != 1 during execution. In all other cases, 0 is returned.
 */
int __cgroup_bpf_run_filter_sock_addr(struct sock *sk,
				      struct sockaddr *uaddr,
				      enum bpf_attach_type type,
				      void *t_ctx)
{
	struct bpf_sock_addr_kern ctx = {
		.sk = sk,
		.uaddr = uaddr,
		.t_ctx = t_ctx,
	};
	struct sockaddr_storage unspec;
	struct cgroup *cgrp;
	int ret;

	/* Check socket family since not all sockets represent network
	 * endpoint (e.g. AF_UNIX).
	 */
	if (sk->sk_family != AF_INET && sk->sk_family != AF_INET6)
		return 0;

	if (!ctx.uaddr) {
		memset(&unspec, 0, sizeof(unspec));
		ctx.uaddr = (struct sockaddr *)&unspec;
	}

	cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], &ctx, BPF_PROG_RUN);

	return ret == 1 ? 0 : -EPERM;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_sock_addr);

/**
 * __cgroup_bpf_run_filter_sock_ops() - Run a program on a sock
 * @sk: socket to get cgroup from
 * @sock_ops: bpf_sock_ops_kern struct to pass to program. Contains
 * sk with connection information (IP addresses, etc.) May not contain
 * cgroup info if it is a req sock.
 * @type: The type of program to be exectuted
 *
 * socket passed is expected to be of type INET or INET6.
 *
 * The program type passed in via @type must be suitable for sock_ops
 * filtering. No further check is performed to assert that.
 *
 * This function will return %-EPERM if any if an attached program was found
 * and if it returned != 1 during execution. In all other cases, 0 is returned.
 */
int __cgroup_bpf_run_filter_sock_ops(struct sock *sk,
				     struct bpf_sock_ops_kern *sock_ops,
				     enum bpf_attach_type type)
{
	struct cgroup *cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	int ret;

	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], sock_ops,
				 BPF_PROG_RUN);
	return ret == 1 ? 0 : -EPERM;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_sock_ops);

int __cgroup_bpf_run_filter_sysctl(struct ctl_table_header *head,
				   struct ctl_table *table, int write,
				   void __user *buf, size_t *pcount,
				   loff_t *ppos, void **new_buf,
				   enum bpf_attach_type type)
{
	struct bpf_sysctl_kern ctx = {
		.head = head,
		.table = table,
		.write = write,
		.ppos = ppos,
		.cur_len = PAGE_SIZE,
	};
	struct cgroup *cgrp;
	int ret;

	ctx.cur_val = kmalloc(ctx.cur_len, GFP_KERNEL);
	if (ctx.cur_val) {
		mm_segment_t old_fs = get_fs();
		loff_t pos = 0;

		set_fs(KERNEL_DS);
		if (table->proc_handler(table, 0,
					(void __user *)ctx.cur_val,
					&ctx.cur_len, &pos))
			ctx.cur_len = 0;
		set_fs(old_fs);
	} else {
		ctx.cur_len = 0;
	}

	if (write && buf && *pcount) {
		ctx.new_val = kmalloc(PAGE_SIZE, GFP_KERNEL);
		ctx.new_len = min_t(size_t, PAGE_SIZE, *pcount);
		if (!ctx.new_val ||
		    copy_from_user(ctx.new_val, buf, ctx.new_len))
			ctx.new_len = 0;
	}

	cgrp = task_dfl_cgroup(current);
	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], &ctx,
				 BPF_PROG_RUN);

	kfree(ctx.cur_val);
	if (ret == 1 && ctx.new_updated) {
		*new_buf = ctx.new_val;
		*pcount = ctx.new_len;
	} else {
		kfree(ctx.new_val);
	}

	return ret == 1 ? 0 : -EPERM;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_sysctl);

static bool __cgroup_bpf_prog_array_is_empty(struct cgroup *cgrp,
					     enum bpf_attach_type type)
{
	struct bpf_prog_array *array;
	bool empty;

	rcu_read_lock();
	array = rcu_dereference(cgrp->bpf.effective[type]);
	empty = bpf_prog_array_is_empty(array);
	rcu_read_unlock();
	return empty;
}

static int sockopt_alloc_buf(struct bpf_sockopt_kern *ctx, int max_optlen)
{
	if (max_optlen < 0)
		return -EINVAL;
	if (max_optlen > PAGE_SIZE)
		max_optlen = PAGE_SIZE;

	ctx->optval = kzalloc(max_optlen, GFP_USER);
	if (!ctx->optval)
		return -ENOMEM;
	ctx->optval_end = ctx->optval + max_optlen;
	return max_optlen;
}

static void sockopt_free_buf(struct bpf_sockopt_kern *ctx)
{
	kfree(ctx->optval);
}

int __cgroup_bpf_run_filter_setsockopt(struct sock *sk, int *level,
				       int *optname, char __user *optval,
				       int *optlen, char **kernel_optval)
{
	struct cgroup *cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	struct bpf_sockopt_kern ctx = {
		.sk = sk,
		.level = *level,
		.optname = *optname,
	};
	int ret, max_optlen;

	if (__cgroup_bpf_prog_array_is_empty(cgrp, BPF_CGROUP_SETSOCKOPT))
		return 0;

	max_optlen = max_t(int, 16, *optlen);
	max_optlen = sockopt_alloc_buf(&ctx, max_optlen);
	if (max_optlen < 0)
		return max_optlen;

	ctx.optlen = *optlen;
	if (copy_from_user(ctx.optval, optval,
			   min(*optlen, max_optlen))) {
		ret = -EFAULT;
		goto out;
	}

	lock_sock(sk);
	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[BPF_CGROUP_SETSOCKOPT],
				 &ctx, BPF_PROG_RUN);
	release_sock(sk);
	if (!ret) {
		ret = -EPERM;
		goto out;
	}

	if (ctx.optlen == -1) {
		ret = 1;
	} else if (ctx.optlen > max_optlen || ctx.optlen < -1) {
		ret = -EFAULT;
	} else {
		ret = 0;
		*level = ctx.level;
		*optname = ctx.optname;
		if (ctx.optlen != 0) {
			*optlen = ctx.optlen;
			*kernel_optval = (char *)ctx.optval;
			return 0;
		}
	}

out:
	sockopt_free_buf(&ctx);
	return ret;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_setsockopt);

int __cgroup_bpf_run_filter_getsockopt(struct sock *sk, int level,
				       int optname, char __user *optval,
				       int __user *optlen, int max_optlen,
				       int retval)
{
	struct cgroup *cgrp = sock_cgroup_ptr(&sk->sk_cgrp_data);
	struct bpf_sockopt_kern ctx = {
		.sk = sk,
		.level = level,
		.optname = optname,
		.retval = retval,
		.optlen = max_optlen,
	};
	int ret;

	if (max_optlen < 0)
		return max_optlen;
	if (__cgroup_bpf_prog_array_is_empty(cgrp, BPF_CGROUP_GETSOCKOPT))
		return retval;

	max_optlen = sockopt_alloc_buf(&ctx, max_optlen);
	if (max_optlen < 0)
		return max_optlen;

	if (!retval) {
		if (get_user(ctx.optlen, optlen)) {
			ret = -EFAULT;
			goto out;
		}
		if (ctx.optlen < 0 ||
		    copy_from_user(ctx.optval, optval,
				   min(ctx.optlen, max_optlen))) {
			ret = -EFAULT;
			goto out;
		}
	}

	lock_sock(sk);
	ret = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[BPF_CGROUP_GETSOCKOPT],
				 &ctx, BPF_PROG_RUN);
	release_sock(sk);
	if (!ret) {
		ret = -EPERM;
		goto out;
	}

	if ((optval && (ctx.optlen > max_optlen || ctx.optlen < 0)) ||
	    (ctx.retval != 0 && ctx.retval != retval)) {
		ret = -EFAULT;
		goto out;
	}

	if (ctx.optlen) {
		if (optval && copy_to_user(optval, ctx.optval, ctx.optlen)) {
			ret = -EFAULT;
			goto out;
		}
		if (put_user(ctx.optlen, optlen)) {
			ret = -EFAULT;
			goto out;
		}
	}
	ret = ctx.retval;

out:
	sockopt_free_buf(&ctx);
	return ret;
}
EXPORT_SYMBOL(__cgroup_bpf_run_filter_getsockopt);

static const struct bpf_func_proto *
cgroup_base_func_proto(enum bpf_func_id func_id, const struct bpf_prog *prog)
{
	switch (func_id) {
	case BPF_FUNC_map_lookup_elem:
		return &bpf_map_lookup_elem_proto;
	case BPF_FUNC_map_update_elem:
		return &bpf_map_update_elem_proto;
	case BPF_FUNC_map_delete_elem:
		return &bpf_map_delete_elem_proto;
	case BPF_FUNC_get_current_uid_gid:
		return &bpf_get_current_uid_gid_proto;
	case BPF_FUNC_ktime_get_ns:
		return &bpf_ktime_get_ns_proto;
	case BPF_FUNC_ktime_get_boot_ns:
		return &bpf_ktime_get_boot_ns_proto;
	default:
		return NULL;
	}
}

static ssize_t sysctl_cpy_dir(const struct ctl_dir *dir, char **bufp,
			      size_t *lenp)
{
	ssize_t tmp_ret = 0, ret;

	if (dir->header.parent) {
		tmp_ret = sysctl_cpy_dir(dir->header.parent, bufp, lenp);
		if (tmp_ret < 0)
			return tmp_ret;
	}

	ret = strscpy(*bufp, dir->header.ctl_table[0].procname, *lenp);
	if (ret < 0)
		return ret;
	*bufp += ret;
	*lenp -= ret;
	ret += tmp_ret;
	if (!ret)
		return ret;

	tmp_ret = strscpy(*bufp, "/", *lenp);
	if (tmp_ret < 0)
		return tmp_ret;
	*bufp += tmp_ret;
	*lenp -= tmp_ret;
	return ret + tmp_ret;
}

BPF_CALL_4(bpf_sysctl_get_name, struct bpf_sysctl_kern *, ctx, char *, buf,
	   size_t, buf_len, u64, flags)
{
	ssize_t tmp_ret = 0, ret;

	if (!buf || flags & ~BPF_F_SYSCTL_BASE_NAME)
		return -EINVAL;
	if (!(flags & BPF_F_SYSCTL_BASE_NAME)) {
		tmp_ret = sysctl_cpy_dir(ctx->head->parent, &buf, &buf_len);
		if (tmp_ret < 0)
			return tmp_ret;
	}
	ret = strscpy(buf, ctx->table->procname, buf_len);
	return ret < 0 ? ret : tmp_ret + ret;
}

static const struct bpf_func_proto bpf_sysctl_get_name_proto = {
	.func = bpf_sysctl_get_name,
	.gpl_only = false,
	.ret_type = RET_INTEGER,
	.arg1_type = ARG_PTR_TO_CTX,
	.arg2_type = ARG_PTR_TO_MEM,
	.arg3_type = ARG_CONST_SIZE,
	.arg4_type = ARG_ANYTHING,
};

static int copy_sysctl_value(char *dst, size_t dst_len, char *src,
			     size_t src_len)
{
	if (!dst)
		return -EINVAL;
	if (!dst_len)
		return -E2BIG;
	if (!src || !src_len) {
		memset(dst, 0, dst_len);
		return -EINVAL;
	}
	memcpy(dst, src, min(dst_len, src_len));
	if (dst_len > src_len) {
		memset(dst + src_len, 0, dst_len - src_len);
		return src_len;
	}
	dst[dst_len - 1] = '\0';
	return -E2BIG;
}

BPF_CALL_3(bpf_sysctl_get_current_value, struct bpf_sysctl_kern *, ctx,
	   char *, buf, size_t, buf_len)
{
	return copy_sysctl_value(buf, buf_len, ctx->cur_val, ctx->cur_len);
}

static const struct bpf_func_proto bpf_sysctl_get_current_value_proto = {
	.func = bpf_sysctl_get_current_value,
	.gpl_only = false,
	.ret_type = RET_INTEGER,
	.arg1_type = ARG_PTR_TO_CTX,
	.arg2_type = ARG_PTR_TO_UNINIT_MEM,
	.arg3_type = ARG_CONST_SIZE,
};

BPF_CALL_3(bpf_sysctl_get_new_value, struct bpf_sysctl_kern *, ctx,
	   char *, buf, size_t, buf_len)
{
	if (!ctx->write) {
		if (buf && buf_len)
			memset(buf, 0, buf_len);
		return -EINVAL;
	}
	return copy_sysctl_value(buf, buf_len, ctx->new_val, ctx->new_len);
}

static const struct bpf_func_proto bpf_sysctl_get_new_value_proto = {
	.func = bpf_sysctl_get_new_value,
	.gpl_only = false,
	.ret_type = RET_INTEGER,
	.arg1_type = ARG_PTR_TO_CTX,
	.arg2_type = ARG_PTR_TO_UNINIT_MEM,
	.arg3_type = ARG_CONST_SIZE,
};

BPF_CALL_3(bpf_sysctl_set_new_value, struct bpf_sysctl_kern *, ctx,
	   const char *, buf, size_t, buf_len)
{
	if (!ctx->write || !ctx->new_val || !ctx->new_len || !buf || !buf_len)
		return -EINVAL;
	if (buf_len > PAGE_SIZE - 1)
		return -E2BIG;
	memcpy(ctx->new_val, buf, buf_len);
	ctx->new_len = buf_len;
	ctx->new_updated = 1;
	return 0;
}

static const struct bpf_func_proto bpf_sysctl_set_new_value_proto = {
	.func = bpf_sysctl_set_new_value,
	.gpl_only = false,
	.ret_type = RET_INTEGER,
	.arg1_type = ARG_PTR_TO_CTX,
	.arg2_type = ARG_PTR_TO_MEM,
	.arg3_type = ARG_CONST_SIZE,
};

static const struct bpf_func_proto *
sysctl_func_proto(enum bpf_func_id func_id, const struct bpf_prog *prog)
{
	switch (func_id) {
	case BPF_FUNC_strtol:
		return &bpf_strtol_proto;
	case BPF_FUNC_strtoul:
		return &bpf_strtoul_proto;
	case BPF_FUNC_sysctl_get_name:
		return &bpf_sysctl_get_name_proto;
	case BPF_FUNC_sysctl_get_current_value:
		return &bpf_sysctl_get_current_value_proto;
	case BPF_FUNC_sysctl_get_new_value:
		return &bpf_sysctl_get_new_value_proto;
	case BPF_FUNC_sysctl_set_new_value:
		return &bpf_sysctl_set_new_value_proto;
	default:
		return cgroup_base_func_proto(func_id, prog);
	}
}

static bool sysctl_is_valid_access(int off, int size,
				   enum bpf_access_type type,
				   const struct bpf_prog *prog,
				   struct bpf_insn_access_aux *info)
{
	const int size_default = sizeof(__u32);

	if (off < 0 || off + size > sizeof(struct bpf_sysctl) || off % size)
		return false;
	switch (off) {
	case bpf_ctx_range(struct bpf_sysctl, write):
		if (type != BPF_READ)
			return false;
		bpf_ctx_record_field_size(info, size_default);
		return bpf_ctx_narrow_access_ok(off, size, size_default);
	case bpf_ctx_range(struct bpf_sysctl, file_pos):
		if (type == BPF_READ) {
			bpf_ctx_record_field_size(info, size_default);
			return bpf_ctx_narrow_access_ok(off, size, size_default);
		}
		return size == size_default;
	default:
		return false;
	}
}

static u32 sysctl_convert_ctx_access(enum bpf_access_type type,
				     const struct bpf_insn *si,
				     struct bpf_insn *insn_buf,
				     struct bpf_prog *prog,
				     u32 *target_size)
{
	struct bpf_insn *insn = insn_buf;

	switch (si->off) {
	case offsetof(struct bpf_sysctl, write):
		*insn++ = BPF_LDX_MEM(BPF_SIZE(si->code), si->dst_reg,
				      si->src_reg,
				      bpf_target_off(struct bpf_sysctl_kern,
						     write, sizeof(int),
						     target_size));
		break;
	case offsetof(struct bpf_sysctl, file_pos):
		if (type == BPF_WRITE) {
			int treg = BPF_REG_9;

			if (si->src_reg == treg || si->dst_reg == treg)
				--treg;
			if (si->src_reg == treg || si->dst_reg == treg)
				--treg;
			*insn++ = BPF_STX_MEM(BPF_DW, si->dst_reg, treg,
					      offsetof(struct bpf_sysctl_kern,
						       tmp_reg));
			*insn++ = BPF_LDX_MEM(BPF_SIZEOF(loff_t *), treg,
					      si->dst_reg,
					      offsetof(struct bpf_sysctl_kern, ppos));
			*insn++ = BPF_STX_MEM(BPF_W, treg, si->src_reg, 0);
			*insn++ = BPF_LDX_MEM(BPF_DW, treg, si->dst_reg,
					      offsetof(struct bpf_sysctl_kern,
						       tmp_reg));
		} else {
			*insn++ = BPF_LDX_MEM(BPF_SIZEOF(loff_t *),
					      si->dst_reg, si->src_reg,
					      offsetof(struct bpf_sysctl_kern, ppos));
			*insn++ = BPF_LDX_MEM(BPF_SIZE(si->code), si->dst_reg,
					      si->dst_reg, 0);
		}
		*target_size = sizeof(u32);
		break;
	}
	return insn - insn_buf;
}

const struct bpf_verifier_ops cg_sysctl_prog_ops = {
	.get_func_proto = sysctl_func_proto,
	.is_valid_access = sysctl_is_valid_access,
	.convert_ctx_access = sysctl_convert_ctx_access,
};

static const struct bpf_func_proto *
cg_sockopt_func_proto(enum bpf_func_id func_id, const struct bpf_prog *prog)
{
	switch (func_id) {
	case BPF_FUNC_sk_storage_get:
		return &bpf_sk_storage_get_proto;
	case BPF_FUNC_sk_storage_delete:
		return &bpf_sk_storage_delete_proto;
	default:
		return cgroup_base_func_proto(func_id, prog);
	}
}

static bool cg_sockopt_is_valid_access(int off, int size,
				       enum bpf_access_type type,
				       const struct bpf_prog *prog,
				       struct bpf_insn_access_aux *info)
{
	const int size_default = sizeof(__u32);

	if (off < 0 || off >= sizeof(struct bpf_sockopt) || off % size)
		return false;
	if (type == BPF_WRITE) {
		switch (off) {
		case offsetof(struct bpf_sockopt, retval):
			return size == size_default && prog->expected_attach_type ==
				BPF_CGROUP_GETSOCKOPT;
		case offsetof(struct bpf_sockopt, optname):
		case offsetof(struct bpf_sockopt, level):
			return size == size_default && prog->expected_attach_type ==
				BPF_CGROUP_SETSOCKOPT;
		case offsetof(struct bpf_sockopt, optlen):
			return size == size_default;
		default:
			return false;
		}
	}

	switch (off) {
	case offsetof(struct bpf_sockopt, sk):
		if (size != sizeof(__u64))
			return false;
		info->reg_type = PTR_TO_SOCKET;
		break;
	case offsetof(struct bpf_sockopt, optval):
		if (size != sizeof(__u64))
			return false;
		info->reg_type = PTR_TO_PACKET;
		break;
	case offsetof(struct bpf_sockopt, optval_end):
		if (size != sizeof(__u64))
			return false;
		info->reg_type = PTR_TO_PACKET_END;
		break;
	case offsetof(struct bpf_sockopt, retval):
		return size == size_default && prog->expected_attach_type ==
			BPF_CGROUP_GETSOCKOPT;
	default:
		return size == size_default;
	}
	return true;
}

#define CG_SOCKOPT_ACCESS_FIELD(T, F) \
	T(BPF_FIELD_SIZEOF(struct bpf_sockopt_kern, F), si->dst_reg, \
	  si->src_reg, offsetof(struct bpf_sockopt_kern, F))

static u32 cg_sockopt_convert_ctx_access(enum bpf_access_type type,
					 const struct bpf_insn *si,
					 struct bpf_insn *insn_buf,
					 struct bpf_prog *prog,
					 u32 *target_size)
{
	struct bpf_insn *insn = insn_buf;

#define SOCKOPT_SCALAR(F) \
	case offsetof(struct bpf_sockopt, F): \
		if (type == BPF_WRITE) \
			*insn++ = CG_SOCKOPT_ACCESS_FIELD(BPF_STX_MEM, F); \
		else \
			*insn++ = CG_SOCKOPT_ACCESS_FIELD(BPF_LDX_MEM, F); \
		break
	switch (si->off) {
	case offsetof(struct bpf_sockopt, sk):
		*insn++ = CG_SOCKOPT_ACCESS_FIELD(BPF_LDX_MEM, sk);
		break;
	SOCKOPT_SCALAR(level);
	SOCKOPT_SCALAR(optname);
	SOCKOPT_SCALAR(optlen);
	SOCKOPT_SCALAR(retval);
	case offsetof(struct bpf_sockopt, optval):
		*insn++ = CG_SOCKOPT_ACCESS_FIELD(BPF_LDX_MEM, optval);
		break;
	case offsetof(struct bpf_sockopt, optval_end):
		*insn++ = CG_SOCKOPT_ACCESS_FIELD(BPF_LDX_MEM, optval_end);
		break;
	}
#undef SOCKOPT_SCALAR
	return insn - insn_buf;
}

static int cg_sockopt_get_prologue(struct bpf_insn *insn_buf,
				   bool direct_write,
				   const struct bpf_prog *prog)
{
	return 0;
}

const struct bpf_verifier_ops cg_sockopt_prog_ops = {
	.get_func_proto = cg_sockopt_func_proto,
	.is_valid_access = cg_sockopt_is_valid_access,
	.convert_ctx_access = cg_sockopt_convert_ctx_access,
	.gen_prologue = cg_sockopt_get_prologue,
};
