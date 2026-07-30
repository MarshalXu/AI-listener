#include "CSherpaShim.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// The approved, hash-locked v1.13.2 ABI header is the single source of truth.
// The product links no sherpa symbols; the release packager copies the runtime
// beside the executable and supplies that bundle-relative path.
#include "../../evidence/AI-4/runtime/sherpa-onnx/sherpa-onnx/c-api/c-api.h"

typedef const SherpaOnnxOnlineRecognizer *(*CreateRecognizerFn)(
    const SherpaOnnxOnlineRecognizerConfig *);
typedef void (*DestroyRecognizerFn)(const SherpaOnnxOnlineRecognizer *);
typedef const SherpaOnnxOnlineStream *(*CreateStreamFn)(
    const SherpaOnnxOnlineRecognizer *);
typedef void (*DestroyStreamFn)(const SherpaOnnxOnlineStream *);
typedef void (*AcceptFn)(const SherpaOnnxOnlineStream *, int32_t, const float *,
                         int32_t);
typedef int32_t (*ReadyFn)(const SherpaOnnxOnlineRecognizer *,
                           const SherpaOnnxOnlineStream *);
typedef void (*DecodeFn)(const SherpaOnnxOnlineRecognizer *,
                         const SherpaOnnxOnlineStream *);
typedef const SherpaOnnxOnlineRecognizerResult *(*ResultFn)(
    const SherpaOnnxOnlineRecognizer *, const SherpaOnnxOnlineStream *);
typedef void (*DestroyResultFn)(const SherpaOnnxOnlineRecognizerResult *);
typedef int32_t (*EndpointFn)(const SherpaOnnxOnlineRecognizer *,
                              const SherpaOnnxOnlineStream *);
typedef void (*ResetFn)(const SherpaOnnxOnlineRecognizer *,
                        const SherpaOnnxOnlineStream *);
typedef void (*FinishedFn)(const SherpaOnnxOnlineStream *);

struct ALSherpaEngine {
  void *library;
  const SherpaOnnxOnlineRecognizer *recognizer;
  const SherpaOnnxOnlineStream *stream;
  CreateRecognizerFn create_recognizer;
  DestroyRecognizerFn destroy_recognizer;
  CreateStreamFn create_stream;
  DestroyStreamFn destroy_stream;
  AcceptFn accept;
  ReadyFn ready;
  DecodeFn decode;
  ResultFn result;
  DestroyResultFn destroy_result;
  EndpointFn endpoint;
  ResetFn reset;
  FinishedFn finished;
};

#define LOAD(field, symbol)                                                   \
  do {                                                                        \
    *(void **)(&engine->field) = dlsym(engine->library, symbol);              \
    if (!engine->field) {                                                      \
      if (status) *status = AL_SHERPA_SYMBOL_UNAVAILABLE;                     \
      al_sherpa_destroy(engine);                                               \
      return NULL;                                                             \
    }                                                                          \
  } while (0)

ALSherpaEngine *al_sherpa_create(const ALSherpaConfig *config,
                                 ALSherpaStatus *status) {
  if (status) *status = AL_SHERPA_OK;
  if (!config || !config->library_path) {
    if (status) *status = AL_SHERPA_LIBRARY_UNAVAILABLE;
    return NULL;
  }
  ALSherpaEngine *engine = calloc(1, sizeof(*engine));
  if (!engine) return NULL;
  engine->library = dlopen(config->library_path, RTLD_NOW | RTLD_LOCAL);
  if (!engine->library) {
    if (status) *status = AL_SHERPA_LIBRARY_UNAVAILABLE;
    free(engine);
    return NULL;
  }
  LOAD(create_recognizer, "SherpaOnnxCreateOnlineRecognizer");
  LOAD(destroy_recognizer, "SherpaOnnxDestroyOnlineRecognizer");
  LOAD(create_stream, "SherpaOnnxCreateOnlineStream");
  LOAD(destroy_stream, "SherpaOnnxDestroyOnlineStream");
  LOAD(accept, "SherpaOnnxOnlineStreamAcceptWaveform");
  LOAD(ready, "SherpaOnnxIsOnlineStreamReady");
  LOAD(decode, "SherpaOnnxDecodeOnlineStream");
  LOAD(result, "SherpaOnnxGetOnlineStreamResult");
  LOAD(destroy_result, "SherpaOnnxDestroyOnlineRecognizerResult");
  LOAD(endpoint, "SherpaOnnxOnlineStreamIsEndpoint");
  LOAD(reset, "SherpaOnnxOnlineStreamReset");
  LOAD(finished, "SherpaOnnxOnlineStreamInputFinished");

  SherpaOnnxOnlineRecognizerConfig c;
  memset(&c, 0, sizeof(c));
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = 80;
  c.model_config.transducer.encoder = config->encoder_path;
  c.model_config.transducer.decoder = config->decoder_path;
  c.model_config.transducer.joiner = config->joiner_path;
  c.model_config.tokens = config->tokens_path;
  c.model_config.num_threads = config->num_threads > 0 ? config->num_threads : 1;
  c.model_config.provider = "cpu";
  c.decoding_method = "greedy_search";
  c.enable_endpoint = 1;
  engine->recognizer = engine->create_recognizer(&c);
  if (!engine->recognizer) {
    if (status) *status = AL_SHERPA_MODEL_UNAVAILABLE;
    al_sherpa_destroy(engine);
    return NULL;
  }
  engine->stream = engine->create_stream(engine->recognizer);
  if (!engine->stream) {
    if (status) *status = AL_SHERPA_STREAM_UNAVAILABLE;
    al_sherpa_destroy(engine);
    return NULL;
  }
  return engine;
}

void al_sherpa_destroy(ALSherpaEngine *engine) {
  if (!engine) return;
  if (engine->stream && engine->destroy_stream)
    engine->destroy_stream(engine->stream);
  if (engine->recognizer && engine->destroy_recognizer)
    engine->destroy_recognizer(engine->recognizer);
  if (engine->library) dlclose(engine->library);
  free(engine);
}

ALSherpaStatus al_sherpa_accept(ALSherpaEngine *engine, int32_t sample_rate,
                                const float *samples, int32_t count) {
  if (!engine || !engine->stream) return AL_SHERPA_STREAM_UNAVAILABLE;
  engine->accept(engine->stream, sample_rate, samples, count);
  while (engine->ready(engine->recognizer, engine->stream))
    engine->decode(engine->recognizer, engine->stream);
  return AL_SHERPA_OK;
}

ALSherpaStatus al_sherpa_finish(ALSherpaEngine *engine) {
  if (!engine || !engine->stream) return AL_SHERPA_STREAM_UNAVAILABLE;
  engine->finished(engine->stream);
  while (engine->ready(engine->recognizer, engine->stream))
    engine->decode(engine->recognizer, engine->stream);
  return AL_SHERPA_OK;
}

char *al_sherpa_copy_text(ALSherpaEngine *engine) {
  if (!engine || !engine->stream) return NULL;
  const SherpaOnnxOnlineRecognizerResult *result =
      engine->result(engine->recognizer, engine->stream);
  if (!result) return NULL;
  char *text = result->text ? strdup(result->text) : NULL;
  engine->destroy_result(result);
  return text;
}

int32_t al_sherpa_is_endpoint(ALSherpaEngine *engine) {
  return engine && engine->stream
             ? engine->endpoint(engine->recognizer, engine->stream)
             : 0;
}

void al_sherpa_reset(ALSherpaEngine *engine) {
  if (engine && engine->stream)
    engine->reset(engine->recognizer, engine->stream);
}

void al_sherpa_free_text(char *text) { free(text); }
