# Zstandard decompressor

Unmodified single-file decoder generated from [meta/zstd v1.5.7](https://github.com/meta/zstd/tree/v1.5.7), commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.

Run `sh create_single_file_decoder.sh` in upstream `build/single_file_libs`, then copy `zstddeclib.c` and the root `LICENSE`. We select the BSD license. SHA-256 of the generated file: `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0`.

The Mac source installer compiles this into a small, signed helper for read-only Codex history resolution. No Homebrew package or runtime download is required. The helper reads at most an 8 GiB uncompressed source, streams full ancestor accounting without extraction, or retains at most the last 64 MiB of an exact prefix in memory, caps the Zstd window at 128 MiB and exits after 30 seconds. It never writes transcripts to disk or accesses the network. The app validates JSONL boundaries and ordinals before using a cumulative baseline. Windows uses its existing pinned `zstandard` dependency.
