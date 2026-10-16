# CNB image shared by cloud-native development and CI.
#
# `build-essential` provides cc, which the MoonBit native backend needs when it
# links test/build artifacts. Baking the toolchain in also keeps CI off the
# network: the previous runtime `curl | sh` install failed on transient TLS
# errors in the runner.
FROM cnbcool/default-dev-env:latest

# MoonBit CLI (native backend needs a C toolchain).
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

# Install the toolchain into a fixed MOON_HOME so every user (root during CI,
# the dev user in cloud-native development) can reach `moon` on PATH.
ENV MOON_HOME=/opt/moon
ENV PATH=$MOON_HOME/bin:$PATH

RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | sh \
  && moon version --all
