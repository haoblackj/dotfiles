#!/bin/bash

if [ ! -S /tmp/.X11-unix/X0 ]; then
    ln -s /mnt/wslg/.X11-unix/X0 /tmp/.X11-unix/ 2>/dev/null
fi

if [ ! -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
    ln -s /mnt/wslg/runtime-dir/wayland-0* "$XDG_RUNTIME_DIR" 2>/dev/null
fi
