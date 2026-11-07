import ipaddress
import os

import uvicorn


def main():
    trusted = os.environ.get("TOMDESK_TRUSTED_PROXY_IPS", "").strip()
    if trusted:
        for address in trusted.split(","):
            ipaddress.ip_address(address.strip())
    port = int(os.environ.get("TOMDESK_ACCOUNT_PORT", "8091"))
    if not 1 <= port <= 65535:
        raise ValueError("TOMDESK_ACCOUNT_PORT must be between 1 and 65535")
    uvicorn.run(
        "tomdesk_account_server.app:create_app",
        factory=True,
        host=os.environ.get("TOMDESK_ACCOUNT_HOST", "127.0.0.1"),
        port=port,
        workers=1,
        proxy_headers=bool(trusted),
        forwarded_allow_ips=trusted,
        access_log=False,
        server_header=False,
    )


if __name__ == "__main__":
    main()
