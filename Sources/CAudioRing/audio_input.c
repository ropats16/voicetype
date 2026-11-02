#include "audio_input.h"
#include <stddef.h>
#include <stdlib.h>

struct vt_input {
    vt_ring *ring;
    AudioUnit unit;
    uint32_t max_frames;
    float *storage;
    // Last: `buffers` holds one AudioBuffer per channel.
    AudioBufferList buffers;
};

vt_input *vt_input_create(vt_ring *ring, AudioUnit unit, uint32_t channels, uint32_t max_frames) {
    if (channels == 0) return NULL;
    vt_input *input = calloc(1, offsetof(vt_input, buffers.mBuffers) + channels * sizeof(AudioBuffer));
    if (!input) return NULL;
    input->storage = calloc((size_t)channels * max_frames, sizeof(float));
    if (!input->storage) { free(input); return NULL; }
    input->ring = ring;
    input->unit = unit;
    input->max_frames = max_frames;
    input->buffers.mNumberBuffers = channels;
    return input;
}

void vt_input_destroy(vt_input *input) {
    if (!input) return;
    free(input->storage);
    free(input);
}

static OSStatus render(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                       UInt32 bus, UInt32 frames, AudioBufferList *unused) {
    (void)unused;
    vt_input *input = refCon;
    if (frames > input->max_frames) return kAudioUnitErr_TooManyFramesToProcess;
    // A render may repoint or resize the buffers, so reset them every slice.
    for (UInt32 c = 0; c < input->buffers.mNumberBuffers; c++) {
        input->buffers.mBuffers[c].mNumberChannels = 1;
        input->buffers.mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        input->buffers.mBuffers[c].mData = input->storage + (size_t)c * input->max_frames;
    }
    OSStatus status = AudioUnitRender(input->unit, flags, timeStamp, bus, frames, &input->buffers);
    if (status == noErr) vt_ring_write_downmix(input->ring, &input->buffers, frames);
    return status;
}

OSStatus vt_input_install(vt_input *input) {
    AURenderCallbackStruct callback = { .inputProc = render, .inputProcRefCon = input };
    return AudioUnitSetProperty(input->unit, kAudioOutputUnitProperty_SetInputCallback,
                                kAudioUnitScope_Global, 0, &callback, sizeof callback);
}
