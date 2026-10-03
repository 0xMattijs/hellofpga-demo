# Checks that run without the board or Libero.
#
#   make sim    the fabric testbenches (Icarus Verilog)
#   make test   the game logic and calibration fit on the PC

SIM := build/sim
SRC := hdl/src

sim: | $(SIM)
	iverilog -g2012 -o $(SIM)/tb_game_overlay hdl/sim/tb_game_overlay.v $(SRC)/game_overlay.v
	vvp -n $(SIM)/tb_game_overlay > $(SIM)/tb_game_overlay.log
	grep -v finish $(SIM)/tb_game_overlay.log; grep -q '^PASS' $(SIM)/tb_game_overlay.log
	iverilog -g2012 -o $(SIM)/tb_game_top hdl/sim/tb_game_top.v $(SRC)/game_top.v \
	    $(SRC)/cam_bus.v $(SRC)/color_track.v $(SRC)/game_overlay.v \
	    $(SRC)/uart_tx.v $(SRC)/uart_rx.v
	vvp -n $(SIM)/tb_game_top > $(SIM)/tb_game_top.log
	grep -v finish $(SIM)/tb_game_top.log; grep -q '^PASS' $(SIM)/tb_game_top.log

test:
	$(MAKE) -C firmware/test

$(SIM):
	mkdir -p $@

.PHONY: sim test
