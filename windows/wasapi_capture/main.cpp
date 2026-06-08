// wasapi_capture: captures system audio (loopback) + microphone via WASAPI,
// mixes them, and writes s16le PCM to stdout (default) or a named pipe (-o flag).
// Usage: wasapi_capture.exe [-o \\.\pipe\<name>]
// Pipe mode: writes "WASAPI_RATE:<hz>\n" to stderr, then PCM to the named pipe.
// Stdout mode: writes 4-byte LE sample-rate header, then s16le stereo PCM.

#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <fcntl.h>
#include <io.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winmm.lib")

constexpr UINT32 kOutChannels = 2;
constexpr size_t kChunkFrames = 960; // 20ms worth of frames

// Actual sample rate is read from the loopback device's mix format at startup.
UINT32 g_sampleRate = 48000;

std::atomic<bool> g_running{true};

// Thread-safe PCM queue (interleaved stereo s16le).
// firstQpc holds the QPC timestamp (100-ns units) of the very first packet
// received by this queue; used to align loopback with microphone timing.
struct AudioQueue {
    std::mutex mtx;
    std::deque<int16_t> buf;
    UINT64 firstQpc{0};

    void push(const int16_t* data, size_t samples, UINT64 qpc) {
        std::lock_guard<std::mutex> lk(mtx);
        if (firstQpc == 0) firstQpc = qpc;
        buf.insert(buf.end(), data, data + samples);
    }

    void pushSilence(size_t samples, UINT64 qpc) {
        std::lock_guard<std::mutex> lk(mtx);
        if (firstQpc == 0) firstQpc = qpc;
        buf.insert(buf.end(), samples, 0);
    }

    bool pop(int16_t* out, size_t samples) {
        std::lock_guard<std::mutex> lk(mtx);
        if (buf.size() < samples) return false;
        for (size_t i = 0; i < samples; i++) {
            out[i] = buf.front();
            buf.pop_front();
        }
        return true;
    }

    UINT64 getFirstQpc() {
        std::lock_guard<std::mutex> lk(mtx);
        return firstQpc;
    }
};

AudioQueue g_loopback;
AudioQueue g_mic;

// -- Format helpers ----------------------------------------------------------

static inline int16_t floatToS16(float f) {
    f = std::clamp(f, -1.0f, 1.0f);
    return static_cast<int16_t>(f * 32767.0f);
}

// Determine if the WAVEFORMATEX (or EXTENSIBLE) is IEEE float.
static bool isIeeeFloat(const WAVEFORMATEX* wf) {
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT GUID
        static const GUID kIeeeFloat = {
            0x00000003, 0x0000, 0x0010,
            {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
        return IsEqualGUID(ext->SubFormat, kIeeeFloat);
    }
    return false;
}

// Convert one buffer of WASAPI PCM frames to s16le stereo.
// Handles: float32, pcm16, pcm32, pcm24. Mono is duplicated to stereo.
static void convertToS16Stereo(const BYTE*        src,
                                UINT32             numFrames,
                                const WAVEFORMATEX* wf,
                                std::vector<int16_t>& out) {
    const bool   isFloat    = isIeeeFloat(wf);
    const WORD   ch         = wf->nChannels;
    const WORD   bits       = wf->wBitsPerSample;
    const UINT32 blockAlign = wf->nBlockAlign;

    out.resize(numFrames * kOutChannels);

    for (UINT32 i = 0; i < numFrames; i++) {
        const BYTE* frame = src + (size_t)i * blockAlign;
        float L = 0.0f, R = 0.0f;

        if (isFloat && bits == 32) {
            L = reinterpret_cast<const float*>(frame)[0];
            R = (ch >= 2) ? reinterpret_cast<const float*>(frame)[1] : L;
        } else if (!isFloat && bits == 16) {
            L = reinterpret_cast<const int16_t*>(frame)[0] / 32768.0f;
            R = (ch >= 2) ? reinterpret_cast<const int16_t*>(frame)[1] / 32768.0f : L;
        } else if (!isFloat && bits == 32) {
            L = reinterpret_cast<const int32_t*>(frame)[0] / 2147483648.0f;
            R = (ch >= 2) ? reinterpret_cast<const int32_t*>(frame)[1] / 2147483648.0f : L;
        } else if (!isFloat && bits == 24) {
            // 24-bit little-endian packed
            int32_t rawL = (frame[2] << 16) | (frame[1] << 8) | frame[0];
            if (rawL & 0x800000) rawL |= 0xFF000000;
            L = rawL / 8388608.0f;
            if (ch >= 2) {
                int32_t rawR = (frame[5] << 16) | (frame[4] << 8) | frame[3];
                if (rawR & 0x800000) rawR |= 0xFF000000;
                R = rawR / 8388608.0f;
            } else {
                R = L;
            }
        }

        out[i * 2]     = floatToS16(L);
        out[i * 2 + 1] = floatToS16(R);
    }
}

// -- Device sample rate query ------------------------------------------------

// Returns the mix format sample rate of the default render endpoint.
static UINT32 queryLoopbackSampleRate() {
    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice*           device     = nullptr;
    IAudioClient*        client     = nullptr;
    WAVEFORMATEX*        wf         = nullptr;
    UINT32               rate       = 48000; // safe fallback

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                   CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                   reinterpret_cast<void**>(&enumerator))) &&
        SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) &&
        SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                   nullptr, reinterpret_cast<void**>(&client))) &&
        SUCCEEDED(client->GetMixFormat(&wf))) {
        rate = wf->nSamplesPerSec;
    }

    if (wf)         CoTaskMemFree(wf);
    if (client)     client->Release();
    if (device)     device->Release();
    if (enumerator) enumerator->Release();
    CoUninitialize();
    return rate;
}

// -- Capture thread ----------------------------------------------------------

static void captureThread(bool loopback) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice*           device     = nullptr;
    IAudioClient*        client     = nullptr;
    IAudioCaptureClient* capture    = nullptr;
    WAVEFORMATEX*        wf         = nullptr;

    auto cleanup = [&] {
        if (wf)         CoTaskMemFree(wf);
        if (capture)    capture->Release();
        if (client)     client->Release();
        if (device)     device->Release();
        if (enumerator) enumerator->Release();
        CoUninitialize();
    };

    HRESULT hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr)) { cleanup(); return; }

    hr = loopback
        ? enumerator->GetDefaultAudioEndpoint(eRender,  eConsole, &device)
        : enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    if (FAILED(hr)) { cleanup(); return; }

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&client));
    if (FAILED(hr)) { cleanup(); return; }

    hr = client->GetMixFormat(&wf);
    if (FAILED(hr)) { cleanup(); return; }

    DWORD streamFlags = loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags,
                            10000000 /* 1s buffer */, 0, wf, nullptr);
    if (FAILED(hr)) { cleanup(); return; }

    hr = client->GetService(__uuidof(IAudioCaptureClient),
                            reinterpret_cast<void**>(&capture));
    if (FAILED(hr)) { cleanup(); return; }

    client->Start();

    AudioQueue& queue = loopback ? g_loopback : g_mic;
    std::vector<int16_t> converted;

    while (g_running) {
        UINT32 packetSize = 0;
        if (FAILED(capture->GetNextPacketSize(&packetSize))) break;

        while (packetSize > 0) {
            BYTE*  data      = nullptr;
            UINT32 numFrames = 0;
            DWORD  flags     = 0;
            UINT64 qpcPos    = 0;

            if (FAILED(capture->GetBuffer(&data, &numFrames, &flags,
                                          nullptr, &qpcPos)))
                break;

            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                queue.pushSilence(numFrames * kOutChannels, qpcPos);
            } else if (numFrames > 0) {
                convertToS16Stereo(data, numFrames, wf, converted);
                queue.push(converted.data(), converted.size(), qpcPos);
            }

            capture->ReleaseBuffer(numFrames);

            if (FAILED(capture->GetNextPacketSize(&packetSize))) goto done;
        }
        Sleep(5);
    }
done:
    client->Stop();
    cleanup();
}

// -- Main --------------------------------------------------------------------

int main(int argc, char* argv[]) {
    _setmode(_fileno(stdout), _O_BINARY);

    // Parse optional -o <pipe_name> for named pipe output mode.
    const char* pipeOutput = nullptr;
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], "-o") == 0) {
            pipeOutput = argv[i + 1];
            break;
        }
    }

    g_sampleRate = queryLoopbackSampleRate();

    HANDLE hPipe = INVALID_HANDLE_VALUE;

    if (pipeOutput != nullptr) {
        hPipe = CreateNamedPipeA(
            pipeOutput,
            PIPE_ACCESS_OUTBOUND,
            PIPE_TYPE_BYTE | PIPE_WAIT,
            1,      // max instances
            65536,  // output buffer size
            0, 0,   // input buffer size, default timeout
            nullptr
        );
        if (hPipe == INVALID_HANDLE_VALUE) return 1;
        // Pipe exists — signal Dart with the sample rate so it can start FFmpeg.
        fprintf(stderr, "WASAPI_RATE:%u\n", g_sampleRate);
        fflush(stderr);
    } else {
        // Stdout mode: backward-compatible 4-byte LE header for capturer.dart.
        uint32_t rateLE = g_sampleRate;
        fwrite(&rateLE, sizeof(rateLE), 1, stdout);
        fflush(stdout);
    }

    // Graceful shutdown: Dart closes our stdin pipe on stop.
    std::thread([] {
        while (std::getchar() != EOF) {}
        g_running = false;
    }).detach();

    // Start WASAPI capture threads before waiting for FFmpeg to connect so
    // that WASAPI is already warming up (QPC timestamps accumulating) during
    // the ConnectNamedPipe wait.
    std::thread loopbackTh(captureThread, true);
    std::thread micTh(captureThread, false);

    if (hPipe != INVALID_HANDLE_VALUE) {
        // Block until FFmpeg opens the pipe. WASAPI threads run concurrently.
        BOOL ok = ConnectNamedPipe(hPipe, nullptr);
        if (!ok && GetLastError() != ERROR_PIPE_CONNECTED) {
            g_running = false;
            loopbackTh.join();
            micTh.join();
            CloseHandle(hPipe);
            return 1;
        }
    }

    constexpr size_t kChunkSamples = kChunkFrames * kOutChannels;
    constexpr float  kLoopbackGain = 0.15f;

    std::vector<int16_t> lb(kChunkSamples), mic(kChunkSamples),
                         out(kChunkSamples);

    std::deque<int16_t> lbDelay;

    // Wait until both capture threads report their first QPC timestamp, then
    // pre-fill lbDelay with the exact silence that aligns loopback to mic.
    // The WASAPI loopback endpoint captures from the render pipeline ahead of
    // the mic ADC, so lbQpc < micQpc; the difference is the real hardware
    // offset and is typically a few milliseconds.
    // Some drivers never fill pu64QPCPosition (returns 0); cap the wait at
    // 500 ms so we don't hang and simply proceed with no delay in that case.
    {
        LARGE_INTEGER qpcWaitStart, qpcFreq;
        QueryPerformanceFrequency(&qpcFreq);
        QueryPerformanceCounter(&qpcWaitStart);

        while (g_running) {
            const UINT64 lbQpc  = g_loopback.getFirstQpc();
            const UINT64 micQpc = g_mic.getFirstQpc();
            if (lbQpc != 0 && micQpc != 0) {
                const INT64 diff100ns = (INT64)lbQpc - (INT64)micQpc;
                if (diff100ns < 0) {
                    constexpr INT64 kMaxDelay100ns = 5000000LL; // 500 ms safety cap
                    const INT64 clamped = std::min(-diff100ns, kMaxDelay100ns);
                    const size_t delaySamples = static_cast<size_t>(
                        clamped * (INT64)g_sampleRate * kOutChannels / 10000000LL);
                    lbDelay.assign(delaySamples, 0);
                }
                break;
            }
            LARGE_INTEGER now;
            QueryPerformanceCounter(&now);
            if ((now.QuadPart - qpcWaitStart.QuadPart) * 1000LL / qpcFreq.QuadPart >= 500)
                break;
            Sleep(5);
        }
    }

    // Writes kChunkSamples s16le samples to the active output (pipe or stdout).
    auto writeOutput = [&](const int16_t* data, size_t samples) -> bool {
        if (hPipe != INVALID_HANDLE_VALUE) {
            DWORD written = 0;
            return WriteFile(hPipe, data,
                             static_cast<DWORD>(samples * sizeof(int16_t)),
                             &written, nullptr)
                   && written == static_cast<DWORD>(samples * sizeof(int16_t));
        }
        return fwrite(data, sizeof(int16_t), samples, stdout) == samples;
    };

    bool outputClosed = false;
    while (g_running) {
        {
            std::lock_guard<std::mutex> lk(g_loopback.mtx);
            lbDelay.insert(lbDelay.end(),
                           g_loopback.buf.begin(),
                           g_loopback.buf.end());
            g_loopback.buf.clear();
        }

        if (lbDelay.size() < kChunkSamples ||
            !g_mic.pop(mic.data(), kChunkSamples)) {
            Sleep(5);
            continue;
        }

        for (size_t i = 0; i < kChunkSamples; i++) {
            lb[i] = lbDelay.front();
            lbDelay.pop_front();
        }

        for (size_t i = 0; i < kChunkSamples; i++) {
            float mixed = lb[i] * kLoopbackGain + static_cast<float>(mic[i]);
            out[i] = static_cast<int16_t>(
                std::clamp(mixed, -32768.0f, 32767.0f));
        }

        if (!writeOutput(out.data(), kChunkSamples)) {
            outputClosed = true;
            break;
        }
    }

    g_running = false;
    loopbackTh.join();
    micTh.join();

    if (!outputClosed) {
        std::fill(mic.begin(), mic.end(), 0);
        while (lbDelay.size() >= kChunkSamples) {
            for (size_t i = 0; i < kChunkSamples; i++) {
                lb[i] = lbDelay.front();
                lbDelay.pop_front();
            }
            for (size_t i = 0; i < kChunkSamples; i++) {
                float s = lb[i] * kLoopbackGain;
                out[i] = static_cast<int16_t>(
                    std::clamp(s, -32768.0f, 32767.0f));
            }
            if (!writeOutput(out.data(), kChunkSamples)) break;
        }
        if (hPipe == INVALID_HANDLE_VALUE) fflush(stdout);
    }

    if (hPipe != INVALID_HANDLE_VALUE) {
        DisconnectNamedPipe(hPipe);
        CloseHandle(hPipe);
    }

    return 0;
}
