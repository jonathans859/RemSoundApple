#ifndef REM_OPUS_SHIM_H
#define REM_OPUS_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Non-variadic wrappers over the libopus encoder API. Swift cannot call the C-variadic
 * opus_encoder_ctl(), so every OPUS_SET_* the sender needs is exposed as a fixed-signature
 * function here. The encoder handle is opaque to Swift; all opus types stay inside the .c
 * file so this header needs no opus include. */

typedef struct RemOpusEncoder RemOpusEncoder;

/* Creates an encoder in OPUS_APPLICATION_RESTRICTED_LOWDELAY mode (the mode the Windows
 * sender uses; supports the 2.5/5/10/20 ms frame sizes). Returns NULL on failure and
 * writes the libopus error code to *error when non-NULL. */
RemOpusEncoder *rem_opus_encoder_create(int sample_rate, int channels, int *error);

void rem_opus_encoder_destroy(RemOpusEncoder *encoder);

/* Applies the Windows sender's encoder configuration in one call: bitrate (bits/sec),
 * complexity 0-10, VBR on/off, inband FEC on/off, expected packet loss percent 0-100.
 * Returns OPUS_OK (0) or the first failing ctl's error code. */
int rem_opus_encoder_configure(RemOpusEncoder *encoder,
                               int bitrate,
                               int complexity,
                               int use_vbr,
                               int inband_fec,
                               int packet_loss_percent);

/* Encodes one frame of interleaved float PCM. frame_size is samples PER CHANNEL and must
 * be a legal Opus frame size for the encoder's sample rate. Returns the number of bytes
 * written to out, or a negative libopus error code. */
int rem_opus_encode_float(RemOpusEncoder *encoder,
                          const float *pcm,
                          int frame_size,
                          unsigned char *out,
                          int max_out_bytes);

#ifdef __cplusplus
}
#endif

#endif /* REM_OPUS_SHIM_H */
