# SmartFusion2 build settings, included by Makefile.
# Takes CMSIS, HAL, the MSS drivers, and the LCD driver from Microchip's
# reference project. The including file sets NAME, OUT, and APP_SRCS
# (with "=", since APP_SRCS may use $(SC)).
# Needs arm-none-eabi-gcc from SoftConsole on PATH.

REF ?= $(HOME)/projects/hello-fpga-ref/HF10_OV7725_LCD_FF
SC  := $(REF)/SC/hellofpga_lcd_cam_ff

SF2_SRCS := \
	$(SC)/ili9488.c \
	$(SC)/CMSIS/system_m2sxxx.c \
	$(SC)/CMSIS/startup_gcc/newlib_stubs.c \
	$(SC)/CMSIS/startup_gcc/startup_m2sxxx.S \
	$(SC)/drivers_config/sys_config/sys_config.c \
	$(SC)/drivers/mss_gpio/mss_gpio.c \
	$(SC)/drivers/mss_hpdma/mss_hpdma.c \
	$(SC)/drivers/mss_i2c/mss_i2c.c \
	$(SC)/drivers/mss_nvm/mss_nvm.c \
	$(SC)/drivers/mss_sys_services/mss_comblk.c \
	$(SC)/drivers/mss_sys_services/mss_sys_services.c \
	$(SC)/hal/CortexM3/cortex_nvic.c \
	$(SC)/hal/CortexM3/GNU/hal.S \
	$(SC)/hal/CortexM3/GNU/hw_reg_access.S

SRCS := $(APP_SRCS) $(SF2_SRCS)

CFLAGS := -mcpu=cortex-m3 -mthumb -O0 -g -fmessage-length=0 -fsigned-char \
	-ffunction-sections -fdata-sections -std=gnu11 --specs=cmsis.specs -MMD -MP \
	-Iinclude -I$(SC) -I$(SC)/CMSIS -I$(SC)/CMSIS/startup_gcc \
	-I$(SC)/drivers/mss_gpio -I$(SC)/drivers_config -I$(SC)/drivers_config/sys_config \
	-I$(SC)/hal -I$(SC)/hal/CortexM3 -I$(SC)/hal/CortexM3/GNU
LDFLAGS := -T $(SC)/CMSIS/startup_gcc/production-smartfusion2-execute-in-place.ld \
	-Xlinker --gc-sections -Wl,-Map,$(OUT)/$(NAME).map --specs=nano.specs

.DEFAULT_GOAL := build/$(NAME).hex

# One explicit rule per source, so a file name in the reference project
# can't shadow one here.
obj = $(OUT)/obj/$(notdir $(1)).o
OBJS := $(foreach s,$(SRCS),$(call obj,$(s)))
define compile
$(call obj,$(1)): $(1) | $(OUT)/obj
	arm-none-eabi-gcc $$(CFLAGS) -c -o $$@ $$<
endef
$(foreach s,$(SRCS),$(eval $(call compile,$(s))))
-include $(OBJS:.o=.d)

build/$(NAME).hex: $(OUT)/$(NAME).elf
	arm-none-eabi-objcopy -O ihex $< $@
	arm-none-eabi-size $<

$(OUT)/$(NAME).elf: $(OBJS)
	arm-none-eabi-gcc $(CFLAGS) $(LDFLAGS) -o $@ $^

$(OUT)/obj:
	mkdir -p $@

clean:
	rm -rf $(OUT) build/$(NAME).hex

.PHONY: clean
