/* Synthetic provider only: no Keychain API, network, interpreter, or external module. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef FIXTURE_VERSION
#define FIXTURE_VERSION 1
#endif

static const char *fixture_credentials(void) {
    return "AGENT_WATCH_SYNTHETIC_VALUE_NOT_A_SECRET";
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--probe") != 0) return 30;
    if (getenv("AGENT_WATCH_UNEXPECTED_ENV") != NULL) return 31;
    const char *value = fixture_credentials();
    /* Normal program output must not become the launcher's response or its log. */
    puts(value);
    fprintf(stderr, "%s\n", value);
    FILE *receipt = fopen("receipt", "w");
    if (!receipt) return 32;
    fprintf(receipt, "fixture-%d\n", FIXTURE_VERSION);
    if (fclose(receipt) != 0) return 33;
    /* The second build also exercises the deadline once approved under its own hash. */
    if (FIXTURE_VERSION == 2) {
        for (;;) pause();
    }
    return 0;
}
