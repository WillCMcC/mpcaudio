CROSS_COMPILE ?= arm-linux-gnueabihf-
CFLAGS ?= -O2

.PHONY: all clean
all: addon/tee/mpc_uac2_tee.so

addon/tee/mpc_uac2_tee.so: addon/tee/mpc_uac2_tee.c
	$(CROSS_COMPILE)gcc $(CFLAGS) -fPIC -shared -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -o $@ $< -ldl -lpthread

clean:
	rm -f addon/tee/mpc_uac2_tee.so
