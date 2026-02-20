<<<<<<<< HEAD:keyboards/madbd34/readme.md
# madbd3

![madbd3](imgur.com image replace me!)
========
# DE60 Round 1

![DE60 R1](https://i.imgur.com/7hpYaoXh.jpg)
>>>>>>>> upstream/master:keyboards/deemen17/de60/r1/readme.md

*A short description of the keyboard/project*

* Keyboard Maintainer: [amkkr](https://github.com/amkkr)
* Hardware Supported: *The PCBs, controllers supported*
* Hardware Availability: *Links to where you can find this hardware*

Make example for this keyboard (after setting up your build environment):

<<<<<<<< HEAD:keyboards/madbd34/readme.md
    make madbd3:default

Flashing example for this keyboard:

    make madbd3:default:flash
========
    make deemen17/de60/r1:default

Flashing example for this keyboard:

    make deemen17/de60/r1:default:flash
>>>>>>>> upstream/master:keyboards/deemen17/de60/r1/readme.md

See the [build environment setup](https://docs.qmk.fm/#/getting_started_build_tools) and the [make instructions](https://docs.qmk.fm/#/getting_started_make_guide) for more information. Brand new to QMK? Start with our [Complete Newbs Guide](https://docs.qmk.fm/#/newbs).

## Bootloader

Enter the bootloader in 3 ways:

* **Bootmagic reset**: Hold down the key at (0,0) in the matrix (usually the top left key or Escape) and plug in the keyboard
* **Physical reset button**: Briefly press the button on the back of the PCB - some may have pads you must short instead
* **Keycode in layout**: Press the key mapped to `QK_BOOT` if it is available
