// Run against the exact APK library without a JVM: bounds and handle ownership.
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

void require(bool value) { if (!value) { std::puts("FAILED"); std::exit(1); } }
template<class T> T symbol(void* lib, const char* name) {
    auto value = reinterpret_cast<T>(dlsym(lib, name)); require(value != nullptr); return value;
}
int main(int argc, char** argv) {
    require(argc == 2);
    void* lib = dlopen(argv[1], RTLD_NOW); require(lib != nullptr);
    const auto input = symbol<uint64_t(*)(int32_t)>(lib,"patcher_boot_v1_input");
    const auto begin = symbol<uint64_t(*)(uint64_t)>(lib,"patcher_boot_v1_begin");
    const auto state = symbol<int32_t(*)(uint64_t)>(lib,"patcher_boot_v1_state");
    const auto size = symbol<int64_t(*)(uint64_t)>(lib,"patcher_boot_v1_size");
    const auto data = symbol<uint8_t*(*)(uint64_t)>(lib,"patcher_boot_v1_data");
    const auto release = symbol<int32_t(*)(uint64_t)>(lib,"patcher_boot_v1_release");
    const auto handles = symbol<int32_t(*)()>(lib,"patcher_boot_v1_handles");
    const auto workers = symbol<int32_t(*)()>(lib,"patcher_boot_v1_workers");
    const auto available = symbol<int32_t(*)()>(lib,"patcher_boot_v1_available");
    require(available()==0 && handles()==0 && workers()==0);
    require(input(-1)==0 && input(0)==0 && input(65537)==0);
    require(release(0)==-1 && state(0)==-2 && size(0)==-1 && data(0)==nullptr);
    uint64_t held[4];
    for (auto& h : held) { h=input(65536); require(h!=0 && size(h)==65536); }
    require(input(1)==0 && handles()==4);
    for (auto h : held) require(release(h)==0);
    for (int i=0;i<10000;++i) {
        const auto h=input(1024); require(h!=0 && data(h)!=nullptr);
        std::memset(data(h),i & 255,1024);
        require(data(h)[1023]==(i & 255) && begin(h)==0);
        require(release(h)==0 && release(h)==-1 && size(h)==-1 && data(h)==nullptr);
    }
    require(handles()==0 && workers()==0);
    std::puts("PASS: bounds, capacity, 10000 lifecycles, duplicate release, unavailable dispatch");
    dlclose(lib);
}
