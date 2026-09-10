#ifndef SOTTO_OPUS_SHIM_H
#define SOTTO_OPUS_SHIM_H
#include <opus/opus.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Non-variadic wrappers around opus_encoder_ctl so Swift can call them. */
int sotto_opus_encoder_set_bitrate(OpusEncoder *enc, opus_int32 bitrate);
int sotto_opus_encoder_set_complexity(OpusEncoder *enc, opus_int32 complexity);
int sotto_opus_encoder_set_inband_fec(OpusEncoder *enc, opus_int32 enabled);
int sotto_opus_encoder_set_packet_loss_perc(OpusEncoder *enc, opus_int32 percent);
int sotto_opus_encoder_set_dtx(OpusEncoder *enc, opus_int32 enabled);
int sotto_opus_encoder_set_signal_voice(OpusEncoder *enc);
int sotto_opus_encoder_set_bandwidth_wideband(OpusEncoder *enc);
#ifdef __cplusplus
}
#endif
#endif
