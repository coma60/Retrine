// The music's spectrum in three bands (SGMusicSpectrum.h).
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/SGPCMRead.h"
#import "SGMusicSpectrum.h"

enum { kLog2N = 10, kN = 1 << kLog2N, kHalf = kN / 2, kBands = 3 };
// The Music app's bands, in hertz: each a lower and an upper edge (a bin counts when lower < its frequency <= upper).
static const float kBandEdge[kBands][2] = {{20, 300}, {300, 3500}, {3500, 24000}};
// A share is stale this long after it was heard.
static const double kFresh = 0.5;

static atomic_bool sg_wanted;
static _Atomic uint64_t sg_layout;              // format flags | channels << 32 | bytes << 48, 0 for none
static _Atomic uint64_t sg_sampleRateBits;
static _Atomic uint32_t sg_shareBits[kBands];
static _Atomic uint64_t sg_heardAt;             // mach time of the newest shares
static double sg_secondsPerTick;

// Render-thread state: only the notify touches it, under the output's admission.
static FFTSetup sg_fft;
static float sg_window[kN], sg_frame[kN], sg_real[kHalf], sg_imag[kHalf], sg_power[kHalf];
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

// One full frame: the power of each bin as a share of the whole, summed over each band.
static void analyze(double sampleRate) {
    vDSP_vmul(sg_frame, 1, sg_window, 1, sg_frame, 1, kN);
    DSPSplitComplex split = {sg_real, sg_imag};
    vDSP_ctoz((const DSPComplex *)sg_frame, 2, &split, 1, kHalf);
    vDSP_fft_zrip(sg_fft, &split, 1, kLog2N, kFFTDirection_Forward);
    sg_imag[0] = 0;   // the Nyquist bin packed there is left out
    vDSP_zvmags(&split, 1, sg_power, 1, kHalf);
    float total = 0;
    vDSP_sve(sg_power, 1, &total, kHalf);
    if (!(total > 0)) return;
    float shares[kBands] = {0};
    for (int k = 1; k < kHalf; k++) {
        float frequency = (float)(k * sampleRate / kN);
        for (int b = 0; b < kBands; b++) {
            if (frequency > kBandEdge[b][0] && frequency <= kBandEdge[b][1]) shares[b] += sg_power[k] / total;
        }
    }
    for (int b = 0; b < kBands; b++) {
        uint32_t bits;
        float share = MIN(1.0f, MAX(0.0f, shares[b]));
        memcpy(&bits, &share, sizeof bits);
        atomic_store_explicit(&sg_shareBits[b], bits, memory_order_relaxed);
    }
    atomic_store_explicit(&sg_heardAt, mach_absolute_time(), memory_order_relaxed);
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

BOOL SGMusicSpectrumRead(float shares[3]) {
    uint64_t heard = atomic_load_explicit(&sg_heardAt, memory_order_relaxed);
    BOOL fresh = heard && (mach_absolute_time() - heard) * sg_secondsPerTick < kFresh;
    for (int b = 0; b < kBands; b++) {
        uint32_t bits = atomic_load_explicit(&sg_shareBits[b], memory_order_relaxed);
        float share;
        memcpy(&share, &bits, sizeof share);
        shares[b] = fresh ? share : 0;
    }
    return fresh;
}

%ctor {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    sg_fft = vDSP_create_fftsetup(kLog2N, kFFTRadix2);
    // A Hann window, so a frame's edges do not spread power across the bands.
    vDSP_hann_window(sg_window, kN, vDSP_HANN_NORM);
    if (!SGPlayerWatchMusicOutput(listenTo)) SGLog(@"music spectrum: Spotify's output cannot be reached");
}
