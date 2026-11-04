# Android on the Native SDK - Decisions (Discuss)

Decided by Julio on 2026-11-04.

| Gray area | Options | Decision |
| --- | --- | --- |
| G1 - How the RN package version and `sdk_name: "react-native"` reach the native SDK | (a) opt-in annotation API (`@RequiresOptIn`) in native 0.2.0; (b) public `NottiOptions` fields; (c) do not send (report the native SDK's own values) | (a). Mirrors iOS `@_spi(Wrapper)`. Native `wrapper-support` spec, native AD-022. |
| G2 - `com.notti.NottiBridge` for hosts with their own `FirebaseMessagingService` | (a) keep as a `@Deprecated` shim forwarding to `com.zeeplabs.notti.NottiBridge`; (b) remove, integrator changes the import | (a). Not breaking for those hosts. |
| G3 - Release | (a) same 0.9.0 as iOS (`ios-native-sdk`); (b) Android first in its own release | (a). One set of upgrade notes, one breaking release. |
