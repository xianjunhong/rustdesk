FROM python:3.11-slim@sha256:db20d8506e2f15b6db39b40b6015ca46bae855dec6dd326d462cfe79ae972893
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TOMDESK_ACCOUNT_DB=/data/accounts.sqlite3 \
    TOMDESK_ACCOUNT_HOST=0.0.0.0 TOMDESK_ACCOUNT_PORT=8091
WORKDIR /app
ARG PIP_INDEX_URL=https://pypi.org/simple
COPY requirements.txt constraints.txt ./
RUN pip install --no-cache-dir -c constraints.txt -r requirements.txt \
    && groupadd --gid 10001 tomdesk \
    && useradd --uid 10001 --gid 10001 --no-create-home tomdesk \
    && mkdir /data && chown tomdesk:tomdesk /data
COPY tomdesk_account_server ./tomdesk_account_server
USER 10001:10001
EXPOSE 8091
CMD ["python", "-m", "tomdesk_account_server"]
