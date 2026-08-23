// SPDX-License-Identifier: GPL-2.0-only
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <errno.h>

int main(void)
{
	FILE *fp;
	pid_t pid;

	fp = fopen("cpu_pids.txt", "r");
	if (!fp) {
		perror("Could not open cpu_pids.txt");
		return 1;
	}

	while (fscanf(fp, "%d", &pid) == 1) {
		if (kill(pid, 0) == 0) {
			if (kill(pid, SIGTERM) == 0) {
				printf("PID %d terminated.\n", pid);
			} else {
				perror("Could not terminate PID");
			}
		} else {
			printf("PID %d was not found or had already terminated.\n", pid);
		}
	}

	fclose(fp);
	remove("cpu_pids.txt");
	return 0;
}
