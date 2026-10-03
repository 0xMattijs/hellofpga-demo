# Build the camera breakout firmware for the Cortex-M3.
#
#   make REF=<path to HF10_OV7725_LCD_FF>
#
# Writes build/demo.hex; pass it to libero/build.tcl to load it into eNVM.
# See sf2.mk for what comes from the reference project.

NAME := demo
OUT  := build/demo
APP_SRCS = src/main.c src/camera.c src/game.c src/track.c src/uart.c
include sf2.mk
