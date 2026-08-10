#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("usage: create_isolated_file_keychain /private/tmp/.../test.keychain\n", stderr);
        return 2;
    }

    const char *path = argv[1];
    const char *prefix = "/private/tmp/";
    if (strncmp(path, prefix, strlen(prefix)) != 0 ||
        strstr(path, "/../") != NULL ||
        access(path, F_OK) == 0) {
        fputs("refusing a non-isolated or existing keychain path\n", stderr);
        return 2;
    }

    SecKeychainRef keychain = NULL;
    const char test_password[] = "tokenfleet-isolated-test-only";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecKeychainCreate(
        path,
        (UInt32)strlen(test_password),
        test_password,
        false,
        NULL,
        &keychain
    );
#pragma clang diagnostic pop
    if (status != errSecSuccess || keychain == NULL) {
        fprintf(stderr, "SecKeychainCreate failed: %d\n", (int)status);
        return 1;
    }

    SecKeychainSettings settings = {
        .version = SEC_KEYCHAIN_SETTINGS_VERS1,
        .lockOnSleep = true,
        .useLockInterval = true,
        .lockInterval = 300,
    };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = SecKeychainSetSettings(keychain, &settings);
#pragma clang diagnostic pop
    CFRelease(keychain);
    if (status != errSecSuccess) {
        fprintf(stderr, "SecKeychainSetSettings failed: %d\n", (int)status);
        return 1;
    }
    if (chmod(path, S_IRUSR | S_IWUSR) != 0) {
        perror("chmod isolated keychain");
        return 1;
    }

    puts(path);
    return 0;
}
