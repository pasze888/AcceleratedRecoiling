package com.wiyuka.acceleratedrecoiling.natives.realtime.index;

import it.unimi.dsi.fastutil.HashCommon;
import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;

final class PositionGroups {
    private static final int MIN_GROUP_SIZE = 32;

    private static final class PositionGroup {
        double x;
        double z;
        int memberCount;
        PositionGroup next;
        long[] memberBitmap;
    }

    private final PositionGroup[] entityGroups;
    private final Long2ObjectOpenHashMap<PositionGroup> groupsByHash = new Long2ObjectOpenHashMap<>();
    private final int wordsPerBitmap;
    private final int bitmapBudget;
    private PositionGroup firstReusableGroup;
    private int allocatedBitmapWords;

    PositionGroups(int capacity, int bitmapBudget) {
        entityGroups = new PositionGroup[capacity];
        wordsPerBitmap = Math.addExact(capacity, Long.SIZE - 1) / Long.SIZE;
        this.bitmapBudget = bitmapBudget;
    }

    long[] coincidentBitmap(double x, double z) {
        if (!Double.isFinite(x) || !Double.isFinite(z)) {
            return null;
        }

        PositionGroup group = findGroup(x, z);
        if (group == null || group.memberCount < MIN_GROUP_SIZE) {
            return null;
        }

        return group.memberBitmap;
    }

    void update(int slot, double x, double z, boolean eligible) {
        PositionGroup currentGroup = entityGroups[slot];
        if (eligible && currentGroup != null && currentGroup.x == x && currentGroup.z == z) {
            return;
        }

        if (currentGroup != null) {
            leaveGroup(slot, currentGroup);
        }
        if (eligible) {
            joinGroup(slot, x, z);
        }
    }

    void remove(int slot) {
        PositionGroup group = entityGroups[slot];
        if (group != null) {
            leaveGroup(slot, group);
        }
    }

    private void joinGroup(int slot, double x, double z) {
        PositionGroup group = findGroup(x, z);
        if (group == null) {
            group = createGroup(x, z);
        }

        entityGroups[slot] = group;
        group.memberCount++;

        if (group.memberBitmap != null) {
            setGroupMember(group, slot, true);
        } else if (group.memberCount == MIN_GROUP_SIZE) {
            allocateGroupBitmap(group);
        }
    }

    private PositionGroup createGroup(double x, double z) {
        PositionGroup group;
        if (firstReusableGroup == null) {
            group = new PositionGroup();
        } else {
            group = firstReusableGroup;
            firstReusableGroup = group.next;
        }

        group.x = x;
        group.z = z;
        group.next = groupsByHash.put(positionHash(x, z), group);
        return group;
    }

    private PositionGroup findGroup(double x, double z) {
        long hash = positionHash(x, z);
        for (PositionGroup group = groupsByHash.get(hash); group != null; group = group.next) {
            if (group.x == x && group.z == z) {
                return group;
            }
        }

        return null;
    }

    private void leaveGroup(int slot, PositionGroup group) {
        entityGroups[slot] = null;
        if (group.memberBitmap != null) {
            setGroupMember(group, slot, false);
        }

        group.memberCount--;
        if (group.memberCount == 0) {
            recycleGroup(group);
        }
    }

    private void recycleGroup(PositionGroup group) {
        long hash = positionHash(group.x, group.z);
        PositionGroup firstInBucket = groupsByHash.get(hash);
        if (firstInBucket == group) {
            if (group.next == null) {
                groupsByHash.remove(hash);
            } else {
                groupsByHash.put(hash, group.next);
            }
        } else {
            PositionGroup previousGroup = firstInBucket;
            while (previousGroup.next != group) {
                previousGroup = previousGroup.next;
            }
            previousGroup.next = group.next;
        }

        group.next = firstReusableGroup;
        firstReusableGroup = group;
    }

    private void allocateGroupBitmap(PositionGroup group) {
        if (allocatedBitmapWords + wordsPerBitmap > bitmapBudget) {
            return;
        }

        group.memberBitmap = new long[wordsPerBitmap];
        allocatedBitmapWords += wordsPerBitmap;

        for (int slot = 0; slot < entityGroups.length; slot++) {
            if (entityGroups[slot] == group) {
                setGroupMember(group, slot, true);
            }
        }
    }

    private static long positionHash(double x, double z) {
        long bitsX = x == 0 ? 0 : Double.doubleToLongBits(x);
        long bitsZ = z == 0 ? 0 : Double.doubleToLongBits(z);
        return HashCommon.mix(bitsX ^ Long.rotateLeft(bitsZ, Integer.SIZE));
    }

    private static void setGroupMember(PositionGroup group, int slot, boolean set) {
        int word = slot >>> 6;
        long bitMask = 1L << slot;
        if (set) {
            group.memberBitmap[word] |= bitMask;
        } else {
            group.memberBitmap[word] &= ~bitMask;
        }
    }
}
