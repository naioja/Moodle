#!/bin/bash

set -x

TMP='/tmp';

cd $TMP

# Install binutils
wget https://ftp.gnu.org/gnu/binutils/binutils-2.36.1.tar.gz -O $TMP/binutils-2.36.1.tar.gz
tar xf binutils-2.36.1.tar.gz
cd $TMP/binutils-2.36.1
./configure && make -j $(nproc) && make install

# Install nasm
wget http://archive.ubuntu.com/ubuntu/pool/universe/n/nasm/nasm_2.15.04-1_amd64.deb -O $TMP/nasm_2.15.04-1_amd64.deb
apt update
apt install $TMP/nasm_2.15.04-1_amd64.deb
apt install -f

# Install cmake
apt update
apt install -y cmake

# Install gcc
add-apt-repository -y ppa:ubuntu-toolchain-r/test
apt update
apt install -y --no-install-recommends software-properties-common
apt install -y gcc-9 g++-9
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 --slave /usr/bin/g++ g++ /usr/bin/g++-9 --slave /usr/bin/gcov gcov /usr/bin/gcov-9

apt-get update && apt-get install -y --no-install-recommends \
git \
ca-certificates \
wget \
pkg-config \
libudev-dev \
gawk \
make \
build-essential \
autoconf \
autotools-dev \
libtool \
automake \
zlib1g \
zlib1g-dev \
nano \
netcat \
curl \
net-tools \
iproute2 \
linux-headers-generic \
libpcre3 \
libpcre3-dev \
haproxy
apt clean all
rm -rf /var/lib/apt/lists/*

# Install OpenSSL
echo '# Install OpenSSL'
cd $TMP
OPENSSL_RELEASE="OpenSSL_1_1_1j"
git clone -b $OPENSSL_RELEASE https://github.com/openssl/openssl.git
cd openssl
./config
make depend
make
make install_sw

# Install IPP_CRYPTO
echo '# Install IPP_CRYPTO'
cd $TMP
IPP_CRYPTO_VERSION="ippcp_2020u3"
git clone -b $IPP_CRYPTO_VERSION https://github.com/intel/ipp-crypto
cd ipp-crypto/sources/ippcp/crypto_mb
cmake . -B"../build" \
  -DOPENSSL_INCLUDE_DIR=/usr/local/include/openssl \
  -DOPENSSL_LIBRARIES=/usr/local/lib64 \
  -DOPENSSL_ROOT_DIR=/usr/local/bin/openssl
cd ../build
make crypto_mb
make install

#Install IPSEC_MB_VERSION="v0.55"
echo '# Install IPSEC_MB'
cd $TMP
IPSEC_MB_VERSION="v0.55"
git clone -b $IPSEC_MB_VERSION https://github.com/intel/intel-ipsec-mb
cd intel-ipsec-mb
make -j SAFE_DATA=y SAFE_PARAM=y SAFE_LOOKUP=y
make install NOLDCONFIG=y PREFIX=/usr/local/


# Install QAT_ENGINE_VERSION="v0.6.5"
echo 'Install QAT_ENGINE_VERSION'
cd $TMP
QAT_ENGINE_VERSION="v0.6.5"
git clone -b $QAT_ENGINE_VERSION https://github.com/intel/QAT_Engine.git && \
cd QAT_Engine
./autogen.sh
./configure \
  --with-openssl_install_dir=/usr/local/ \
  --with-qat_sw_install_dir=/usr/local/ \
  --enable-qat_sw
make
make install

# Install ASYNC_NGINX_VERSION="v0.4.5"
echo 'Install ASYNC_NGINX_VERSION'
cd $TMP
ASYNC_NGINX_VERSION="v0.4.5"
git clone -b $ASYNC_NGINX_VERSION https://github.com/intel/asynch_mode_nginx.git
cd asynch_mode_nginx
./configure \
  --prefix=/var/www \
  --conf-path=/usr/local/share/nginx/conf/nginx.conf \
  --sbin-path=/usr/local/bin/nginx \
  --pid-path=/run/nginx.pid \
  --lock-path=/run/lock/nginx.lock \
  --modules-path=/var/www/modules/ \
  --without-http_rewrite_module \
  --with-http_ssl_module \
  --with-pcre \
  --add-dynamic-module=modules/nginx_qat_module/ \
  --with-cc-opt="-DNGX_SECURE_MEM -I/usr/local/include/openssl -Wno-error=deprecated-declarations -Wimplicit-fallthrough=0" \
  --with-ld-opt="-Wl,-rpath=/usr/local/lib64 -L/usr/local/lib64" \
  --user=nginx \
  --group=nginx
make
make install

# Configure Intel nginx
apt update ; apt install -y nginx
[[ -f /usr/local/share/nginx/conf/nginx.conf ]] && mv /usr/local/share/nginx/conf/nginx.conf /usr/local/share/nginx/conf/nginx.conf.orig
ln -s /etc/nginx/nginx.conf /usr/local/share/nginx/conf/nginx.conf

# disable distro nginx modules
sed -i 's|/usr/sbin/nginx|/usr/local/bin/nginx|g' /lib/systemd/system/nginx.service
systemctl daemon-reload

# Configure systemd to load custom version nginx
sed -i 's|include\ /etc/nginx/modules-enabled/\*\.conf\;|load_module\ /var/www/modules/ngx_ssl_engine_qat_module.so\;|g' /etc/nginx/nginx.conf
systemctl restart nginx

