# Bootstrap transport ABI v1

Android attempts the `libpatcher_boot.so` C ABI before its first `bootPayload`
request. Other platforms, old APKs, absent symbols, and unavailable bridges use
the existing MethodChannel. Selection is fixed for bootPayload and markBooting;
a rejected or timed-out dispatched request never retries on another transport.
Reports and all non-bootstrap operations continue through the engine's channel.

Kotlin remains the only owner of patch authentication and state transitions.
The bridge transports StandardMethodCodec requests and envelopes and copies the
response into a private Dart Uint8List before releasing native storage. CRC,
entry SHA, candidate verification, attempt tokens and publication checks remain.

Inputs are limited to 64 KiB, responses to 320 MiB plus 64 KiB, and the process
admits at most four handles and two workers. Cancelling a handle discards its
result; it does not interrupt a Kotlin transaction or reclaim a live worker's
capacity. A 2500 ms transport deadline releases the handle within the existing
outer bootstrap timeout. The pointer API has one owner; it is not a cross-isolate
shared-memory API. No borrowed Dart view survives release.

ABI v1 does not convey an engine identity. A second plugin registration, even
after detach, permanently disables this fast path for the process. This avoids
dispatching into another engine's manager. In-flight operations are not replayed;
subsequent engines use their own MethodChannels. Detach releases the JNI global
reference; a worker already executing owns a local reference until it completes.

The CMake bridge builds for the plugin's existing ABI list. Only a matching APK
and rebuilt patch corpus can validate a product change. Superseded FFI prototypes
are archived in the local pre-ffi-baseline-20260915 tag. The production-library
handle harness remains at test/acceptance/ffi_boot/native_handles.cpp.
