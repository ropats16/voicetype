#pragma once
// Real-time input callback for an input-only AUHAL: renders each slice into
// buffers allocated up front, then downmixes it into a ring. Nothing on the
// audio thread allocates, locks or blocks.
#include <AudioToolbox/AudioToolbox.h>
#include "audio_ring.h"

typedef struct vt_input vt_input;

/// Allocates deinterleaved Float32 buffers for `channels` channels of up to
/// `max_frames` frames, written to `ring`. Returns NULL on allocation failure.
vt_input *vt_input_create(vt_ring *ring, AudioUnit unit, uint32_t channels, uint32_t max_frames);
/// Only call once the unit is disposed: then nothing calls back into it.
void vt_input_destroy(vt_input *input);

/// Makes `input` the unit's input callback. A slice longer than `max_frames`
/// is dropped.
OSStatus vt_input_install(vt_input *input);
