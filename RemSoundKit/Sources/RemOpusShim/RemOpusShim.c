#include "include/RemOpusShim.h"

#include <opus.h>
#include <stdlib.h>

/* RemOpusEncoder is just OpusEncoder under an opaque name the header can forward-declare
 * without pulling opus.h into Swift's view. */

RemOpusEncoder *rem_opus_encoder_create(int sample_rate, int channels, int *error)
{
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(sample_rate, channels,
                                           OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err);
    if (error != NULL) {
        *error = err;
    }
    if (err != OPUS_OK) {
        return NULL;
    }
    return (RemOpusEncoder *)enc;
}

void rem_opus_encoder_destroy(RemOpusEncoder *encoder)
{
    if (encoder != NULL) {
        opus_encoder_destroy((OpusEncoder *)encoder);
    }
}

int rem_opus_encoder_configure(RemOpusEncoder *encoder,
                               int bitrate,
                               int complexity,
                               int use_vbr,
                               int inband_fec,
                               int packet_loss_percent)
{
    OpusEncoder *enc = (OpusEncoder *)encoder;
    int err;
    err = opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_VBR(use_vbr ? 1 : 0));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(inband_fec ? 1 : 0));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(packet_loss_percent));
    return err;
}

int rem_opus_encode_float(RemOpusEncoder *encoder,
                          const float *pcm,
                          int frame_size,
                          unsigned char *out,
                          int max_out_bytes)
{
    return opus_encode_float((OpusEncoder *)encoder, pcm, frame_size, out, max_out_bytes);
}
