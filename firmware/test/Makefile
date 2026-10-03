# Runs the game logic and the calibration fit on the PC.
#   make -C firmware/test
host_game: host_game.c ../src/game.c ../src/track.c ../include/*.h
	cc -std=gnu11 -Wall -Wextra -O1 -I../include -o $@ host_game.c ../src/game.c ../src/track.c -lm

test: host_game
	./host_game

clean:
	rm -f host_game

.PHONY: test clean
.DEFAULT_GOAL := test
