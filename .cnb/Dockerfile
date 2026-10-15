# CI build environment for CNB: MoonBit toolchain preinstalled.
FROM cnbcool/default-build-env

# MoonBit's native backend needs a C compiler/linker driver.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.moon/bin:${PATH}"

COPY scripts/install-moonbit.sh /tmp/install-moonbit.sh
RUN sh /tmp/install-moonbit.sh && rm -f /tmp/install-moonbit.sh

RUN moon version --all
