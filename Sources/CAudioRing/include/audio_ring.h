#pragma once
// Lock-free single-producer/single-consumer ring of mono Float32 samples. The
// producer is the real-time audio callback; the consumer is a normal queue.
// Writes and reads never allocate, lock or block.
#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>

typedef struct vt_ring vt_ring;

/// Allocates a ring holding at least `capacity` samples (rounded up to a
/// power of two). Returns NULL on allocation failure.
vt_ring *vt_ring_create(uint32_t capacity);
void vt_ring_destroy(vt_ring *ring);

/// Producer side, real-time safe: averages every channel of `frames` Float32
/// frames in `buffers` (interleaved, deinterleaved or mixed) into one mono
/// sample each and appends them. `frames` is clamped to what each buffer's
/// `mDataByteSize` holds; frames that don't fit are dropped. Returns the
/// number of frames written.
uint32_t vt_ring_write_downmix(vt_ring *ring, const AudioBufferList *buffers, uint32_t frames);

/// Consumer side: moves up to `max` samples into `dst`. Returns the count.
uint32_t vt_ring_read(vt_ring *ring, float *dst, uint32_t max);

/// Empties the ring. Only call while neither side is running.
void vt_ring_reset(vt_ring *ring);
