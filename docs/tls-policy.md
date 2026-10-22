# Application certificate policy

At startup, before importing HTTP client modules, the application refreshes a private CA bundle from the Python build's original operating-system CA file and removes two distrusted root fingerprints. It sets SSL_CERT_FILE, SSL_CERT_DIR and REQUESTS_CA_BUNDLE; the CA directory remains empty. Certificate and hostname verification remain enabled. The fixed certifi version is pinned for clients that explicitly use its bundle.

The container's existing read-only filesystem and temporary writable directory are supported. The bundle defaults to a dedicated subdirectory of the process temporary directory. Deployment may set TOKENFLEET_TLS_SOURCE and TOKENFLEET_TLS_OUTPUT to explicit local paths. Invalid or unavailable input stops application startup. No platform trust store is modified.

The normal application startup path applies this policy after fresh builds and restarts. Standalone maintenance commands that do not import the application must use their own verified CA settings. Rollback uses the previous application image and retains its prior certificate behavior.
