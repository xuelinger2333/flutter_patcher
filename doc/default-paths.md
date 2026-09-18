# Default build and bootstrap behavior

The current CLI defaults `build android` and `patch android` to bytecode.
Use the existing v1 workflow explicitly for SO patches; `--strategy so` remains
recognized but the current bytecode CLI does not implement that workflow.
Bytecode host builds currently require Linux x64 and a supported SDK. An
unsupported host reports an error; it does not silently switch strategies.

Patch generation checks lean first. Dependency changes, a failed lean check,
or a resource transformation that needs whole cause a whole check. Whole must
pass its own compatibility checks and the final compiler checks before a patch
is emitted. Neither tier bypasses baseline identity or authentication.

The app owns its Binding. Bootstrap does not create or replace it. Standard and
custom are acceptance fixture names, not runtime options users must choose.

Android bootstrap prefers the available ABI v1 FFI bridge. Missing library,
missing symbols or an unavailable registration select MethodChannel before the
first request. The selection stays fixed for bootPayload and markBooting.
Timeouts and errors after dispatch do not retry the operation on another channel.
Reports and other operations continue through MethodChannel. Non-Android
platforms use MethodChannel; this does not imply bytecode support on all platforms.

Native code delivers authenticated bytes. Dart still checks ZIP CRC and entry
SHA; retaining them does not undo the FFI implementation or byte delivery change.
Bootstrap budgets are lean 85 ms and whole 250 ms. One observed startup is not
proof of long-term performance stability.

Superseded FFI echo/boot experiments and the unsuccessful interleaved hash
benchmark are removed from the current tree. Their sources remain in the local
pre-ffi-baseline-20260915 tag. Historical reports and acceptance records remain.
Real-device multi-engine/detach, missing-symbol, and live-worker timeout/cancel
coverage of the production bridge remains outstanding; the fault matrix alone
does not establish those guarantees.
