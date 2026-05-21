// wasapi_capture: captures system audio (loopback) + microphone via WASAPI,
// mixes them, and writes s16le PCM to stdout.
// Usage: wasapi_capture.exe
// Output: 4-byte LE sample-rate header, then s16le stereo PCM at device rate

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

// Thread-safe PCM queue (interleaved stereo s16le)
struct AudioQueue {
    std::mutex mtx;
    std::deque<int16_t> buf;

    void push(const int16_t* data, size_t samples) {
        std::lock_guard<std::mutex> lk(mtx);
        buf.insert(buf.end(), data, data + samples);
    }

    void pushSilence(size_t samples) {
        std::lock_guard<std::mutex> lk(mtx);
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
// Handles: float32, pcm16, pcm32. Mono is duplicated to stereo.
static void convertToS16Stereo(const BYTE*        src,
                                UINT32             numFrames,
                                const WAVEFORMATEX* wf,
                                std::vector<int16_t>& out) {
    const bool   isFloat = isIeeeFloat(wf);
    const WORD   ch      = wf->nChannels;
    const WORD   bits    = wf->wBitsPerSample;
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

    if (wf)       CoTaskMemFree(wf);
    if (client)   client->Release();
    if (device)   device->Release();
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
        if (wf)       CoTaskMemFree(wf);
        if (capture)  capture->Release();
        if (client)   client->Release();
        if (device)   device->Release();
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
            BYTE*  data       = nullptr;
            UINT32 numFrames  = 0;
            DWORD  flags      = 0;

            if (FAILED(capture->GetBuffer(&data, &numFrames, &flags,
                                          nullptr, nullptr)))
                break;

            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                queue.pushSilence(numFrames * kOutChannels);
            } else if (numFrames > 0) {
                convertToS16Stereo(data, numFrames, wf, converted);
                queue.push(converted.data(), converted.size());
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

int main() {
    _setmode(_fileno(stdout), _O_BINARY);

    // Resolve device sample rate before starting threads.
    g_sampleRate = queryLoopbackSampleRate();

    // Write sample rate as first 4 bytes so the caller can configure FFmpeg.
    uint32_t rateLE = g_sampleRate;
    fwrite(&rateLE, sizeof(rateLE), 1, stdout);
    fflush(stdout);

    std::thread loopbackTh(captureThread, true);
    std::thread micTh(captureThread, false);

    constexpr size_t kChunkSamples = kChunkFrames * kOutChannels;
    std::vector<int16_t> lb(kChunkSamples), mic(kChunkSamples),
                         out(kChunkSamples);

    // Delay the loopback stream by 3 s before mixing with the mic.
    // The Windows audio engine pre-buffers render data, so loopback arrives
    // earlier than the mic signal by roughly this amount.
    constexpr uint32_t kLoopbackDelayMs = 5500;
    const size_t lbDelaySamples =
        static_cast<size_t>(kLoopbackDelayMs) * g_sampleRate / 1000 * kOutChannels;
    std::deque<int16_t> lbDelay(lbDelaySamples, 0);

    while (g_running) {
        // Drain g_loopback into the delay buffer.
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

        // Attenuate loopback so it doesn't overpower the microphone.
        constexpr float kLoopbackGain = 0.35f;
        for (size_t i = 0; i < kChunkSamples; i++) {
            int32_t mixed = static_cast<int32_t>(lb[i] * kLoopbackGain) + mic[i];
            out[i] = static_cast<int16_t>(
                std::clamp(mixed, (int32_t)-32768, (int32_t)32767));
        }

        if (fwrite(out.data(), sizeof(int16_t), kChunkSamples, stdout)
                < kChunkSamples) {
            break; // stdout closed (Dart process killed)
        }
    }

    g_running = false;
    loopbackTh.join();
    micTh.join();
    return 0;
}
