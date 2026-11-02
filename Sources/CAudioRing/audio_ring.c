#include "audio_ring.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct vt_ring {
    // Running totals; their difference is the fill level. Each is written by
    // one side only and read by the other with acquire/release ordering.
    _Atomic uint64_t written;
    _Atomic uint64_t read;
    uint32_t mask;
    float *samples;
};

vt_ring *vt_ring_create(uint32_t capacity) {
    uint32_t size = 1;
    while (size < capacity && size < (1u << 31)) size <<= 1;
    vt_ring *ring = calloc(1, sizeof *ring);
    if (!ring) return NULL;
    ring->samples = calloc(size, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->mask = size - 1;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->read, 0);
    return ring;
}

void vt_ring_destroy(vt_ring *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring);
}

uint32_t vt_ring_write_downmix(vt_ring *ring, const AudioBufferList *buffers, uint32_t frames) {
    uint64_t head = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint64_t space = (uint64_t)ring->mask + 1 - (head - tail);
    uint32_t n = frames < space ? frames : (uint32_t)space;

    // Never read past a buffer, whatever `frames` claims.
    uint32_t channels = 0;
    for (uint32_t b = 0; b < buffers->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &buffers->mBuffers[b];
        if (!buffer->mData) return 0;
        if (buffer->mNumberChannels == 0) continue;
        uint32_t held = buffer->mDataByteSize / (buffer->mNumberChannels * (uint32_t)sizeof(float));
        if (held < n) n = held;
        channels += buffer->mNumberChannels;
    }
    if (channels == 0) return 0;
    const float scale = 1.0f / (float)channels;

    for (uint32_t i = 0; i < n; i++) {
        float sum = 0;
        for (uint32_t b = 0; b < buffers->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &buffers->mBuffers[b];
            const float *frame = (const float *)buffer->mData + (size_t)i * buffer->mNumberChannels;
            for (uint32_t c = 0; c < buffer->mNumberChannels; c++) sum += frame[c];
        }
        ring->samples[(head + i) & ring->mask] = sum * scale;
    }
    atomic_store_explicit(&ring->written, head + n, memory_order_release);
    return n;
}

uint32_t vt_ring_read(vt_ring *ring, float *dst, uint32_t max) {
    uint64_t tail = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint64_t available = head - tail;
    uint32_t n = available < max ? (uint32_t)available : max;

    uint32_t start = (uint32_t)(tail & ring->mask);
    uint32_t first = ring->mask + 1 - start;
    if (first > n) first = n;
    memcpy(dst, ring->samples + start, first * sizeof(float));
    memcpy(dst + first, ring->samples, (n - first) * sizeof(float));
    atomic_store_explicit(&ring->read, tail + n, memory_order_release);
    return n;
}

void vt_ring_reset(vt_ring *ring) {
    atomic_store(&ring->written, 0);
    atomic_store(&ring->read, 0);
}
