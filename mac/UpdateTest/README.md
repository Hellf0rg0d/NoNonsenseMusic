# Update test key

A throwaway Ed25519 key pair for the update self-test (NN_SELFTEST_UPDATE, mac.yml): Debug builds trust
`test-update-public.key`, and CI signs its test update with `test-update-private.key`. It controls nothing real: Debug
builds check no feed unless a self-test hands them one on this Mac, and Release builds trust only the release key, whose
private half lives in the keychain of the Mac that publishes releases (Sparkle's generate_keys, account nononsensemusic).
