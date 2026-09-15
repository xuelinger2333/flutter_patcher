// Test-only synchronous JNI transport. No signature or patch-state implementation.
#include <jni.h>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <sys/resource.h>
#include <time.h>

namespace {
JavaVM* vm = nullptr;
jobject provider = nullptr;
jmethodID read_method = nullptr;
std::mutex mutex;
std::unordered_map<uint64_t, std::unique_ptr<std::vector<uint8_t>>> buffers;
uint64_t next_id = 1;
constexpr int max_bytes = 16 * 1024 * 1024;
thread_local int last_error = 0;
}
#define API extern "C" __attribute__((visibility("default")))

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* value, void*) { vm = value; return JNI_VERSION_1_6; }
extern "C" JNIEXPORT void JNICALL
Java_com_example_wp24_1probe_MainActivity_registerProvider(JNIEnv* env, jobject self) {
    std::lock_guard<std::mutex> guard(mutex);
    if (provider != nullptr) env->DeleteGlobalRef(provider);
    provider = env->NewGlobalRef(self);
    jclass cls = env->GetObjectClass(self);
    read_method = env->GetMethodID(cls, "readPayload", "(I)[B");
    env->DeleteLocalRef(cls);
}

API uint64_t wp24_acquire(int32_t size) {
    last_error = 0;
    if (size < 0 || size > max_bytes) { last_error = 1; return 0; }
    std::lock_guard<std::mutex> guard(mutex);
    if (!vm || !provider || !read_method || buffers.size() >= 4) { last_error = 2; return 0; }
    JNIEnv* env = nullptr;
    bool attached = false;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK) { last_error = 3; return 0; }
        attached = true;
    }
    auto array = static_cast<jbyteArray>(env->CallObjectMethod(provider, read_method, size));
    uint64_t id = 0;
    if (env->ExceptionCheck()) { env->ExceptionClear(); last_error = 4; }
    else if (!array || env->GetArrayLength(array) != size) { last_error = 5; }
    else {
        try {
            auto bytes = std::make_unique<std::vector<uint8_t>>(size);
            if (size) env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte*>(bytes->data()));
            if (env->ExceptionCheck()) { env->ExceptionClear(); last_error = 6; }
            else { id = next_id++; buffers.emplace(id, std::move(bytes)); }
        } catch (...) { last_error = 7; }
    }
    if (array) env->DeleteLocalRef(array);
    if (attached) vm->DetachCurrentThread();
    return id;
}
// A handle has one synchronous Dart owner. Its borrowed view must be copied
// before release; these test APIs do not promise safety for concurrent owners.
API const uint8_t* wp24_data(uint64_t id) {
    std::lock_guard<std::mutex> guard(mutex);
    auto found = buffers.find(id);
    return found == buffers.end() ? nullptr : found->second->data();
}
API int64_t wp24_length(uint64_t id) {
    std::lock_guard<std::mutex> guard(mutex);
    auto found = buffers.find(id);
    return found == buffers.end() ? -1 : static_cast<int64_t>(found->second->size());
}
API int32_t wp24_release(uint64_t id) {
    std::lock_guard<std::mutex> guard(mutex);
    return buffers.erase(id) == 1 ? 0 : -1;
}
API int32_t wp24_error() { return last_error; }
API int64_t wp24_retained() {
    std::lock_guard<std::mutex> guard(mutex);
    int64_t size = 0; for (const auto& item : buffers) size += item.second->size();
    return size;
}
API int64_t wp24_cpu_ns() {
    timespec t{}; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return static_cast<int64_t>(t.tv_sec)*1000000000 + t.tv_nsec;
}
API int64_t wp24_peak_rss() {
    rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    return static_cast<int64_t>(usage.ru_maxrss)*1024;
}
