FROM debian:bookworm-slim AS tippecanoe-builder

ARG TIPPECANOE_REF=7fc82a1796e6d99c6a1fbd96318f6295a46df512

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
        libsqlite3-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/tippecanoe

RUN git init \
    && git remote add origin https://github.com/felt/tippecanoe.git \
    && git fetch --depth 1 origin "${TIPPECANOE_REF}" \
    && git checkout --detach FETCH_HEAD \
    && make -j"$(nproc)" \
    && make install

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        gdal-bin \
        libsqlite3-0 \
        python3-gdal \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tippecanoe-builder /usr/local/bin/ /usr/local/bin/
COPY build_map.sh /usr/local/bin/build_map.sh
COPY validate_map.py /usr/local/bin/validate_map.py
COPY profile_map.py /usr/local/bin/profile_map.py

RUN chmod +x \
    /usr/local/bin/build_map.sh \
    /usr/local/bin/validate_map.py \
    /usr/local/bin/profile_map.py

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ENTRYPOINT ["/usr/local/bin/build_map.sh"]
