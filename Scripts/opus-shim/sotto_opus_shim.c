#include "sotto_opus_shim.h"
int sotto_opus_encoder_set_bitrate(OpusEncoder *e, opus_int32 v) { return opus_encoder_ctl(e, OPUS_SET_BITRATE(v)); }
int sotto_opus_encoder_set_complexity(OpusEncoder *e, opus_int32 v) { return opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(v)); }
int sotto_opus_encoder_set_inband_fec(OpusEncoder *e, opus_int32 v) { return opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(v)); }
int sotto_opus_encoder_set_packet_loss_perc(OpusEncoder *e, opus_int32 v) { return opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(v)); }
int sotto_opus_encoder_set_dtx(OpusEncoder *e, opus_int32 v) { return opus_encoder_ctl(e, OPUS_SET_DTX(v)); }
int sotto_opus_encoder_set_signal_voice(OpusEncoder *e) { return opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)); }
int sotto_opus_encoder_set_bandwidth_wideband(OpusEncoder *e) { return opus_encoder_ctl(e, OPUS_SET_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND)); }
