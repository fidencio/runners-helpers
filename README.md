# runners-helpers
This is a repo where I store information needed for setting and resetting up Kata Containers and Confidential Containers runners

## kata-containers

Whenever one happens to notice nydus snapshotter related issues on the
kata-containers nodes, simply run:
```sh
./runners-helpers/kata-containers/setup.sh uninstall
sudo systemctl reboot
./runners-helpers/kata-containers/setup.sh install
```
