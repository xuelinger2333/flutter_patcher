// Experimental async byte-message bridge. Kotlin remains the only patch manager.
#include <jni.h>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {
JavaVM* vm=nullptr;
jobject provider=nullptr;
jmethodID execute=nullptr;
std::mutex mutex;
struct Task { std::vector<uint8_t> bytes; int state=0; bool input=false; bool cancelled=false; };
std::unordered_map<uint64_t,std::shared_ptr<Task>> tasks;
uint64_t sequence=1;
int workers=0;
constexpr int max_response=320*1024*1024+65536;
void work(std::shared_ptr<Task> task,std::vector<uint8_t> request) {
    JNIEnv* env=nullptr;
    bool attached=false;
    if(vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6)!=JNI_OK) {
        if(vm->AttachCurrentThread(&env,nullptr)!=JNI_OK) {
            std::lock_guard<std::mutex> lock(mutex);task->state=-1;--workers;return;
        }
        attached=true;
    }
    jobject local=nullptr;jmethodID method=nullptr;
    { std::lock_guard<std::mutex> lock(mutex); if(provider) local=env->NewLocalRef(provider);method=execute; }
    jbyteArray input=nullptr,output=nullptr;
    std::vector<uint8_t> response;
    bool success=false;
    if(local && method) {
        input=env->NewByteArray(static_cast<jsize>(request.size()));
        if(input) {
            env->SetByteArrayRegion(input,0,static_cast<jsize>(request.size()),reinterpret_cast<const jbyte*>(request.data()));
            if(!env->ExceptionCheck())output=static_cast<jbyteArray>(env->CallObjectMethod(local,method,input));
            if(!env->ExceptionCheck() && output) {
                const int size=env->GetArrayLength(output);
                if(size>0 && size<=max_response) {
                    try {
                        response.resize(size);
                        env->GetByteArrayRegion(output,0,size,reinterpret_cast<jbyte*>(response.data()));
                        success=!env->ExceptionCheck();
                    } catch(...) { success=false; }
                }
            }
        }
    }
    if(env->ExceptionCheck())env->ExceptionClear();
    if(output)env->DeleteLocalRef(output);
    if(input)env->DeleteLocalRef(input);
    if(local)env->DeleteLocalRef(local);
    if(attached)vm->DetachCurrentThread();
    std::lock_guard<std::mutex> lock(mutex);
    --workers;
    if(!task->cancelled) { task->bytes=std::move(response);task->state=success?1:-1; }
}
}
#define API extern "C" __attribute__((visibility("default")))
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* value,void*) {vm=value;return JNI_VERSION_1_6;}
extern "C" JNIEXPORT void JNICALL
Java_com_flutter_1patcher_flutter_1patcher_FfiBootBridge_nativeRegister(JNIEnv* env,jobject self) {
    std::lock_guard<std::mutex> lock(mutex);
    if(provider) {env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"Bridge already attached");return;}
    provider=env->NewGlobalRef(self);
    jclass cls=env->GetObjectClass(self);
    execute=env->GetMethodID(cls,"execute","([B)[B");env->DeleteLocalRef(cls);
}
API uint64_t wp24_input(int32_t size) {
    std::lock_guard<std::mutex> lock(mutex);
    if(size<=0 || size>65536 || tasks.size()>=4)return 0;
    try {auto task=std::make_shared<Task>();task->bytes.resize(size);task->state=1;task->input=true;
        const auto id=sequence++;tasks.emplace(id,task);return id;}catch(...){return 0;}
}
API uint64_t wp24_begin(uint64_t input) {
    std::lock_guard<std::mutex> lock(mutex);
    const auto found=tasks.find(input);
    if(found==tasks.end() || !found->second->input || !provider || tasks.size()>=4 || workers>=2)return 0;
    try {
        auto request=found->second->bytes;
        auto task=std::make_shared<Task>();const auto id=sequence++;
        tasks.emplace(id,task);
        ++workers;
        try {std::thread(work,task,std::move(request)).detach();}
        catch(...) {--workers;tasks.erase(id);return 0;}
        return id;
    } catch(...) {return 0;}
}
API int32_t wp24_state(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex);auto it=tasks.find(id);return it==tasks.end()?-2:it->second->state;
}
API int64_t wp24_size(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex);auto it=tasks.find(id);
    return it==tasks.end() || it->second->state!=1?-1:static_cast<int64_t>(it->second->bytes.size());
}
// Borrowed only until release. Exactly one Dart owner copies before releasing.
API uint8_t* wp24_data(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex);auto it=tasks.find(id);
    return it==tasks.end() || it->second->state!=1?nullptr:it->second->bytes.data();
}
API int32_t wp24_release(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex);auto it=tasks.find(id);if(it==tasks.end())return -1;
    it->second->cancelled=true;tasks.erase(it);return 0;
}
API int32_t wp24_workers() {std::lock_guard<std::mutex> lock(mutex);return workers;}
API int32_t wp24_handles() {std::lock_guard<std::mutex> lock(mutex);return static_cast<int32_t>(tasks.size());}
