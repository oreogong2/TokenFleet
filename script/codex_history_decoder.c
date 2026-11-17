/* Read-only, bounded prefix decoder. No transcript is written to disk. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../vendor/zstd/zstddeclib.c"

#define TAIL_LIMIT (64U * 1024U * 1024U)
#define PREFIX_LIMIT (8ULL * 1024ULL * 1024ULL * 1024ULL)

int main(int argc, char **argv) {
    alarm(30);
    if (argc != 3 || !argv[2][0] || argv[2][0] == '-') return 2;
    char *end = NULL;
    errno = 0;
    unsigned long long target = strtoull(argv[2], &end, 10);
    if (errno || *end || target == 0 || target > PREFIX_LIMIT) return 2;
    int fd = open(argv[1], O_RDONLY | O_NOFOLLOW);
    struct stat before, after;
    if (fd < 0) return 3;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode)) { close(fd); return 3; }
    FILE *file = fdopen(fd, "rb");
    if (!file) { close(fd); return 3; }
    ZSTD_DStream *stream = ZSTD_createDStream();
    unsigned char *tail = malloc(TAIL_LIMIT);
    unsigned char input[65536], output[65536];
    int status = 4;
    if (!stream || !tail || ZSTD_isError(ZSTD_initDStream(stream)) ||
        ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 27))) goto done;
    unsigned long long total = 0;
    size_t cursor = 0;
    ZSTD_inBuffer in = {input, 0, 0};
    int need_input = 1;
    while (total < target) {
        if (need_input) {
            in.size = fread(input, 1, sizeof input, file);
            in.pos = 0;
            if (!in.size) goto done;
        }
            size_t capacity = (size_t)((target - total < sizeof output) ? target - total : sizeof output);
            ZSTD_outBuffer out = {output, capacity, 0};
            size_t old_pos = in.pos;
            size_t result = ZSTD_decompressStream(stream, &out, &in);
            if (ZSTD_isError(result)) goto done;
            need_input = in.pos == in.size && out.pos < out.size;
            if (!need_input && old_pos == in.pos && out.pos == 0) goto done;
            size_t first = out.pos < TAIL_LIMIT - cursor ? out.pos : TAIL_LIMIT - cursor;
            memcpy(tail + cursor, output, first);
            memcpy(tail, output + first, out.pos - first);
            cursor = (cursor + out.pos) % TAIL_LIMIT;
            total += out.pos;
    }
    if (fstat(fd, &after) || before.st_size != after.st_size || before.st_mtime != after.st_mtime) goto done;
    size_t count = total < TAIL_LIMIT ? (size_t)total : TAIL_LIMIT;
    size_t start = total < TAIL_LIMIT ? 0 : cursor;
    if (tail[(cursor + TAIL_LIMIT - 1) % TAIL_LIMIT] != '\n') goto done;
    size_t first = count < TAIL_LIMIT - start ? count : TAIL_LIMIT - start;
    if (fwrite(tail + start, 1, first, stdout) != first ||
        fwrite(tail, 1, count - first, stdout) != count - first || fflush(stdout)) goto done;
    status = 0;
done:
    free(tail);
    ZSTD_freeDStream(stream);
    fclose(file);
    return status;
}
