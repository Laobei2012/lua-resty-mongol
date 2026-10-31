FROM openresty/openresty:1.31.1.1-0-bookworm-fat
RUN apt-get update && apt-get install -y --no-install-recommends cpanminus make curl \
    && cpanm --notest Test::Nginx \
    && /usr/local/openresty/luajit/bin/luarocks install luacheck
ENV PATH="/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin:/usr/local/openresty/luajit/bin:${PATH}"
WORKDIR /work
