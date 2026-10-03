# Camera breakout for the Hello FPGA kit

A breakout game that you play with your hands. Hold up a brightly colored
object in front of the camera and move it left and right to steer the paddle.
The game is drawn over the live camera image, so you see yourself behind the
bricks.

The demo shows how the SmartFusion2's two halves work together:

| Feature | What it does here |
|---|---|
| FPGA fabric | Converts every camera pixel to YCbCr, finds the pixels of your object's color, and sums their positions (`hdl/src/color_track.v`). It draws the bricks, ball, paddle, and score into the video on its way to the LCD (`hdl/src/game_overlay.v`). |
| Cortex-M3 | Reads the object's position once per frame, runs the game, and writes the game state to the fabric (`firmware/src/game.c`). |
| OV7725 camera | Video at 640 × 480 and 30 frames per second. The firmware locks its exposure and white balance so the object's color stays still. |
| LCD | Shows the camera image with the game on top, at 480 × 320. |
| Push buttons | Serve, paddle width, and calibration. |
| PIC32 | Programs the board, and relays the scores to a PC over USB. |

## Play

1. Program the board (see [Build](#build)), then unplug it and plug it back in.
2. Pick an object with a strong color that doesn't appear elsewhere in the
   picture: a green or blue ball, a colored cup, or a sticky note. Skin, wood,
   and gray clothes make poor targets.
3. Hold the object inside the box in the middle of the screen and press
   **SW3**. The digits count down 3, 2, 1 while the camera adjusts to the
   light. Keep the object in the box until the countdown ends.
4. Move the object. A cyan marker shows where the board sees it, and the
   paddle follows.

The ball serves by itself after 1.5 seconds. You start with three lives.
Bricks score 50 points in the top row down to 10 in the bottom row. Clearing a
wall puts up a new one and speeds up the ball.

The three buttons sit above the LCD. From left to right they are SW3, SW2,
and SW1.

| Button | Action |
|---|---|
| SW1 (right) | Serve now. After a game over, start a new game. |
| SW2 (middle) | Change the paddle width: wide, normal, or narrow. |
| SW3 (left) | Calibrate to the object in the box. Do this again when the light changes. |

### Keep score on a PC

The board can report each final score to a PC through the USB port:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/scoreboard.py --player Alice
```

The script prints the top ten and keeps them in `scores.json`. Your user must
be in the `dialout` group to open the serial port.

## Build

You need:

- Libero SoC 2026.1 and SoftConsole v2021.1 (for `arm-none-eabi-gcc`).
- Microchip's Hello FPGA video demo, `HF10_OV7725_LCD_FF` (Libero v12.7,
  M2S010 VF256 -1). Microchip no longer hosts it; an unmodified copy is in
  [zhouxinyu0723/Hello_fpga_green_crosses](https://github.com/zhouxinyu0723/Hello_fpga_green_crosses)
  as `HF10_OV7725_LCD_FF.7z`. Unpack it outside this repository. Its
  license doesn't allow redistribution, so this repository only refers to it.
- [hellofpga-prog](https://github.com/0xMattijs/hellofpga-prog) to program
  the board without a FlashPro.

```bash
source ~/Microchip/setup-microchip-tools.sh
REF=~/projects/hello-fpga-ref/HF10_OV7725_LCD_FF

make -C firmware REF=$REF
libero SCRIPT:libero/build.tcl "SCRIPT_ARGS:$REF $PWD/firmware/build/demo.hex"
hellofpga-prog program libero/build/export/demo.dat
```

`libero/build.tcl` copies the reference project to `libero/build/`, converts
it to the installed Libero version, and adds this repository's fabric block
(`libero/game_top.tcl`). It then runs synthesis, place-and-route, and timing,
and writes `libero/build/export/demo.dat` (DirectC) and `demo.stp` (STAPL).
Both program the fabric and the eNVM. A build takes about 3 minutes.

After programming, unplug the board and plug it back in. Until then, the
camera isn't set up and the LCD shows static.

On Linux, stop ModemManager from probing the board's serial port. Its AT
commands can stall the link to the PIC32:

```bash
echo 'ATTRS{idVendor}=="04d8", ATTRS{idProduct}=="00dd", ENV{ID_MM_DEVICE_IGNORE}="1"' \
  | sudo tee /etc/udev/rules.d/99-hello-fpga.rules
sudo udevadm control --reload-rules
```

### Checks without the board

```bash
make sim    # fabric testbenches, with Icarus Verilog
make test   # the game logic and the calibration fit, on the PC
```

`hdl/sim/tb_game_overlay.v` checks every pixel of the overlay against a
model of the layout. `hdl/sim/tb_game_top.v` sends camera frames through the
whole fabric block and checks the tracker's sums and what reaches the LCD.

## How it works

```
OV7725 ──► cam_bus ──┬──────────────────────────────► LCD path (reference design)
                     │            ▲
                     │      game_overlay ◄── ball, paddle, bricks, score
                     ▼                              ▲
                color_track ── count, Σx, Σy ──► Cortex-M3 (game.c)
```

`cam_bus.v` sits between the camera pins and the reference design's LCD
path. It passes the video through, paints in whatever `game_overlay.v` asks
for, and assembles RGB565 pixels for the tracker.

`color_track.v` converts each pixel to YCbCr and checks it against a box of
Y, Cb, and Cr limits. For every frame, it reports how many pixels matched
and the sums of their x and y. The firmware divides to get the object's
center. Working in YCbCr keeps the color (Cb and Cr) apart from the
brightness (Y), so the object still matches when it turns toward or away from
the light.

Calibration fits the box to the object. The tracker also sums the colors
inside the calibration box. The firmware averages them over five frames and
sets the Cb and Cr limits to the mean plus or minus 16. The Y floor is 35% of
the mean brightness.

`game_overlay.v` decides, for each pixel, whether to pass the video, paint a
color, or darken the video. It works in screen coordinates: the kit's LCD
shows the camera image mirrored, so the overlay flips x, and the paddle moves
the same way as your hand.

The fabric applies register writes at the next frame boundary, so a frame
never shows half an update. The Cortex-M3 polls the frame counter, since the
reference design has no fabric interrupt line that Libero 2026.1 can
regenerate.

`hdl/src/game_top.v` lists the register map. `firmware/include/config.h`
holds the settings: colors, calibration, tracking, and game speed.

## Origin

The camera bus, UART, and Libero scripts come from
[rppg-fpga](https://github.com/0xMattijs/rppg-fpga), a heart-rate monitor for
the same kit.
