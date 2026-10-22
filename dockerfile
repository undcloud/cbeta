FROM ubuntu:24.04
USER root

# 静默安装
ARG DEBIAN_FRONTEND=noninteractive
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# 容器内 git 提交身份（本项目为 undcloud/cbeta，不要沿用上游镜像的 Cirrus CI）
ARG GIT_USER_NAME=undcloud
ARG GIT_USER_EMAIL=undcloud@users.noreply.github.com

# apt 换源：Ubuntu 24.04
RUN printf '%s\n' \
    'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble main restricted universe multiverse' \
    'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-updates main restricted universe multiverse' \
    'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ noble-backports main restricted universe multiverse' \
    'deb http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse' \
    > /etc/apt/sources.list \
    && apt-get update

# 参考： https://github.com/cirruslabs/docker-images-android 
RUN apt update \
    && apt install  wget -y 

ENV ANDROID_HOME=/opt/android-sdk-linux \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en

ENV ANDROID_SDK_ROOT=$ANDROID_HOME \
    PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator

# comes from https://developer.android.com/studio/#command-line-tools-only
ENV ANDROID_SDK_TOOLS_VERSION 13114758
# 国内镜像加速配置（Flutter / Dart）
ENV PUB_HOSTED_URL=https://pub.flutter-io.cn \
    FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
    FLUTTER_GIT_URL=https://gitee.com/mirrors/Flutter.git

RUN set -o xtrace \
    && cd /opt \
    && apt-get update \
    && apt-get install -y jq \
    && apt-get install -y openjdk-21-jdk \
    && apt-get install -y sudo wget zip unzip xz-utils file git openssh-client curl bc software-properties-common build-essential ruby-full ruby-bundler libstdc++6 libpulse0 libglu1-mesa locales lcov libsqlite3-dev --no-install-recommends \
    # for x86 emulators
    && apt-get install -y libxtst6 libnss3-dev libnspr4 libxss1 libasound2t64 libatk-bridge2.0-0 libgtk-3-0 libgdk-pixbuf2.0-0 \
    && apt-get install -y -qq xxd \
    && apt-get install -y lftp \
    && apt-get install -qq -y sqlite3 libsqlite3-dev \
    # && rm -rf /var/lib/apt/lists/* \
    && sh -c 'echo "en_US.UTF-8 UTF-8" > /etc/locale.gen' \
    && locale-gen \
    && update-locale LANG=en_US.UTF-8 \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_TOOLS_VERSION}_latest.zip -O android-sdk-tools.zip \
    && mkdir -p ${ANDROID_HOME}/cmdline-tools/ \
    && unzip -q android-sdk-tools.zip -d ${ANDROID_HOME}/cmdline-tools/ \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && chown -R root:root $ANDROID_HOME \
    && rm android-sdk-tools.zip \
    && echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && yes | sdkmanager --licenses \
    && wget -O /usr/bin/android-wait-for-emulator https://raw.githubusercontent.com/travis-ci/travis-cookbooks/master/community-cookbooks/android-sdk/files/default/android-wait-for-emulator \
    && chmod +x /usr/bin/android-wait-for-emulator \
    && touch /root/.android/repositories.cfg \
    && sdkmanager platform-tools \
    && mkdir -p /root/.android \
    && touch /root/.android/repositories.cfg \
    && git config --global user.email "${GIT_USER_EMAIL}" \
    && git config --global user.name "${GIT_USER_NAME}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends fontconfig fonts-noto-cjk fonts-noto-cjk-extra \
    && fc-cache -f \
    && apt-get install -y --no-install-recommends lld-18 llvm-18
    
# emulator is not available on linux/arm64 (https://issuetracker.google.com/issues/227219818)
RUN if [ $(uname -m) = "x86_64" ]; then sdkmanager emulator ; fi

# https://developer.android.com/studio/releases/build-tools
ENV ANDROID_PLATFORM_VERSION 36
ENV ANDROID_BUILD_TOOLS_VERSION 36.0.0


# Flutter 3.41.x 默认 NDK，需与 android/app/build.gradle.kts 中 flutter.ndkVersion 一致
ENV ANDROID_NDK_VERSION 28.2.13676358
ENV ANDROID_CMAKE_VERSION 3.22.1

RUN yes | sdkmanager \
    "platforms;android-$ANDROID_PLATFORM_VERSION" \
    "build-tools;$ANDROID_BUILD_TOOLS_VERSION" \
    "ndk;$ANDROID_NDK_VERSION" \
    "cmake;$ANDROID_CMAKE_VERSION"


ARG flutter_ver=3.41.6
ARG build_rev=0


# Install Flutter  https://github.com/instrumentisto/flutter-docker-image
ENV FLUTTER_HOME=/usr/local/flutter \
    FLUTTER_VERSION=${flutter_ver} \
    # 设置 Dart 包的镜像源
    PUB_HOSTED_URL=https://pub.flutter-io.cn \
    # 设置 Flutter SDK 的镜像源
    FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
    PATH=$PATH:/usr/local/flutter/bin:/usr/local/flutter/bin/cache/dart-sdk/bin

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends --no-install-suggests \
            ca-certificates \
 && update-ca-certificates \
    \
 # Install dependencies for Linux toolchain
 && apt-get install -y --no-install-recommends --no-install-suggests \
            build-essential \
            clang cmake \
            lcov \
            libgtk-3-dev liblzma-dev \
            ninja-build \
            pkg-config \
    \
 # Install Flutter itself
 && curl --retry 5 --retry-delay 3 -fL -o /tmp/flutter.tar.xz \
        https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_${flutter_ver}-stable.tar.xz \
 && tar -xf /tmp/flutter.tar.xz -C /usr/local/ \
 && git config --global --add safe.directory /usr/local/flutter \
 && flutter config --enable-android \
                   --enable-linux-desktop \
                   --enable-web \
                   --no-enable-ios \
 && flutter precache --universal --linux --web --no-ios \
 && (yes | flutter doctor --android-licenses) \
 && flutter --version \
    \
 # Make Flutter tools available for non-root usage（目录可能尚不存在，失败不中断构建）
 && (chown -R 1000:1000 /usr/local/flutter/packages/flutter_tools/.dart_tool/ 2>/dev/null || true) \
    \
 && rm -rf /var/lib/apt/lists/* \
           /tmp/*

# 图形驱动依赖，解决 eglinfo 警告；Google Chrome 仅有 amd64 版
RUN apt-get update \
    && apt-get install -y --no-install-recommends mesa-vulkan-drivers mesa-utils \
    && if [ "$(uname -m)" = "x86_64" ]; then \
         wget -q -O /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
         && apt-get install -y --no-install-recommends /tmp/google-chrome.deb \
         && rm -f /tmp/google-chrome.deb; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# 预创建 AVD（模拟器镜像仅 x86_64 可用）
RUN if [ "$(uname -m)" = "x86_64" ]; then \
        yes | sdkmanager \
            "system-images;android-36;google_apis;x86_64" \
            "system-images;android-34;google_apis;x86_64" \
        && mkdir -p /root/.android/avd \
        && echo no | avdmanager create avd \
             -n flutter_emulator \
             -k "system-images;android-34;google_apis;x86_64" \
             -d pixel; \
    fi


# SSH 服务：沿用现有 root 开发环境
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && printf '\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes\n' \
       >> /etc/ssh/sshd_config \
    && rm -rf /var/lib/apt/lists/*

# SSH 公钥通过构建参数传入，避免 COPY 缺失文件导致构建失败
# 用法：docker build --build-arg SSH_PUBKEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG SSH_PUBKEY=""
RUN if [ -n "$SSH_PUBKEY" ]; then \
        printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys \
        && chmod 600 /root/.ssh/authorized_keys; \
    else \
        echo "WARN: 未提供 SSH_PUBKEY，容器内无法以公钥登录" >&2; \
    fi \
    && ssh-keygen -A

# 项目在容器内的默认工作目录
WORKDIR /app/xuefo

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]

# docker build --build-arg SSH_PUBKEY="$(cat ~/.ssh/id_rsa.pub)" -t flutter_android:v2.0 .



# docker run -it \
#   --name xuefo_flutter_android_v2.0 \
#   -p 2222:22 \
#   -p 8081:8080 \
#   -w /app \
#   -e DISPLAY=$DISPLAY \
#   -e UID=$(id -u) \
#   -e GID=$(id -g) \
#   --device=/dev/bus \
#   --device=/dev/kvm \
#   --device=/dev/dri \
#   -v /tmp/.X11-unix:/tmp/.X11-unix \
#   -v /dev/bus/usb:/dev/bus/usb \
#   -v /h/flutter/xuefo:/app \
#   --shm-size=2g \
#   flutter_android:v2.0 
