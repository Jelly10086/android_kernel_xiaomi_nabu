// SPDX-License-Identifier: GPL-2.0
/*
 * Creation-only XSKMAP compatibility for Android BPF loaders.
 *
 * This kernel does not provide AF_XDP.  The map can be created, named and
 * pinned so that unrelated BPF objects can finish loading, but every data
 * operation is rejected.  Do not add redirect semantics here without the
 * complete AF_XDP socket lifetime implementation.
 */

#include <linux/bpf.h>
#include <linux/capability.h>
#include <linux/mm.h>

#define XSK_COMPAT_CREATE_FLAG_MASK \
	(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY)

struct xsk_compat_map {
	struct bpf_map map;
	void *entries[];
};

static struct bpf_map *xsk_compat_map_alloc(union bpf_attr *attr)
{
	struct xsk_compat_map *xmap;
	u64 size, pages;
	int err;

	if (!capable(CAP_NET_ADMIN))
		return ERR_PTR(-EPERM);

	if (!attr->max_entries || attr->key_size != sizeof(u32) ||
	    attr->value_size != sizeof(u32) ||
	    attr->map_flags & ~XSK_COMPAT_CREATE_FLAG_MASK)
		return ERR_PTR(-EINVAL);

	size = sizeof(*xmap) +
	       (u64)attr->max_entries * sizeof(xmap->entries[0]);
	if (size >= U32_MAX - PAGE_SIZE)
		return ERR_PTR(-E2BIG);

	pages = round_up(size, PAGE_SIZE) >> PAGE_SHIFT;
	err = bpf_map_precharge_memlock(pages);
	if (err)
		return ERR_PTR(err);

	xmap = bpf_map_area_alloc(size, bpf_map_attr_numa_node(attr));
	if (!xmap)
		return ERR_PTR(-ENOMEM);

	bpf_map_init_from_attr(&xmap->map, attr);
	xmap->map.pages = pages;
	return &xmap->map;
}

static void xsk_compat_map_free(struct bpf_map *map)
{
	struct xsk_compat_map *xmap;

	xmap = container_of(map, struct xsk_compat_map, map);
	bpf_map_area_free(xmap);
}

static int xsk_compat_map_get_next_key(struct bpf_map *map, void *key,
				       void *next_key)
{
	u32 index = key ? *(u32 *)key : U32_MAX;
	u32 *next = next_key;

	if (index >= map->max_entries) {
		*next = 0;
		return 0;
	}

	if (index == map->max_entries - 1)
		return -ENOENT;

	*next = index + 1;
	return 0;
}

static void *xsk_compat_map_lookup_elem(struct bpf_map *map, void *key)
{
	return NULL;
}

static void *xsk_compat_map_lookup_elem_sys_only(struct bpf_map *map,
						 void *key)
{
	return ERR_PTR(-EOPNOTSUPP);
}

static int xsk_compat_map_update_elem(struct bpf_map *map, void *key,
				      void *value, u64 flags)
{
	return -EOPNOTSUPP;
}

static int xsk_compat_map_delete_elem(struct bpf_map *map, void *key)
{
	return -EOPNOTSUPP;
}

const struct bpf_map_ops xsk_compat_map_ops = {
	.map_alloc = xsk_compat_map_alloc,
	.map_free = xsk_compat_map_free,
	.map_get_next_key = xsk_compat_map_get_next_key,
	.map_lookup_elem = xsk_compat_map_lookup_elem,
	.map_lookup_elem_sys_only = xsk_compat_map_lookup_elem_sys_only,
	.map_update_elem = xsk_compat_map_update_elem,
	.map_delete_elem = xsk_compat_map_delete_elem,
};
