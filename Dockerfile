FROM perl:5.36

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    man-db \
    manpages \
    manpages-dev \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    coreutils \
    procps \
    util-linux \
    binutils \
    grep \
    sed \
    gawk \
    findutils \
    file \
    && rm -rf /var/lib/apt/lists/*

RUN mandb

RUN curl -L https://cpanmin.us | perl - App::cpanminus && \
    cpanm --notest \
    WWW::Telegram::BotAPI \
    URI::Escape

COPY . .

CMD ["perl", "main.pl"]
