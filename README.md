# Leed for YunoHost

[![Integration level](https://dash.yunohost.org/integration/leed.svg)](https://ci-apps.yunohost.org/jenkins/job/leed%20%28Community%29/lastBuild/consoleFull)  
[![Install Leed with YunoHost](https://install-app.yunohost.org/install-with-yunohost.png)](https://install-app.yunohost.org/?app=leed)

*[Lire ce readme en français.](./README_fr.md)*

> *This package allow you to install leed quickly and simply on a YunoHost server.  
If you don't have YunoHost, please see [here](https://yunohost.org/#/install) to know how to install and enjoy it.*

## Overview
Leed (short for Light Feed) is a minimalist RSS/ATOM aggregator which offers fast RSS consultation and non-intrusive features.

**Shipped version:** 1.8.3

## Screenshots

![](http://projet.idleman.fr/leed/data/leed1.jpg)

## Configuration

Use the admin panel of your Leed to configure this app.

## Documentation

* YunoHost documentation: There no other documentations, feel free to contribute.

## YunoHost specific features

#### Multi-users support

Not supported.

#### Supported architectures

* Tested on x86_64

## Limitations

## Additionnal informations

## Links

 * Report a bug: https://github.com/YunoHost-Apps/leed_ynh/issues
 * Leed website: http://leed.idleman.fr/
 * YunoHost website: https://yunohost.org/

---

Developers infos
----------------

Please do your pull request to the [testing branch](https://github.com/YunoHost-Apps/leed_ynh/tree/testing).

To try the testing branch, please proceed like that.
```
sudo yunohost app install https://github.com/YunoHost-Apps/leed_ynh/tree/testing --verbose
or
sudo yunohost app upgrade leed -u https://github.com/YunoHost-Apps/leed_ynh/tree/testing --verbose
```
