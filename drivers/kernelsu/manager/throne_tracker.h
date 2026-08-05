#ifndef __KSU_H_UID_OBSERVER
#define __KSU_H_UID_OBSERVER

void ksu_throne_tracker_init(void);

void ksu_throne_tracker_exit(void);

void track_throne(bool prune_only);

bool track_throne_for_uid(uid_t uid);

#endif
