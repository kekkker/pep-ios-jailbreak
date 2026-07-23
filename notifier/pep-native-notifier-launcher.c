#include <errno.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const char *const app_binary_pattern =
    "/var/containers/Bundle/Application/*/pEp.app/pEpNativeNotifier";

int main(void) {
    glob_t matches = {0};
    int result = glob(app_binary_pattern, 0, NULL, &matches);
    if (result != 0 || matches.gl_pathc == 0) {
        fprintf(stderr, "pep-native-launcher: pEpNativeNotifier was not found\n");
        globfree(&matches);
        return 72;
    }

    for (size_t index = 0; index < matches.gl_pathc; ++index) {
        const char *binary = matches.gl_pathv[index];
        if (access(binary, X_OK) != 0) {
            continue;
        }
        char *const arguments[] = {(char *)binary, NULL};
        execv(binary, arguments);
        fprintf(stderr,
                "pep-native-launcher: exec failed for %s (errno %d)\n",
                binary,
                errno);
    }

    globfree(&matches);
    return 73;
}
