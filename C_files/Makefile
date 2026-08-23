# SPDX-License-Identifier: GPL-2.0-only
# Build the kernel module and the user-space I/O workload.

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

obj-m += mychardev.o

all: mychardev io_load

mychardev:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

io_load: io_load.c
	$(CC) io_load.c -o io_load

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) io_load
