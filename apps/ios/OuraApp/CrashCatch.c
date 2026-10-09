#include "CrashCatch.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_fd = -1;
static void crashcatch_handler(int sig) {
    int fd = g_fd;
    if (fd >= 0) {
        static const char header[] = "\n*** CRASH ***\n";
        (void)write(fd, header, sizeof header - 1);
        char number[] = "signal=00\n";
        number[7] = (char)('0' + (sig / 10) % 10);
        number[8] = (char)('0' + sig % 10);
        (void)write(fd, number, sizeof number - 1);
    }
    /* SA_RESETHAND restores the default disposition; preserve OS crash reporting. */
    raise(sig);
}
void crashcatch_install(int fd) {
    g_fd = fd;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = crashcatch_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}
