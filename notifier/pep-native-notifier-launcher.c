#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern uint32_t notify_post(const char *name);

static const char *const app_binary_pattern =
    "/var/containers/Bundle/Application/*/pEp.app/pEpNativeNotifier";
static const char *const queue_root =
    "/var/mobile/Library/Caches/software.pep.notifier";
static const char *const queue_directory =
    "/var/mobile/Library/Caches/software.pep.notifier/queue";
static const char *const bulletin_notification =
    "software.pep.notifier.new-bulletin";
static pid_t child_pid = -1;

static void forward_signal(int signal_number) {
    if (child_pid > 0) {
        kill(child_pid, signal_number);
    }
}

static int read_exact(int descriptor, void *buffer, size_t length) {
    size_t received = 0;
    while (received < length) {
        ssize_t result = read(descriptor, (char *)buffer + received, length - received);
        if (result == 0) {
            return received == 0 ? 0 : -1;
        }
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        received += (size_t)result;
    }
    return 1;
}

static int write_exact(int descriptor, const void *buffer, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, (const char *)buffer + written, length - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        written += (size_t)result;
    }
    return 0;
}

static int assure_queue_directory(void) {
    if (mkdir(queue_root, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    if (mkdir(queue_directory, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    chmod(queue_root, 0700);
    chmod(queue_directory, 0700);
    return 0;
}

static int queue_bulletin(const void *payload, size_t payload_length) {
    if (assure_queue_directory() != 0) {
        return -1;
    }

    char temporary_path[512];
    int path_result = snprintf(
        temporary_path,
        sizeof(temporary_path),
        "%s/.bulletin-XXXXXX",
        queue_directory);
    if (path_result <= 0 || (size_t)path_result >= sizeof(temporary_path)) {
        return -1;
    }

    int descriptor = mkstemp(temporary_path);
    if (descriptor < 0) {
        return -1;
    }
    fchmod(descriptor, 0600);
    int result = write_exact(descriptor, payload, payload_length);
    if (result == 0) {
        result = fsync(descriptor);
    }
    int saved_errno = errno;
    close(descriptor);
    errno = saved_errno;
    if (result != 0) {
        unlink(temporary_path);
        return -1;
    }

    char final_path[520];
    path_result = snprintf(final_path, sizeof(final_path), "%s.plist", temporary_path);
    if (path_result <= 0 || (size_t)path_result >= sizeof(final_path) ||
        rename(temporary_path, final_path) != 0) {
        unlink(temporary_path);
        return -1;
    }

    notify_post(bulletin_notification);
    return 0;
}

static int supervise_notifier(const char *binary) {
    int bulletin_pipe[2];
    if (pipe(bulletin_pipe) != 0) {
        fprintf(stderr, "pep-native-launcher: pipe failed (errno %d)\n", errno);
        return 74;
    }

    child_pid = fork();
    if (child_pid < 0) {
        fprintf(stderr, "pep-native-launcher: fork failed (errno %d)\n", errno);
        close(bulletin_pipe[0]);
        close(bulletin_pipe[1]);
        return 75;
    }
    if (child_pid == 0) {
        close(bulletin_pipe[0]);
        if (bulletin_pipe[1] != 3) {
            if (dup2(bulletin_pipe[1], 3) < 0) {
                _exit(76);
            }
            close(bulletin_pipe[1]);
        }
        fcntl(3, F_SETFD, 0);
        setenv("PEP_HEADLESS_NOTIFIER", "1", 1);
        setenv("PEP_BULLETIN_FD", "3", 1);
        char *const arguments[] = {(char *)binary, NULL};
        execv(binary, arguments);
        _exit(77);
    }

    close(bulletin_pipe[1]);
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);
    signal(SIGHUP, forward_signal);

    for (;;) {
        uint32_t network_length = 0;
        int read_result = read_exact(
            bulletin_pipe[0],
            &network_length,
            sizeof(network_length));
        if (read_result == 0) {
            break;
        }
        if (read_result < 0) {
            fprintf(stderr, "pep-native-launcher: malformed bulletin header\n");
            break;
        }

        uint32_t payload_length = ntohl(network_length);
        if (payload_length == 0 || payload_length > 1024 * 1024) {
            fprintf(stderr, "pep-native-launcher: invalid bulletin size\n");
            break;
        }
        void *payload = malloc(payload_length);
        if (payload == NULL) {
            break;
        }
        read_result = read_exact(bulletin_pipe[0], payload, payload_length);
        if (read_result <= 0 || queue_bulletin(payload, payload_length) != 0) {
            fprintf(stderr, "pep-native-launcher: unable to persist bulletin (errno %d)\n",
                    errno);
        } else {
            fprintf(stderr, "pep-native-launcher: bulletin delivered to SpringBoard\n");
        }
        free(payload);
        if (read_result <= 0) {
            break;
        }
    }

    close(bulletin_pipe[0]);
    int child_status = 0;
    waitpid(child_pid, &child_status, 0);
    if (WIFEXITED(child_status)) {
        return WEXITSTATUS(child_status);
    }
    if (WIFSIGNALED(child_status)) {
        return 128 + WTERMSIG(child_status);
    }
    return 78;
}

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
        int result = supervise_notifier(binary);
        globfree(&matches);
        return result;
    }

    globfree(&matches);
    return 73;
}
