// SPDX-License-Identifier: GPL-2.0-only
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

#define SIZE 10000

/* This default can be overridden with -DNUM_CHILDREN=X during compilation. */
#ifndef NUM_CHILDREN
#define NUM_CHILDREN 4
#endif

int main(void) {
    pid_t pid;
    FILE *fp;

    fp = fopen("cpu_pids.txt", "w");
    if (!fp) {
        perror("Could not open cpu_pids.txt");
        return 1;
    }

    double *arr = malloc(SIZE * sizeof(double));
    if (!arr) {
        perror("malloc");
        fclose(fp);
        return 1;
    }

    /* Initialize the array used by the CPU-bound workload. */
    for (int i = 0; i < SIZE; i++) {
        arr[i] = i * 0.001;
    }

    for (int i = 0; i < NUM_CHILDREN; i++) {
        pid = fork();
        if (pid < 0) {
            perror("fork");
            fclose(fp);
            free(arr);
            return 1;
        }
        if (pid == 0) {
            /* Child process: keep producing CPU contention. */
            while (1) {
                for (int j = 0; j < SIZE; j++) {
                    arr[j] = sin(arr[j]) * cos(arr[j]) + sqrt(arr[j]);
                }
            }
        } else {
            /* Parent process: save each child PID for later cleanup. */
            fprintf(fp, "%d\n", pid);
            printf("%d ", pid);
        }
    }

    fclose(fp);
    free(arr);
    return 0;
}
