# Copyright 2026 KoukeNeko
# Licensed under the Apache License, Version 2.0.
"""Who has committed to the repository, from GitHub.

Standard library only: the packaging step runs this file by itself to write
the snapshot a release ships, while a checkout asks GitHub each time.
"""
import json
import os
import sys
import urllib.request

OWNER, NAME = "KoukeNeko", "Hamasen"
API_URL = f"https://api.github.com/repos/{OWNER}/{NAME}/contributors?per_page=100"


def fetch(timeout=8):
    """[{login, url, contributions}], most active first, without bots."""
    request = urllib.request.Request(API_URL, headers={"Accept": "application/vnd.github+json",
                                                       "User-Agent": "Hamasen"})
    token = os.environ.get("GITHUB_TOKEN")  # CI runners share an address and exhaust the anonymous limit
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        people = json.load(response)
    return sorted(({"login": p["login"], "url": p["html_url"], "contributions": p["contributions"]}
                   for p in people if not p["login"].endswith("[bot]")),
                  key=lambda p: -p["contributions"])


if __name__ == "__main__":
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        json.dump(fetch(), f, indent=2)
