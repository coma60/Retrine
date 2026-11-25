// The music's spectrum in three bands (SGMusicSpectrum.h).
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/SGPCMRead.h"
#import "SGMusicSpectrum.h"

// The Music app's analyzer takes its tap's buffers whole, 4096 frames as a rule, unwindowed.
enum { kLog2N = 12, kN = 1 << kLog2N, kHalf = kN / 2, kBands = 3 };
// The Music app's bands, in hertz: each a lower and an upper edge (a bin counts when lower < its frequency <= upper).
static const float kBandEdge[kBands][2] = {{20, 300}, {300, 3500}, {3500, 24000}};

static atomic_bool sg_wanted;
static _Atomic uint64_t sg_layout;              // format flags | channels << 32 | bytes << 48, 0 for none
static _Atomic uint64_t sg_sampleRateBits;
static _Atomic uint32_t sg_levelBits[kBands];
static _Atomic uint64_t sg_readings;            // how many readings there have been; bumped after the levels are stored

// Render-thread state: only the notify touches it, under the output's admission.
static FFTSetup sg_fft;
static float sg_frame[kN], sg_real[kHalf], sg_imag[kHalf], sg_power[kHalf];
static UInt32 sg_fill;

static double loadDouble(_Atomic uint64_t *bits) {
    uint64_t raw = atomic_load_explicit(bits, memory_order_relaxed);
    double value;
    memcpy(&value, &raw, sizeof value);
    return value;
}

static void storeDouble(_Atomic uint64_t *bits, double value) {
    uint64_t raw;
    memcpy(&raw, &value, sizeof raw);
    atomic_store_explicit(bits, raw, memory_order_relaxed);
}

// One full frame, as the Music app's analyzer reads it: the power of each bin (unscaled, the first holding the DC and
// Nyquist terms) as a share of the whole, summed over each band, then scaled by the whole's loudness, 20 log10 of it
// over 120, and held to 0 to 1.
static void analyze(double sampleRate) {
    DSPSplitComplex split = {sg_real, sg_imag};
    vDSP_ctoz((const DSPComplex *)sg_frame, 2, &split, 1, kHalf);
    vDSP_fft_zrip(sg_fft, &split, 1, kLog2N, kFFTDirection_Forward);
    vDSP_zvmags(&split, 1, sg_power, 1, kHalf);
    float total = 0;
    vDSP_sve(sg_power, 1, &total, kHalf);
    if (!(total > 0)) return;
    float loudness = 20 * log10f(total) / 120;
    float shares[kBands] = {0};
    for (int k = 0; k < kHalf; k++) {
        float frequency = (float)(k * sampleRate / kN);
        for (int b = 0; b < kBands; b++) {
            if (frequency > kBandEdge[b][0] && frequency <= kBandEdge[b][1]) shares[b] += sg_power[k] / total;
        }
    }
    for (int b = 0; b < kBands; b++) {
        uint32_t bits;
        float level = MIN(1.0f, MAX(0.0f, shares[b] * loudness));
        memcpy(&bits, &level, sizeof bits);
        atomic_store_explicit(&sg_levelBits[b], bits, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&sg_readings, 1, memory_order_release);
}

// `refCon` is the unit; only the music's output is heard, mixed to mono.
static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (!atomic_load_explicit(&sg_wanted, memory_order_relaxed) || !sg_fft) return noErr;
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) return noErr;
    if (!SGPlayerBeginProcessing((AudioUnit)refCon)) return noErr;
    uint64_t layout = atomic_load_explicit(&sg_layout, memory_order_relaxed);
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    bool isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    bool split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    double sampleRate = loadDouble(&sg_sampleRateBits);
    if ((bytes != 2 && bytes != 4) || channels < 1 || sampleRate <= 0 || !SGPCMLayoutFits(data, frames, channels, bytes, split)) {
        SGPlayerEndProcessing();
        return noErr;
    }
    const void *left = data->mBuffers[0].mData, *right = split && channels > 1 ? data->mBuffers[1].mData : left;
    UInt32 stride = split ? 1 : channels, rightOffset = !split && channels > 1 ? 1 : 0;
    for (UInt32 i = 0; i < frames; i++) {
        UInt32 at = i * stride;
        sg_frame[sg_fill++] = 0.5f * (SGPCMReadSample(left, at, bytes, isFloat, fraction) + SGPCMReadSample(right, at + rightOffset, bytes, isFloat, fraction));
        if (sg_fill == kN) {
            analyze(sampleRate);
            sg_fill = 0;
        }
    }
    SGPlayerEndProcessing();
    return noErr;
}

// The output's format, the hardware side the notify's buffers are in; a format it cannot read leaves them alone.
static void readFormat(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    UInt32 bytes = format.mBitsPerChannel / 8;
    BOOL takes = status == noErr && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0 && format.mChannelsPerFrame >= 1
                 && (bytes == 2 || bytes == 4) && ((format.mFormatFlags & kAudioFormatFlagIsFloat) || (format.mFormatFlags & kAudioFormatFlagIsSignedInteger));
    if (!takes) {
        atomic_store(&sg_layout, 0);
        return;
    }
    storeDouble(&sg_sampleRateBits, format.mSampleRate);
    atomic_store(&sg_layout, (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 | (uint64_t)bytes << 48);
}

static void listenTo(AudioUnit unit) {
    if (!unit || !SGPlayerMusicOutputRunning()) return;
    AudioUnitRemoveRenderNotify(unit, rendered, unit);
    readFormat(unit);
    OSStatus status = AudioUnitAddRenderNotify(unit, rendered, unit);
    if (status != noErr) SGLog(@"music spectrum: the render notify could not be added (%d)", (int)status);
}

void SGMusicSpectrumSetWanted(BOOL wanted) {
    atomic_store(&sg_wanted, wanted);
}

uint64_t SGMusicSpectrumRead(float levels[3]) {
    uint64_t readings = atomic_load_explicit(&sg_readings, memory_order_acquire);
    for (int b = 0; b < kBands; b++) {
        uint32_t bits = atomic_load_explicit(&sg_levelBits[b], memory_order_relaxed);
        memcpy(&levels[b], &bits, sizeof bits);
    }
    return readings;
}

%ctor {
    sg_fft = vDSP_create_fftsetup(kLog2N, kFFTRadix2);
    if (!SGPlayerWatchMusicOutput(listenTo)) SGLog(@"music spectrum: Spotify's output cannot be reached");
}
