#ifndef CSHERPA_SHIM_H
#define CSHERPA_SHIM_H

#include <stdint.h>

typedef struct ALSherpaEngine ALSherpaEngine;

typedef struct {
  const char *library_path;
  const char *encoder_path;
  const char *decoder_path;
  const char *joiner_path;
  const char *tokens_path;
  int32_t num_threads;
} ALSherpaConfig;

typedef enum {
  AL_SHERPA_OK = 0,
  AL_SHERPA_LIBRARY_UNAVAILABLE = 1,
  AL_SHERPA_SYMBOL_UNAVAILABLE = 2,
  AL_SHERPA_MODEL_UNAVAILABLE = 3,
  AL_SHERPA_STREAM_UNAVAILABLE = 4
} ALSherpaStatus;

ALSherpaEngine *al_sherpa_create(const ALSherpaConfig *config,
                                 ALSherpaStatus *status);
void al_sherpa_destroy(ALSherpaEngine *engine);
ALSherpaStatus al_sherpa_accept(ALSherpaEngine *engine, int32_t sample_rate,
                                const float *samples, int32_t count);
ALSherpaStatus al_sherpa_finish(ALSherpaEngine *engine);
char *al_sherpa_copy_text(ALSherpaEngine *engine);
int32_t al_sherpa_is_endpoint(ALSherpaEngine *engine);
void al_sherpa_reset(ALSherpaEngine *engine);
void al_sherpa_free_text(char *text);

#endif
