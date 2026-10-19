CROSS_COMPILE ?= arm-linux-gnueabihf-
CFLAGS ?= -O2

.PHONY: all clean
all: addon/tee/mpc_uac2_tee.so addon/mpc-transfer-watch

addon/tee/mpc_uac2_tee.so: addon/tee/mpc_uac2_tee.c
	$(CROSS_COMPILE)gcc $(CFLAGS) -fPIC -shared -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -o $@ $< -ldl -lpthread

addon/mpc-transfer-watch: addon/mpc-transfer-watch.c
	$(CROSS_COMPILE)gcc $(CFLAGS) -Wall -Wextra -Werror -o $@ $<

clean:
	rm -f addon/tee/mpc_uac2_tee.so addon/mpc-transfer-watch
