/* Experimental native fixture launcher. Not linked into Agent Watch or its installer.
 * Dynamic code validation is intentional: checking a pathname before spawn cannot
 * establish the identity of the program that the kernel actually loaded.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static bool native_file(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat metadata;
    uint32_t magic = 0;
    bool valid = fstat(fd, &metadata) == 0 && S_ISREG(metadata.st_mode)
        && (metadata.st_mode & 0111) != 0
        && read(fd, &magic, sizeof(magic)) == sizeof(magic)
        && magic == MH_MAGIC_64;
    close(fd);
    return valid;
}

static int identity(const char *path) {
    if (!native_file(path)) return 20;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)path, strlen(path), false);
    SecStaticCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    int result = 20;
    if (url && SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == errSecSuccess
        && SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSNoNetworkAccess, NULL) == errSecSuccess
        && SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) == errSecSuccess) {
        CFDataRef hash = CFDictionaryGetValue(information, kSecCodeInfoUnique);
        CFNumberRef options = CFDictionaryGetValue(information, kSecCodeInfoFlags);
        int flags = 0;
        int required = kSecCodeSignatureForceHard | kSecCodeSignatureForceKill | kSecCodeSignatureRuntime;
        bool hardened = options && CFGetTypeID(options) == CFNumberGetTypeID()
            && CFNumberGetValue(options, kCFNumberIntType, &flags) && (flags & required) == required;
        if (hardened && hash && CFGetTypeID(hash) == CFDataGetTypeID() && CFDataGetLength(hash) == 20) {
            const UInt8 *bytes = CFDataGetBytePtr(hash);
            for (CFIndex i = 0; i < 20; i++) printf("%02x", bytes[i]);
            putchar('\n');
            result = 0;
        }
    }
    if (information) CFRelease(information);
    if (code) CFRelease(code);
    if (url) CFRelease(url);
    return result;
}

static bool validate_child(pid_t pid, const char *hash) {
    if (strlen(hash) != 40 || strspn(hash, "0123456789abcdef") != 40) return false;
    CFStringRef text = CFStringCreateWithFormat(NULL, NULL, CFSTR("cdhash H\"%s\""), hash);
    SecRequirementRef requirement = NULL;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = { kSecGuestAttributePid };
    const void *values[] = { number };
    CFDictionaryRef attributes = CFDictionaryCreate(
        NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    bool valid = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) == errSecSuccess
        && SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess
        && SecCodeCheckValidity(code, kSecCSNoNetworkAccess, requirement) == errSecSuccess;
    if (code) CFRelease(code);
    if (attributes) CFRelease(attributes);
    if (number) CFRelease(number);
    if (requirement) CFRelease(requirement);
    if (text) CFRelease(text);
    return valid;
}

static int launch(const char *hash, const char *program, const char *directory, const char *replacement) {
    if (!native_file(program)) return 20;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    if (posix_spawnattr_init(&attributes) != 0) return 20;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        posix_spawnattr_destroy(&attributes);
        return 20;
    }
    bool configured = posix_spawnattr_setflags(
        &attributes, POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT) == 0
        && posix_spawn_file_actions_addchdir_np(&actions, directory) == 0
        && posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0
        && posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0
        && posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0;
    char *arguments[] = { "trusted-fixture", "--probe", NULL };
    char *environment[] = { "PATH=/usr/bin:/bin", "LANG=C", NULL };
    pid_t pid = 0;
    /* Test-only synchronization point: substitute a second harmless native fixture
     * after the pathname preflight and before the kernel chooses the executable.
     */
    if (replacement && rename(replacement, program) != 0) configured = false;
    int spawned = configured ? posix_spawn(&pid, program, &actions, &attributes, arguments, environment) : -1;
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (spawned != 0) return 20;
    /* The child has not run its loader or main yet. Its process identity remains
     * ours until waitpid, so this PID cannot be recycled during validation.
     */
    bool approved = validate_child(pid, hash);
    if (!approved || kill(pid, SIGCONT) != 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return 20;
    }
    int status = 0;
    pid_t waited = waitpid(pid, &status, 0);
    return waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 21;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "identity") == 0) return identity(argv[2]);
    bool ordinary = argc == 5 && strcmp(argv[1], "run") == 0;
    bool replaced = argc == 6 && strcmp(argv[1], "run-replaced") == 0;
    if (!ordinary && !replaced) return 2;
    int result = launch(argv[2], argv[3], argv[4], replaced ? argv[5] : NULL);
    puts(result == 0 ? "completed" : result == 20 ? "refused" : "failed");
    return result;
}
