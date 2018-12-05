meta-swupd
==========

OpenEmbedded meta layer for swupd software-update. For information on how to
best make use of this layer see docs/Guide.md

This a new maintained fork of [meta-swupd](https://github.com/pohly/meta-swupd). It no longer uses
the deprecated [swupd-server](https://github.com/clearlinux/swupd-server), and instead uses
[mixer-tools](https://github.com/clearlinux/mixer-tools) within a Docker container.

## Dependencies

This layer depends on:

 * [`openembedded-core`](http://layers.openembedded.org/layerindex/branch/master/layer/openembedded-core/)
 * [`docker-ce`](https://docs.docker.com/install/)
 * [`clr-sdk container`](https://github.com/clearlinux/dockerfiles)


## Installation

### Docker

1. Follow the instructions from the [Docker CE](https://docs.docker.com/install/) website to install it for your distro.
2. Docker normally requires commands to be run under `sudo` which doesn't work in a build environment. The workaround
   is to add the build user to the docker group. For the current user this would be done as follows:

   `sudo usermod -a -G docker $USER`

### clr-sdk

This layer depends on a more recent version of mixer-tools (5.4.0) which isn't currently included in the version of clr-sdk
on Dockerhub. Therefore we must build the latest version locally.

```sh
git clone https://github.com/clearlinux/dockerfiles
cd dockerfiles/clr-sdk
docker build -t clearlinux/clr-sdk .
```


## Contribution

Layer Maintainer: Aaron Zinghini <aaron.zinghini@seeingmachines.com>

Please file bugs directly on this repository.
