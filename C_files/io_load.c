// SPDX-License-Identifier: GPL-2.0-only
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

/* Parse /proc/self/sched and return one scheduler statistic. */
static double get_sched_stat(const char *key) {
    FILE *f = fopen("/proc/self/sched", "r");
    if (!f) {
        perror("fopen /proc/self/sched");
        return -1.0;
    }
    char line[256];
    double value = -1.0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, key)) {
            char *p = strstr(line, ":");
            if (p) {
                sscanf(p + 1, "%lf", &value);
            }
            break;
        }
    }
    fclose(f);
    return value;
}

int main(void) {
    const char *path = "/dev/mychardev";
    char buf;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    /* Capture wait_sum before the complete 5,000-read workload. */
    double wait_sum_start = get_sched_stat("wait_sum");
    if (wait_sum_start < 0) {
        fprintf(stderr, "Error: Could not read initial wait_sum.\n");
        close(fd);
        return 1;
    }

    for (int i = 0; i < 5000; i++) {
        ssize_t n;
        /* Additional printf calls would introduce I/O noise here. */
        n = read(fd, &buf, 1);  /* The module sleeps uninterruptibly. */
        if (n < 0) {
            perror("read");
            close(fd);
            return 1;
        }
    }
    close(fd);

    /* Capture the final value and calculate the whole-invocation delta. */
    double wait_sum_end = get_sched_stat("wait_sum");
    if (wait_sum_end < 0) {
        fprintf(stderr, "Error: Could not read final wait_sum.\n");
        return 1;
    }

    /* Print only the result parsed by the benchmark script. */
    printf("TOTAL_WAIT_SUM: %f\n", wait_sum_end - wait_sum_start);

    return 0;
}
