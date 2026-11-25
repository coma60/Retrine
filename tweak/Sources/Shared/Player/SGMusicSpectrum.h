// The music's spectrum in three bands, as the Music app's backdrop hears it: each band's share of the spectral power
// of Spotify's output (bass 20-300 Hz, middle 300-3500 Hz, treble 3500-24000 Hz), from an unwindowed 2048-point FFT at 48 kHz,
// scaled by the frame's loudness (20 log10 of its power, over 120) and held to 0 to 1. The Fluid backdrop (Redesigned/Kit/SGRFluidGPU.m) turns these into its contrast, saturation and the
// copies' size, as the Music app does.
//
// Listening is off until someone wants it, and costs nothing then but a check per buffer. Nothing is heard while
// Spotify's output cannot be reached.
//
// Threading: SGMusicSpectrumSetWanted on the main thread; SGMusicSpectrumRead from any thread.
#import <Foundation/Foundation.h>

// Whether anything is reading the spectrum now (the backdrop flowing on screen).
void SGMusicSpectrumSetWanted(BOOL wanted);
// How many readings there have been (0 for none yet), and the levels of one of them, each 0 to 1 (NO for one not yet
// made or long overwritten): a reader takes each reading once, in order, as the Music app's backdrop takes each report.
uint64_t SGMusicSpectrumReadings(void);
BOOL SGMusicSpectrumReading(uint64_t index, float levels[3]);
