// yue2_jni.cpp: JNI bridge between the app (io.github.jooray.localhoststudio.yue2.Yue2Native)
// and the yue2.cpp pipeline.
//
// One call runs one song end to end inside the calling (worker) thread:
//   score (AR, ABC text) -> semantic codes (AR) -> flow matching (NAR) -> VAE
// and writes the result plus stage checkpoints into a job directory:
//   score.abc            written when the score stage finishes
//   tokens.partial.csv   the semantic stream so far, rewritten every second of audio
//   tokens.csv           the complete semantic stream
//   song.mp3 / song.json the audio and its replay request
//   engine.log           everything the engine printed on stderr
// A cover first runs transcribe() on the same directory: the recording to the
// score SheetSage2 hears in it (cover.abc), which the song then takes as its abc.
// A run started on a directory that already holds checkpoints resumes from
// them: a complete stream replays (no AR at all), a partial stream continues
// (the AR writes on from where it stopped), a score skips the planning stage.

#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <sched.h>
#include <strings.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "audio-io.h"
#include "backend.h"
#include "hooks.h"
#include "pipeline.h"

// dr_flac (public domain / MIT-0), vendored: library songs from the desktop app are FLAC.
// The implementation lives in this translation unit only.
#define DR_FLAC_IMPLEMENTATION
#include "vendor/dr_flac.h"

#define TAG "yue2"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ---- audio input: yue2.cpp's audio_read (mp3/wav) plus FLAC via dr_flac ----

// Decode an audio file into yue2.cpp's planar stereo layout [L: T][R: T].
// .flac goes through dr_flac (mono is duplicated, >2 channels keep the first
// two); anything else falls through to audio_read. Returns malloc'd memory the
// caller free()s, like audio_read; NULL on failure.
static float * studio_audio_read(const char * path, int * T, int * sr) {
    *T  = 0;
    *sr = 0;
    size_t n = strlen(path);
    if (n < 5 || strcasecmp(path + n - 5, ".flac") != 0) {
        return audio_read(path, T, sr);
    }
    unsigned int channels = 0, rate = 0;
    drflac_uint64 frames = 0;
    float * inter = drflac_open_file_and_read_pcm_frames_f32(path, &channels, &rate, &frames, nullptr);
    if (!inter || channels == 0 || frames == 0 || frames > (drflac_uint64) INT32_MAX / 2) {
        fprintf(stderr, "[JNI] cannot decode FLAC %s\n", path);
        drflac_free(inter, nullptr);
        return nullptr;
    }
    const int Tn     = (int) frames;
    float *   planar = (float *) malloc((size_t) 2 * Tn * sizeof(float));
    if (!planar) {
        drflac_free(inter, nullptr);
        return nullptr;
    }
    const unsigned int rc = channels > 1 ? 1 : 0;  // right source channel
    for (int t = 0; t < Tn; t++) {
        const float * f = inter + (size_t) t * channels;
        planar[t]      = f[0];
        planar[Tn + t] = f[rc];
    }
    drflac_free(inter, nullptr);
    *T  = Tn;
    *sr = (int) rate;
    return planar;
}

enum Stage {
    STAGE_LOAD     = 0,
    STAGE_SCORE    = 1,
    STAGE_SEMANTIC = 2,
    STAGE_NAR      = 3,
    STAGE_VAE      = 4,
    STAGE_WRITE    = 5,
    STAGE_LISTEN   = 6,  // a cover's recording through the transcriber
};

static std::atomic<bool> g_cancel{ false };
static std::atomic<bool> g_running{ false };

// ---- stderr capture: engine logs go to logcat and to the job log file ----

static std::mutex  g_log_mutex;
static FILE *      g_log_file = nullptr;
static std::string g_last_line;

static void log_line(const std::string & line) {
    __android_log_print(ANDROID_LOG_INFO, TAG, "%s", line.c_str());
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_last_line = line;
    if (g_log_file) {
        fputs(line.c_str(), g_log_file);
        fputc('\n', g_log_file);
        fflush(g_log_file);
    }
}

static void start_stderr_capture() {
    static std::once_flag once;
    std::call_once(once, [] {
        int fds[2];
        if (pipe(fds) != 0) {
            return;
        }
        setvbuf(stderr, nullptr, _IONBF, 0);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        int rd = fds[0];
        std::thread([rd] {
            std::string line;
            char        buf[1024];
            for (;;) {
                ssize_t n = read(rd, buf, sizeof(buf));
                if (n <= 0) {
                    break;
                }
                for (ssize_t i = 0; i < n; i++) {
                    if (buf[i] == '\n' || buf[i] == '\r') {
                        if (!line.empty()) {
                            log_line(line);
                        }
                        line.clear();
                    } else {
                        line.push_back(buf[i]);
                    }
                }
            }
        }).detach();
    });
}

// ---- small file helpers ----

static bool read_file(const std::string & path, std::string * out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    *out = ss.str();
    return true;
}

static bool write_atomic(const std::string & path, const std::string & data) {
    std::string tmp = path + ".tmp";
    FILE *      f   = fopen(tmp.c_str(), "wb");
    if (!f) {
        return false;
    }
    bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
    ok      = (fflush(f) == 0) && ok;
    fsync(fileno(f));
    fclose(f);
    if (!ok) {
        return false;
    }
    return rename(tmp.c_str(), path.c_str()) == 0;
}

static std::string trim(const std::string & s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    size_t b = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

// ---- generation context shared with the hooks ----

struct JobCtx {
    JNIEnv *         env;
    jobject          listener;
    jmethodID        on_progress;
    std::string      dir;
    Yue2Pipeline *   pipeline;
    std::vector<int> base;          // codec values already in hand (continued run)
    int              total_frames;  // the semantic budget in frames
    int              last_saved;
    int              song_frames;   // the whole semantic stream, once known
};

static void report(JobCtx * c, int stage, int cur, int total) {
    if (!c->listener) {
        return;
    }
    c->env->CallVoidMethod(c->listener, c->on_progress, stage, cur, total);
    if (c->env->ExceptionCheck()) {
        c->env->ExceptionClear();
    }
}

static std::string tokens_csv(const std::vector<int> & base, const std::vector<int> & drawn) {
    std::string csv;
    csv.reserve((base.size() + drawn.size()) * 6);
    bool first = true;
    for (int v : base) {
        csv += (first ? "" : ",") + std::to_string(v);
        first = false;
    }
    for (int t : drawn) {
        csv += (first ? "" : ",") + std::to_string(t - YUE2_CODEC_OFFSET);
        first = false;
    }
    return csv;
}

static void hook_ar(void * user, int phase, int step, int max_tokens, const std::vector<int> * tokens) {
    JobCtx * c = (JobCtx *) user;
    if (phase == 0) {
        if (step < 0) {
            BPETokenizer * tok   = store_bpe(c->pipeline->store, c->pipeline->model_path.c_str());
            std::string    score = tok ? bpe_decode(tok, *tokens) : "";
            if (!score.empty() && !write_atomic(c->dir + "/score.abc", score)) {
                LOGE("cannot write score checkpoint");
            }
            report(c, STAGE_SCORE, max_tokens, max_tokens);
        } else if (step % 8 == 0) {
            report(c, STAGE_SCORE, (int) tokens->size(), max_tokens);
        }
        return;
    }
    int have = (int) (c->base.size() + tokens->size());
    if (step < 0) {
        c->song_frames = have;
        if (!write_atomic(c->dir + "/tokens.csv", tokens_csv(c->base, *tokens))) {
            LOGE("cannot write token checkpoint");
        }
        unlink((c->dir + "/tokens.partial.csv").c_str());
        report(c, STAGE_SEMANTIC, c->total_frames, c->total_frames);
        return;
    }
    if (have - c->last_saved >= YUE2_FRAME_RATE) {
        write_atomic(c->dir + "/tokens.partial.csv", tokens_csv(c->base, *tokens));
        c->last_saved = have;
    }
    if (step % 5 == 0) {
        report(c, STAGE_SEMANTIC, have, c->total_frames);
    }
}

static void hook_nar(void * user, int step, int steps) {
    report((JobCtx *) user, STAGE_NAR, step, steps);
}

static void hook_vae(void * user, int tile, int tiles) {
    report((JobCtx *) user, STAGE_VAE, tile, tiles);
}

// A preview partway through flow matching: the guessed clean latents of the whole song through a
// VAE of its own (the store holds the NAR and would refuse a second model group), written to
// preview.wav next to the checkpoints. Songs solved in several chunks get none.
static bool is_cancelled(void *);

static void hook_preview(void * user, const float * latents, int frames) {
    JobCtx * c = (JobCtx *) user;
    if (frames != c->song_frames) {
        return;
    }
    Timer   t;
    VAEGGML vae;
    vae_ggml_load(&vae, c->pipeline->vae_path.c_str());
    std::vector<float> audio;
    int                T_audio = 0;
    bool ok = pipeline_decode(c->pipeline, &vae, latents, frames, &audio, &T_audio, is_cancelled, nullptr);
    vae_ggml_free(&vae);
    if (!ok || T_audio <= 0) {
        fprintf(stderr, "[JNI] Preview decode failed\n");
        return;
    }
    std::string tmp = c->dir + "/preview.tmp.wav";
    if (audio_write(tmp.c_str(), audio.data(), T_audio, YUE2_SAMPLE_RATE, false, WAV_S16, 0, 0)) {
        rename(tmp.c_str(), (c->dir + "/preview.wav").c_str());
        fprintf(stderr, "[JNI] Preview: %.1f s of audio in %.1f s\n", (float) T_audio / YUE2_SAMPLE_RATE,
                t.ms() / 1000.0);
    }
}

// work/latents.f32 (float32 little-endian, frames x 64) and latents.json: the finished mix, so it
// can be refined later without mixing from scratch. Same layout as the desktop engine.
static void write_latents(const std::string & dir, const Yue2Song & song, int steps, long long seed) {
    std::string bin((const char *) song.latents.data(), song.latents.size() * sizeof(float));
    write_atomic(dir + "/latents.f32", bin);
    write_atomic(dir + "/latents.json", "{\"frames\": " + std::to_string(song.T_lat) + ", \"dim\": " +
                                            std::to_string(YUE2_LATENT_DIM) + ", \"steps\": " +
                                            std::to_string(steps) + ", \"seed\": " + std::to_string(seed) + "}");
}

static bool is_cancelled(void *) {
    return g_cancel.load();
}

// Pin the calling thread (and every ggml worker it spawns, which inherit the
// mask) to the given cores.
static void pin_to_cores(JNIEnv * env, jintArray cores) {
    if (!cores) {
        return;
    }
    jsize n = env->GetArrayLength(cores);
    if (n <= 0) {
        return;
    }
    std::vector<jint> ids(n);
    env->GetIntArrayRegion(cores, 0, n, ids.data());
    cpu_set_t set;
    CPU_ZERO(&set);
    std::string list;
    for (jint id : ids) {
        if (id >= 0 && id < CPU_SETSIZE) {
            CPU_SET(id, &set);
            list += std::to_string(id) + " ";
        }
    }
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        LOGE("sched_setaffinity failed: %s", strerror(errno));
    } else {
        LOGI("pinned to cores %s", list.c_str());
    }
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_generate(JNIEnv *   env,
                                                                                               jclass,
                                                                                               jstring    j_dir,
                                                                                               jstring    j_model,
                                                                                               jstring    j_vae,
                                                                                               jstring    j_request,
                                                                                               jint       n_threads,
                                                                                               jintArray  cores,
                                                                                               jint       max_seq,
                                                                                               jstring    j_parent_audio,
                                                                                               jdouble    splice_at,
                                                                                               jdouble    crossfade_s,
                                                                                               jobject    listener) {
    bool expected = false;
    if (!g_running.compare_exchange_strong(expected, true)) {
        return -2;  // busy
    }
    g_cancel = false;
    start_stderr_capture();

    auto jstr = [env](jstring s) {
        const char * c = env->GetStringUTFChars(s, nullptr);
        std::string  r(c);
        env->ReleaseStringUTFChars(s, c);
        return r;
    };
    std::string dir     = jstr(j_dir);
    std::string model   = jstr(j_model);
    std::string vae     = jstr(j_vae);
    std::string reqjson = jstr(j_request);
    std::string parent  = j_parent_audio ? jstr(j_parent_audio) : "";

    {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        g_log_file = fopen((dir + "/engine.log").c_str(), "a");
    }
    auto finish = [&](int code) {
        fflush(stderr);
        usleep(200 * 1000);  // let the reader thread drain the pipe
        std::lock_guard<std::mutex> lock(g_log_mutex);
        if (g_log_file) {
            fclose(g_log_file);
            g_log_file = nullptr;
        }
        g_running = false;
        return code;
    };

    pin_to_cores(env, cores);
    g_yue2_n_threads = n_threads > 0 ? n_threads : 0;

    Yue2Request r;
    request_init(&r);
    if (!request_parse_json(&r, reqjson.c_str())) {
        fprintf(stderr, "[JNI] FATAL: bad request JSON\n");
        return finish(-1);
    }
    request_resolve_seed(&r);
    const bool extend_job = !r.source_tokens.empty();
    r.lm_batch_size    = 1;
    r.synth_batch_size = 1;

    JobCtx ctx       = {};
    ctx.env          = env;
    ctx.listener     = listener;
    ctx.on_progress  = listener ? env->GetMethodID(env->GetObjectClass(listener), "onProgress", "(III)V") : nullptr;
    ctx.dir          = dir;
    ctx.total_frames = std::min(r.semantic_sampling.max_tokens,
                                r.duration > 0 ? (int) (r.duration * (float) YUE2_FRAME_RATE) : 1 << 30);

    // Resume from checkpoints
    std::string score, tokens, partial;
    bool        has_score = read_file(dir + "/score.abc", &score) && !trim(score).empty();
    bool        has_tok   = read_file(dir + "/tokens.csv", &tokens) && !trim(tokens).empty();
    bool        has_part  = read_file(dir + "/tokens.partial.csv", &partial) && !trim(partial).empty();
    bool        cot_off   = r.cot == "off";
    if (has_score && !cot_off) {
        r.abc = score;
    }
    // A fresh extend job: the codes in hand are the source section
    if (!r.source_tokens.empty()) {
        std::vector<int> src;
        if (pipeline_parse_tokens(r.source_tokens, &src)) {
            const int T_src = (int) src.size();
            const int a     = std::clamp((int) lroundf(r.source_start * YUE2_FRAME_RATE), 0, T_src);
            const int b     = r.source_end < 0.0f ? T_src
                                                  : std::clamp((int) lroundf(r.source_end * YUE2_FRAME_RATE), 0, T_src);
            if (b > a) {
                ctx.base.assign(src.begin() + a, src.begin() + b);
            }
        }
    }
    if (has_tok) {
        r.source_tokens = "";
        ctx.base.clear();
        r.semantic_tokens = trim(tokens);
        std::vector<int> values;
        if (pipeline_parse_tokens(r.semantic_tokens, &values)) {
            ctx.song_frames = (int) values.size();
        }
        fprintf(stderr, "[JNI] Resume: complete semantic stream, replaying\n");
    } else if (has_part && (has_score || cot_off)) {
        std::vector<int> values;
        if (pipeline_parse_tokens(partial, &values)) {
            if ((int) values.size() + 1 >= ctx.total_frames) {
                r.semantic_tokens = trim(partial);
                r.source_tokens   = "";
                ctx.base.clear();
                write_atomic(dir + "/tokens.csv", r.semantic_tokens);
                fprintf(stderr, "[JNI] Resume: partial stream already at budget, replaying %zu frames\n",
                        values.size());
            } else {
                ctx.base        = values;
                r.source_tokens = trim(partial);
                r.source_start  = 0.0f;
                r.source_end    = -1.0f;
                fprintf(stderr, "[JNI] Resume: continuing from %zu frames\n", values.size());
            }
        }
    } else if (has_score && !cot_off) {
        fprintf(stderr, "[JNI] Resume: reusing the planned score\n");
    }
    ctx.last_saved = (int) ctx.base.size();

    report(&ctx, STAGE_LOAD, 0, 1);

    Yue2PipelineParams params;
    params.max_seq = max_seq > 0 ? max_seq : 0;

    ModelStore * store = store_create(EVICT_STRICT);
    Yue2Pipeline pipeline;
    pipeline.store = store;
    ctx.pipeline   = &pipeline;
    if (!pipeline_configure(&pipeline, model.c_str(), vae.c_str(), params)) {
        store_free(store);
        return finish(-1);
    }

    g_yue2_hooks.ar_step  = hook_ar;
    g_yue2_hooks.nar_step = hook_nar;
    g_yue2_hooks.vae_tile = hook_vae;
    g_yue2_hooks.user     = &ctx;

    // Refine: refine.f32 (the source mix's latents) and refine.json ({"t": 0.25}) in the job dir
    std::vector<float> refine;
    std::string        refine_bin, refine_info;
    if (read_file(dir + "/refine.f32", &refine_bin) && read_file(dir + "/refine.json", &refine_info)) {
        refine.resize(refine_bin.size() / sizeof(float));
        memcpy(refine.data(), refine_bin.data(), refine.size() * sizeof(float));
        float  t   = 0.25f;
        size_t pos = refine_info.find("\"t\"");
        if (pos != std::string::npos) {
            t = strtof(refine_info.c_str() + refine_info.find(':', pos) + 1, nullptr);
        }
        const int frames = (int) (refine.size() / YUE2_LATENT_DIM);
        if (frames == ctx.song_frames && t > 0.0f && t < 1.0f) {
            g_yue2_hooks.refine_latents = refine.data();
            g_yue2_hooks.refine_frames  = frames;
            g_yue2_hooks.refine_t       = t;
            fprintf(stderr, "[JNI] Refine: %d frames from t=%.2f (%d of %d steps)\n", frames, t,
                    yue2_solve_steps(r.steps), r.steps);
        } else {
            fprintf(stderr, "[JNI] FATAL: refine latents have %d frames, the song %d\n", frames, ctx.song_frames);
            pipeline_free(&pipeline);
            store_free(store);
            g_yue2_hooks = Yue2Hooks{};
            return finish(-1);
        }
    } else if (!extend_job && r.steps >= 16) {
        // A quarter of the way into a long mix, a preview to judge the song by
        g_yue2_hooks.nar_preview  = hook_preview;
        g_yue2_hooks.preview_step = r.steps / 4;
    }

    std::vector<Yue2Song> songs;
    bool                  ok = pipeline_generate(&pipeline, r, &songs, is_cancelled, nullptr);
    g_yue2_hooks          = Yue2Hooks{};
    pipeline_free(&pipeline);
    store_free(store);

    if (!ok || songs.empty()) {
        return finish(g_cancel.load() ? 1 : -1);
    }

    report(&ctx, STAGE_WRITE, 0, 1);
    Yue2Song & song    = songs[0];
    bool       is_mp3  = true;
    WavFormat  wav_fmt = WAV_S16;
    audio_parse_format(r.output_format.c_str(), is_mp3, wav_fmt);
    std::string out = dir + (is_mp3 ? "/song.mp3" : "/song.wav");
    const int   S   = (int) lround(splice_at * YUE2_FRAME_RATE) * YUE2_HOP;  // splice point, frame aligned
    std::vector<float> base_audio;
    int                T_base = 0;
    if (!parent.empty() && S > 0) {
        int     sr     = 0;
        float * planar = studio_audio_read(parent.c_str(), &T_base, &sr);
        if (planar && sr > 0 && sr != YUE2_SAMPLE_RATE) {
            // The parent was rendered or exported at another rate: bring it to the engine rate.
            int     T_rs = 0;
            float * rs   = audio_resample(planar, T_base, sr, YUE2_SAMPLE_RATE, 2, &T_rs);
            fprintf(stderr, "[JNI] Resampled parent %d Hz -> %d Hz (%d -> %d samples)\n", sr, YUE2_SAMPLE_RATE,
                    T_base, T_rs);
            free(planar);
            planar = rs;
            T_base = rs ? T_rs : 0;
            sr     = rs ? YUE2_SAMPLE_RATE : sr;
        }
        if (planar && sr == YUE2_SAMPLE_RATE && T_base >= S) {
            base_audio.assign(planar, planar + (size_t) 2 * T_base);
        } else {
            fprintf(stderr, "[JNI] WARNING: cannot splice onto %s (sr %d, %d samples), keeping the full render\n",
                    parent.c_str(), sr, T_base);
        }
        free(planar);
    }
    if (!base_audio.empty()) {
        // Raw re-render of section + extension first (normalizes in place, so
        // both sides of the crossfade sit at the same loudness as the parent)
        std::string full = dir + (is_mp3 ? "/song_full.mp3" : "/song_full.wav");
        if (!audio_write(full.c_str(), song.audio.data(), song.T_audio, YUE2_SAMPLE_RATE, is_mp3, wav_fmt,
                         r.mp3_bitrate, r.peak_clip)) {
            fprintf(stderr, "[JNI] FATAL: cannot write %s\n", full.c_str());
            return finish(-1);
        }
        // parent[0, S) + equal-power crossfade over F samples + render[F, ...)
        const int R = song.T_audio;
        const int XF = (int) lround((crossfade_s > 0 ? crossfade_s : 2.0) * YUE2_SAMPLE_RATE);
        int       F  = std::min({ XF, R, T_base - S });
        F           = std::max(F, 0);
        const int T = S + R;
        std::vector<float> mix((size_t) 2 * T);
        for (int c = 0; c < 2; c++) {
            const float * pa  = base_audio.data() + (size_t) c * T_base;
            const float * ra  = song.audio.data() + (size_t) c * R;
            float *       dst = mix.data() + (size_t) c * T;
            memcpy(dst, pa, (size_t) S * sizeof(float));
            for (int t = 0; t < F; t++) {
                double th  = (double) t / (double) F * M_PI / 2.0;
                dst[S + t] = (float) (pa[S + t] * cos(th) + ra[t] * sin(th));
            }
            memcpy(dst + S + F, ra + F, (size_t) (R - F) * sizeof(float));
        }
        fprintf(stderr, "[JNI] Spliced at %.2f s with a %.2f s crossfade: %.1f s total\n",
                (double) S / YUE2_SAMPLE_RATE, (double) F / YUE2_SAMPLE_RATE, (double) T / YUE2_SAMPLE_RATE);
        if (!audio_write(out.c_str(), mix.data(), T, YUE2_SAMPLE_RATE, is_mp3, wav_fmt, r.mp3_bitrate, 0)) {
            fprintf(stderr, "[JNI] FATAL: cannot write %s\n", out.c_str());
            return finish(-1);
        }
    } else if (!audio_write(out.c_str(), song.audio.data(), song.T_audio, YUE2_SAMPLE_RATE, is_mp3, wav_fmt,
                            r.mp3_bitrate, r.peak_clip)) {
        fprintf(stderr, "[JNI] FATAL: cannot write %s\n", out.c_str());
        return finish(-1);
    }
    std::string stream = pipeline_format_tokens(song.tokens);
    write_atomic(dir + "/tokens.csv", stream);
    if (!song.score.empty()) {
        write_atomic(dir + "/score.abc", song.score);
    }
    if (!extend_job && parent.empty()) {
        write_latents(dir, song, r.steps, (long long) r.seed);
    }
    unlink((dir + "/preview.wav").c_str());
    Yue2Request replay = request_replay(r, song.score.empty() ? r.abc : song.score, stream, 0, 0);
    write_atomic(dir + "/song.json", request_to_json(&replay) + "\n");
    fprintf(stderr, "[JNI] Done: %.1f s of audio -> %s\n", (float) song.T_audio / (float) YUE2_SAMPLE_RATE,
            out.c_str());
    report(&ctx, STAGE_WRITE, 1, 1);
    return finish(0);
}

// A recording to its ABC score (SheetSage2, MERT beside the transcriber GGUF),
// written to <dir>/cover.abc. melody_only drops the chord symbols.
extern "C" JNIEXPORT jint JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_transcribe(JNIEnv *  env,
                                                                                                 jclass,
                                                                                                 jstring   j_dir,
                                                                                                 jstring   j_model,
                                                                                                 jstring   j_audio,
                                                                                                 jboolean  melody_only,
                                                                                                 jint      n_threads,
                                                                                                 jintArray cores,
                                                                                                 jobject   listener) {
    bool expected = false;
    if (!g_running.compare_exchange_strong(expected, true)) {
        return -2;  // busy
    }
    g_cancel = false;
    start_stderr_capture();
    auto jstr = [env](jstring s) {
        const char * c = env->GetStringUTFChars(s, nullptr);
        std::string  r(c);
        env->ReleaseStringUTFChars(s, c);
        return r;
    };
    std::string dir   = jstr(j_dir);
    std::string model = jstr(j_model);
    std::string audio = jstr(j_audio);
    {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        g_log_file = fopen((dir + "/engine.log").c_str(), "a");
    }
    auto finish = [&](int code) {
        fflush(stderr);
        usleep(200 * 1000);  // let the reader thread drain the pipe
        std::lock_guard<std::mutex> lock(g_log_mutex);
        if (g_log_file) {
            fclose(g_log_file);
            g_log_file = nullptr;
        }
        g_running = false;
        return code;
    };
    JobCtx ctx      = {};
    ctx.env         = env;
    ctx.listener    = listener;
    ctx.on_progress = listener ? env->GetMethodID(env->GetObjectClass(listener), "onProgress", "(III)V") : nullptr;
    report(&ctx, STAGE_LISTEN, 0, 1);

    pin_to_cores(env, cores);
    g_yue2_n_threads = n_threads > 0 ? n_threads : 0;

    int     T = 0, sr = 0;
    float * planar = studio_audio_read(audio.c_str(), &T, &sr);
    std::vector<float> mono;
    bool               read_ok = planar && mert_mono_24k(planar, T, sr, &mono);
    if (!read_ok) {
        fprintf(stderr, "[JNI] FATAL: cannot read %s\n", audio.c_str());
        return finish(-1);
    }
    SheetSage2 m;
    if (!ss2_load(&m, model.c_str())) {
        return finish(-1);
    }
    std::string abc, error;
    DebugDumper dbg;
    debug_init(&dbg, nullptr);
    bool ok = ss2_transcribe(&m, mono.data(), (int) mono.size(), melody_only, &abc, &error, &dbg);
    ss2_free(&m);
    if (g_cancel.load()) {
        return finish(1);
    }
    if (!ok || trim(abc).empty()) {
        fprintf(stderr, "[JNI] FATAL: transcription failed: %s\n", error.empty() ? "no score" : error.c_str());
        return finish(-1);
    }
    if (!write_atomic(dir + "/cover.abc", abc)) {
        fprintf(stderr, "[JNI] FATAL: cannot write %s/cover.abc\n", dir.c_str());
        return finish(-1);
    }
    fprintf(stderr, "[JNI] Transcribed %s: %.1f s, %zu bytes of score\n", audio.c_str(),
            (double) mono.size() / MERT_SAMPLE_RATE, abc.size());
    report(&ctx, STAGE_LISTEN, 1, 1);
    return finish(0);
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_cancel(JNIEnv *, jclass) {
    g_cancel = true;
}

extern "C" JNIEXPORT jstring JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_lastLogLine(JNIEnv * env,
                                                                                                     jclass) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    return env->NewStringUTF(g_last_line.c_str());
}

extern "C" JNIEXPORT jstring JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_systemInfo(JNIEnv * env,
                                                                                                    jclass) {
    std::string info = "ggml CPU backend";
#if defined(__ARM_FEATURE_DOTPROD)
    info += " +dotprod";
#endif
#if defined(__ARM_FEATURE_MATMUL_INT8)
    info += " +i8mm";
#endif
#if defined(__ARM_FEATURE_FP16_VECTOR_ARITHMETIC)
    info += " +fp16";
#endif
#if defined(YUE2_WITH_VULKAN)
    info += ", Vulkan compiled in";
#endif
    return env->NewStringUTF(info.c_str());
}

// Decode an audio file (mp3/wav/flac) and write it as 24-bit WAV (sharing in another format).
extern "C" JNIEXPORT jboolean JNICALL Java_io_github_jooray_localhoststudio_yue2_Yue2Native_convertToWav(JNIEnv * env,
                                                                                                        jclass,
                                                                                                        jstring j_src,
                                                                                                        jstring j_dst) {
    const char * src = env->GetStringUTFChars(j_src, nullptr);
    const char * dst = env->GetStringUTFChars(j_dst, nullptr);
    int     T = 0, sr = 0;
    float * planar = studio_audio_read(src, &T, &sr);
    bool    ok     = planar && audio_write_wav(dst, planar, T, sr, WAV_S24);
    free(planar);
    env->ReleaseStringUTFChars(j_src, src);
    env->ReleaseStringUTFChars(j_dst, dst);
    return ok ? JNI_TRUE : JNI_FALSE;
}
