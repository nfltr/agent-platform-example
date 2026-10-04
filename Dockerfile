FROM python:3.12-slim

# nfltr from the signed installer (checks the release signature and checksum).
ARG NFLTR_VERSION=
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://nfltr.xyz/install.sh | NFLTR_INSTALL_DIR=/usr/local/bin NFLTR_VERSION="${NFLTR_VERSION}" sh

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py github.py hubclient.py index.html ./

RUN useradd --create-home platform && mkdir -p /state && chown platform /state
USER platform
ENV PLATFORM_STATE_DIR=/state PLATFORM_CONFIG=/config/config.json
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
