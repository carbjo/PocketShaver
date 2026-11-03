/*
 *  rave_presentation_policy.h - Deferred RAVE frame presentation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_PRESENTATION_POLICY_H
#define RAVE_PRESENTATION_POLICY_H

#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <utility>
#include <vector>

enum class RavePresentationResult { Presented, Discarded, Failed };

inline bool RaveDeferCPUPresentation(bool dontSwap, bool hasPendingFrame)
{
    return dontSwap || hasPendingFrame;
}

struct RaveCPUPresentationFrame {
    uint64_t renderSerial = 0;
    bool cpuComposite = false;
    std::vector<uint8_t> cpuPixels;

    // Preserve guest-composed pixels before a later ATI lock replaces them.
    void PreserveCPUFrame(uint64_t serial, const uint8_t *pixels, std::size_t size)
    {
        if (serial != renderSerial || !pixels) return;
        cpuComposite = true;
        cpuPixels.assign(pixels, pixels + size);
    }

    const uint8_t *CPUPixelsForSwap(uint64_t serial, const uint8_t *pixels,
                                    std::size_t size, bool dirty) const
    {
        if (dirty && serial == renderSerial && pixels) return pixels;
        return cpuPixels.size() == size ? cpuPixels.data() : nullptr;
    }
};

// Capture must produce an independent frame: the compositor retains texture
// identity, so retaining the writable render target would not retain its pixels.
// Owners are context identities. Display-owner changes invalidate every entry.
template <typename Owner, typename Frame>
class RavePresentationQueue {
public:
    template <typename Capture, typename Publish>
    bool FinishFrame(Owner owner, bool dontSwap, bool cpuComposite,
                     Capture capture, Publish publish)
    {
        pending.erase(owner);
        if (cpuComposite && !dontSwap) return true;
        Frame frame{};
        if (!capture(frame)) return false;
        if (dontSwap) {
            pending.emplace(owner, std::move(frame));
            return true;
        }
        return publish(frame) != RavePresentationResult::Failed;
    }

    template <typename Publish>
    RavePresentationResult Swap(Owner owner, Publish publish)
    {
        auto entry = pending.find(owner);
        if (entry == pending.end()) return RavePresentationResult::Discarded;
        const RavePresentationResult result = publish(entry->second);
        if (result != RavePresentationResult::Failed) pending.erase(entry);
        return result;
    }

    Frame *Find(Owner owner)
    {
        auto entry = pending.find(owner);
        return entry == pending.end() ? nullptr : &entry->second;
    }

    void ClearOwner(Owner owner) { pending.erase(owner); }
    void Clear() { pending.clear(); }

private:
    std::unordered_map<Owner, Frame> pending;
};

#endif
