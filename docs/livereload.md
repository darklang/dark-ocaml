## Setting up livereload

**Note: this doc is out of date. We would like to make this work, however, so contributions are welcome.**

When a compile completes, you will want your browser to reload, the load your changes. You can set this up on your host using "livereload".

### Setup

Install Python 3:

- on linux: `apt install python3-pip`
- on mac: `brew install python3`
- on Windows (WSL+Ubuntu): `apt install python3-pip`

### Install livereload

`pip install livereload`

### Run the script

From your machine (not the devcontainer), run:

`./scripts/build/_reload-browser`
