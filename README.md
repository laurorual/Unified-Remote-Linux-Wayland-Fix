# Unified-Remote-Linux-Wayland-Fix
A simple fix for mouse input in Unified Remote when using it on Linux Wayland environments.

Just download the Unified-Remote-Linux-Wayland-Fix.zip file from this repo, extract it and copy the "remotes" files to your Unified Remote folder.

It also contains a "unified-remote.service" file to auto start Unified Remote with your system. Just copy this file to $HOME/.config/systemd/user/ and run:
```
systemctl --user daemon-reload
systemctl --user enable unified-remote.service
systemctl --user start unified-remote.service
```
